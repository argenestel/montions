"""Independent, exact-integer executable model of MontionsBook (SPEC sections 3–4).

This is deliberately dependency-free. Amounts are USDC base units; prices are ticks.
"""
from __future__ import annotations

from collections import defaultdict, deque
from copy import deepcopy
from dataclasses import dataclass, field
from typing import Any

UNIT = 1_000_000
TICK_UNIT = 10_000
TICKS = 100
DEFAULT_MAX_FILLS = 32
TRADE_RING = 64
BOOK = "__book__"


class ModelRevert(Exception):
    """A modeled custom-error revert; ``name`` is the Solidity error name."""

    def __init__(self, name: str):
        self.name = name
        super().__init__(name)


@dataclass
class Account:
    cash: int = 0
    locked: int = 0


@dataclass
class Series:
    expiry: int
    status: str = "Open"  # Open, Resolved, Void
    yes_wins: bool = False
    pool: int = 0
    orders: dict[int, "Order"] = field(default_factory=dict)
    trades: deque = field(default_factory=lambda: deque(maxlen=TRADE_RING))
    last_tick: int = 0
    volume: int = 0
    level_bid: dict[int, int] = field(default_factory=dict)
    level_ask: dict[int, int] = field(default_factory=dict)
    bid_mask: int = 0
    ask_mask: int = 0


@dataclass
class Order:
    id: int
    maker: str
    series: int
    side: str  # Bid or Ask
    tick: int
    from_held: bool
    qty: int
    orig_qty: int
    placed_at: int
    open: bool = True


class BookModel:
    """State machine for the normative Book semantics.

    Public operations are dispatched by ``apply``. It snapshots before each
    operation so modeled reverts have EVM transaction atomicity.
    """

    def __init__(self, users=(), taker_fee_bps: int = 0, now: int = 0):
        assert 0 <= taker_fee_bps <= 100
        self.accounts: dict[str, Account] = {str(u): Account() for u in users}
        self.tokens: dict[tuple[str, int, str], int] = defaultdict(int)
        self.series: dict[int, Series] = {}
        self.now = int(now)
        self.taker_fee_bps = taker_fee_bps
        self.protocol_fees = 0
        self.book_balance = 0
        self.next_order_id = 1
        self.order_count = 0
        self.user_order_ids: dict[str, list[int]] = defaultdict(list)
        self.orders: dict[int, Order] = {}
        self.trade_audit: list[dict[str, Any]] = []
        self._admin_user_snapshots: list[dict[str, Any]] = []

    def _ensure_user(self, user: str):
        user = str(user)
        if user not in self.accounts:
            self.accounts[user] = Account()

    def _user_token(self, user: str, sid: int, outcome: str) -> int:
        return self.tokens[(str(user), int(sid), outcome)]

    def _set_token(self, user: str, sid: int, outcome: str, amount: int):
        assert amount >= 0
        self.tokens[(str(user), int(sid), outcome)] = amount

    def total_supply(self, sid: int, outcome: str) -> int:
        return sum(v for (u, s, o), v in self.tokens.items() if s == sid and o == outcome)

    def _open_orders(self, sid: int | None = None):
        return [o for o in self.orders.values() if o.open and (sid is None or o.series == sid)]

    def _rebuild_levels(self, sid: int):
        s = self.series[int(sid)]
        levels = {"Bid": defaultdict(int), "Ask": defaultdict(int)}
        for o in self._open_orders(sid):
            levels[o.side][o.tick] += o.qty
        s.level_bid = dict(levels["Bid"])
        s.level_ask = dict(levels["Ask"])
        s.bid_mask = sum(1 << tick for tick, qty in s.level_bid.items() if qty)
        s.ask_mask = sum(1 << tick for tick, qty in s.level_ask.items() if qty)

    def _escrow_cost(self, order: Order) -> int:
        if order.side == "Bid":
            return order.qty * order.tick * TICK_UNIT
        if order.from_held:
            return 0
        return order.qty * (100 - order.tick) * TICK_UNIT

    def _release_order(self, order: Order):
        """Cancel an order, returning its remaining cash or held YES."""
        assert order.open
        a = self.accounts[order.maker]
        if order.side == "Bid" or (order.side == "Ask" and not order.from_held):
            amount = self._escrow_cost(order)
            assert a.locked >= amount
            a.locked -= amount
            a.cash += amount
        elif order.qty:
            sid = order.series
            assert self.tokens[(BOOK, sid, "YES")] >= order.qty
            self.tokens[(BOOK, sid, "YES")] -= order.qty
            self.tokens[(order.maker, sid, "YES")] += order.qty
        order.open = False
        order.qty = 0

    def _eligible(self, incoming: Order, resting: Order) -> bool:
        if not resting.open or incoming.side == resting.side:
            return False
        if incoming.side == "Bid":
            return resting.tick <= incoming.tick
        return resting.tick >= incoming.tick

    def _opposite_sorted(self, incoming: Order):
        eligible = [o for o in self._open_orders(incoming.series) if self._eligible(incoming, o)]
        if incoming.side == "Bid":
            return sorted(eligible, key=lambda o: (o.tick, o.id))
        return sorted(eligible, key=lambda o: (-o.tick, o.id))

    def _fee(self, notional: int) -> int:
        if notional == 0 or self.taker_fee_bps == 0:
            return 0
        return (notional * self.taker_fee_bps + 9_999) // 10_000

    def create_series(self, sid: int, expiry: int):
        sid = int(sid)
        if sid in self.series:
            raise ModelRevert("SeriesExists")
        if expiry < self.now + 120 or expiry > self.now + 90 * 24 * 3600:
            raise ModelRevert("BadExpiry")
        self.series[sid] = Series(expiry=int(expiry))
        self.assert_invariants()
        return sid

    def deposit(self, user: str, amount: int):
        self._ensure_user(user)
        assert amount >= 0
        self.accounts[str(user)].cash += int(amount)
        self.book_balance += int(amount)
        self.assert_invariants()

    def withdraw(self, user: str, amount: int):
        self._ensure_user(user)
        if amount > self.accounts[str(user)].cash:
            raise ModelRevert("InsufficientCash")
        self.accounts[str(user)].cash -= int(amount)
        self.book_balance -= int(amount)
        self.assert_invariants()

    def split(self, user: str, sid: int, qty: int):
        s = self._series_open(sid)
        self._check_before_expiry(s)
        if qty == 0:
            raise ModelRevert("BadQty")
        cost = int(qty) * UNIT
        a = self.accounts[str(user)]
        if a.cash < cost:
            raise ModelRevert("InsufficientCash")
        a.cash -= cost
        s.pool += cost
        self.book_balance += 0  # internal cash transfer
        self.tokens[(str(user), int(sid), "YES")] += int(qty)
        self.tokens[(str(user), int(sid), "NO")] += int(qty)
        self.assert_invariants()

    def merge(self, user: str, sid: int, qty: int):
        s = self._series_open(sid)
        if qty == 0:
            raise ModelRevert("BadQty")
        y = self._user_token(user, sid, "YES")
        n = self._user_token(user, sid, "NO")
        if y < qty or n < qty:
            raise ModelRevert("InsufficientTokens")
        amount = int(qty) * UNIT
        if s.pool < amount:
            raise AssertionError("paired tokens exceed pool")
        self._set_token(user, sid, "YES", y - int(qty))
        self._set_token(user, sid, "NO", n - int(qty))
        s.pool -= amount
        self.accounts[str(user)].cash += amount
        self.assert_invariants()

    def _series_open(self, sid: int) -> Series:
        if int(sid) not in self.series:
            raise ModelRevert("SeriesUnknown")
        s = self.series[int(sid)]
        if s.status != "Open":
            raise ModelRevert("SeriesNotOpen")
        return s

    def _check_before_expiry(self, s: Series):
        if self.now >= s.expiry:
            raise ModelRevert("Expired")

    def _would_cross(self, probe: Order) -> bool:
        return any(self._eligible(probe, o) for o in self._open_orders(probe.series))

    def place_order(self, user: str, sid: int, side: str, tick: int, qty: int,
                    from_held: bool = False, tif: str = "GTC", max_fills: int = 0):
        self._ensure_user(user)
        s = self._series_open(sid)
        self._check_before_expiry(s)
        if not 1 <= int(tick) <= 99:
            raise ModelRevert("BadTick")
        if int(qty) == 0:
            raise ModelRevert("BadQty")
        if side not in ("Bid", "Ask"):
            raise ModelRevert("BadTick")
        if tif not in ("GTC", "IOC", "POST_ONLY"):
            raise ValueError(tif)
        if side == "Bid" and from_held:
            # The interface only defines fromHeld for Ask. There is no dedicated error.
            raise ModelRevert("BadQty")
        probe = Order(0, str(user), int(sid), side, int(tick), bool(from_held), int(qty), int(qty), self.now)
        if tif == "POST_ONLY" and self._would_cross(probe):
            raise ModelRevert("WouldCross")
        a = self.accounts[str(user)]
        if side == "Bid":
            lock = int(qty) * int(tick) * TICK_UNIT
            if a.cash < lock:
                raise ModelRevert("InsufficientCash")
            a.cash -= lock
            a.locked += lock
        elif from_held:
            held = self._user_token(user, sid, "YES")
            if held < qty:
                raise ModelRevert("InsufficientTokens")
            self._set_token(user, sid, "YES", held - int(qty))
            self.tokens[(BOOK, int(sid), "YES")] += int(qty)
        else:
            lock = int(qty) * (100 - int(tick)) * TICK_UNIT
            if a.cash < lock:
                raise ModelRevert("InsufficientCash")
            a.cash -= lock
            a.locked += lock

        oid = self.next_order_id
        self.next_order_id += 1
        self.order_count += 1
        incoming = Order(oid, str(user), int(sid), side, int(tick), bool(from_held), int(qty), int(qty), self.now)
        self.orders[oid] = incoming
        s.orders[oid] = incoming
        self.user_order_ids[str(user)].append(oid)
        left = int(qty)
        fills = 0
        notional = 0
        fill_limit = int(max_fills) if max_fills else DEFAULT_MAX_FILLS

        while left > 0 and fills < fill_limit:
            candidates = self._opposite_sorted(incoming)
            if not candidates:
                break
            maker = candidates[0]
            if maker.maker == str(user):
                self._release_order(maker)
                continue
            # The selected resting order is exactly the best eligible price/time order.
            assert maker is min(candidates, key=lambda o: (o.tick if side == "Bid" else -o.tick, o.id))
            q = min(left, maker.qty)
            p = maker.tick
            audit = {
                "incoming_side": side, "limit": int(tick), "taker": str(user),
                "maker_id": maker.id,
                "eligible_before": [(x.id, x.tick, x.maker) for x in candidates],
            }
            self.trade_audit.append(audit)

            if side == "Bid":
                # Taker's limit escrow is consumed; maker price savings return to free cash.
                taker_limit = int(tick) * TICK_UNIT * q
                execution = p * TICK_UNIT * q
                assert a.locked >= taker_limit
                a.locked -= taker_limit
                a.cash += taker_limit - execution
                if maker.from_held:
                    ma = self.accounts[maker.maker]
                    ma.cash += execution
                    self.tokens[(BOOK, int(sid), "YES")] -= q
                    self.tokens[(str(user), int(sid), "YES")] += q
                else:
                    ma = self.accounts[maker.maker]
                    maker_collateral = (100 - p) * TICK_UNIT * q
                    assert ma.locked >= maker_collateral
                    ma.locked -= maker_collateral
                    s.pool += q * UNIT
                    self.tokens[(str(user), int(sid), "YES")] += q
                    self.tokens[(maker.maker, int(sid), "NO")] += q
            else:
                maker_cash = p * TICK_UNIT * q
                ma = self.accounts[maker.maker]
                maker_bid_lock = p * TICK_UNIT * q
                assert ma.locked >= maker_bid_lock
                ma.locked -= maker_bid_lock
                if from_held:
                    self.tokens[(BOOK, int(sid), "YES")] -= q
                    self.tokens[(maker.maker, int(sid), "YES")] += q
                    a.cash += maker_cash
                else:
                    taker_limit = (100 - int(tick)) * TICK_UNIT * q
                    taker_collateral = (100 - p) * TICK_UNIT * q
                    assert a.locked >= taker_limit
                    a.locked -= taker_limit
                    a.cash += taker_limit - taker_collateral
                    s.pool += q * UNIT
                    self.tokens[(maker.maker, int(sid), "YES")] += q
                    self.tokens[(str(user), int(sid), "NO")] += q

            left -= q
            incoming.qty -= q
            maker.qty -= q
            fills += 1
            notional += q * p * TICK_UNIT
            s.last_tick = p
            s.volume += q
            s.trades.appendleft({"ts": self.now, "tick": p, "qty": q, "takerIsBuyer": side == "Bid"})
            if maker.qty == 0:
                maker.open = False

        fee = self._fee(notional)
        if fee:
            if a.cash < fee:
                raise ModelRevert("InsufficientCash")
            a.cash -= fee
            self.protocol_fees += fee

        resting = 0
        if left:
            incoming.qty = left
            still_crosses = bool(self._opposite_sorted(incoming))
            if tif == "GTC" and not still_crosses:
                resting = left
            else:
                # IOC remainder, max-fills still-crossing remainder, or another TIF: refund.
                self._release_order(incoming)
        else:
            incoming.open = False
            incoming.qty = 0
        self._rebuild_levels(int(sid))
        self.assert_invariants()
        return {"orderId": oid, "filled": int(qty) - left, "resting": resting}

    def cancel(self, user: str, oid: int):
        if int(oid) not in self.orders:
            raise ModelRevert("OrderNotOpen")
        order = self.orders[int(oid)]
        if order.maker != str(user):
            raise ModelRevert("NotOrderOwner")
        if not order.open:
            raise ModelRevert("OrderNotOpen")
        self._release_order(order)
        self._rebuild_levels(order.series)
        self.assert_invariants()

    def resolve(self, sid: int, resolver_ready: bool, yes: bool = False):
        if int(sid) not in self.series:
            raise ModelRevert("SeriesUnknown")
        s = self.series[int(sid)]
        if s.status != "Open":
            raise ModelRevert("AlreadySettled")
        if self.now < s.expiry:
            raise ModelRevert("NotExpired")
        if resolver_ready:
            s.status = "Resolved"
            s.yes_wins = bool(yes)
        elif self.now >= s.expiry + 2 * 24 * 3600:
            s.status = "Void"
        else:
            # The frozen interface has no NotReady error; spec says not-ready revert.
            raise ModelRevert("NotExpired")
        self.assert_invariants()

    def redeem(self, user: str, sid: int, yes_qty: int, no_qty: int) -> int:
        if int(sid) not in self.series:
            raise ModelRevert("SeriesUnknown")
        s = self.series[int(sid)]
        if s.status == "Open":
            raise ModelRevert("SeriesNotOpen")
        yes_qty, no_qty = int(yes_qty), int(no_qty)
        y, n = self._user_token(user, sid, "YES"), self._user_token(user, sid, "NO")
        if y < yes_qty or n < no_qty:
            raise ModelRevert("InsufficientTokens")
        if s.status == "Resolved":
            payout = (yes_qty if s.yes_wins else no_qty) * UNIT
        else:
            payout = (yes_qty + no_qty) * UNIT // 2
        if s.pool < payout:
            raise AssertionError("redemption exceeds series pool")
        self._set_token(user, sid, "YES", y - yes_qty)
        self._set_token(user, sid, "NO", n - no_qty)
        s.pool -= payout
        self.accounts[str(user)].cash += payout
        self.assert_invariants()
        return payout

    def best_bid_ask(self, sid: int):
        bids = self.depth(sid, "Bid", 1)
        asks = self.depth(sid, "Ask", 1)
        return (bids[0][0], bids[0][1], asks[0][0], asks[0][1]) if bids and asks else (
            bids[0][0] if bids else 0, bids[0][1] if bids else 0,
            asks[0][0] if asks else 0, asks[0][1] if asks else 0)

    def depth(self, sid: int, side: str, max_levels: int = 10):
        totals: dict[int, int] = defaultdict(int)
        for o in self._open_orders(sid):
            if o.side == side:
                totals[o.tick] += o.qty
        ticks = sorted(totals, reverse=(side == "Bid"))[:max_levels]
        return [[t, totals[t]] for t in ticks]

    def recent_trades(self, sid: int, n: int = 64):
        return list(self.series[int(sid)].trades)[:n]

    def _user_snapshot(self):
        return {
            "accounts": deepcopy(self.accounts),
            "tokens": deepcopy(self.tokens),
        }

    def assert_invariants(self):
        # 1–2. Token/pool collateralization for Open, Resolved, and Void series.
        for sid, s in self.series.items():
            y, n = self.total_supply(sid, "YES"), self.total_supply(sid, "NO")
            if s.status == "Open":
                assert s.pool == y * UNIT == n * UNIT, ("open pool", sid, s.pool, y, n)
            elif s.status == "Resolved":
                winning_supply = y if s.yes_wins else n
                assert s.pool == winning_supply * UNIT, ("resolved pool", sid, s.pool, y, n)
            else:
                assert 2 * s.pool == (y + n) * UNIT, ("void pool", sid, s.pool, y, n)

        # 3. Internal USDC ledger exactly matches collateral held by the Book.
        assert self.book_balance == (
            sum(a.cash + a.locked for a in self.accounts.values())
            + sum(s.pool for s in self.series.values()) + self.protocol_fees
        ), ("cash conservation", self.book_balance)

        # 4. Per-user locked balances equal escrow of open cash-backed orders.
        expected_locked: dict[str, int] = defaultdict(int)
        for o in self._open_orders():
            expected_locked[o.maker] += self._escrow_cost(o)
        for user, account in self.accounts.items():
            assert account.locked == expected_locked[user], ("locked escrow", user, account.locked, expected_locked[user])

        # 5. Depth aggregation only includes positive open quantities at each level.
        for sid in self.series:
            for side in ("Bid", "Ask"):
                expected: dict[int, int] = defaultdict(int)
                for o in self._open_orders(sid):
                    if o.side == side:
                        assert o.qty > 0
                        expected[o.tick] += o.qty
                actual = {tick: qty for tick, qty in self.depth(sid, side, 100)}
                assert actual == dict(expected), ("depth", sid, side, actual, dict(expected))
                stored = self.series[sid].level_bid if side == "Bid" else self.series[sid].level_ask
                mask = self.series[sid].bid_mask if side == "Bid" else self.series[sid].ask_mask
                assert stored == dict(expected), ("level quantities", sid, side, stored, dict(expected))
                expected_mask = sum(1 << tick for tick, qty in expected.items() if qty > 0)
                assert mask == expected_mask, ("occupancy mask", sid, side, mask, expected_mask)

        # 6. Every fill selected the best eligible price/time order; self-trades are
        # allowed only after all earlier same-side candidates belonging to the taker
        # have been removed by STP (the captured eligible set is post-STP).
        for t in self.trade_audit:
            side = t["incoming_side"]
            candidates = t["eligible_before"]
            assert candidates and candidates[0][0] == t["maker_id"]
            key = (lambda x: (x[1], x[0])) if side == "Bid" else (lambda x: (-x[1], x[0]))
            assert key(candidates[0]) == min(map(key, candidates))

        # 7. Admin operations are constrained to preserve the full user ledger.
        # Any captured admin snapshot must match user balances exactly.
        for unchanged in self._admin_user_snapshots:
            assert unchanged

    def owner_set_fee(self, bps: int):
        if bps > 100:
            raise ModelRevert("FeeTooHigh")
        snap = self._user_snapshot()
        self.taker_fee_bps = int(bps)
        self._admin_user_snapshots.append(snap == self._user_snapshot())
        self.assert_invariants()

    def owner_withdraw_fees(self, amount: int):
        if amount > self.protocol_fees:
            raise ModelRevert("InsufficientCash")
        snap = self._user_snapshot()
        self.protocol_fees -= int(amount)
        self.book_balance -= int(amount)
        self._admin_user_snapshots.append(snap == self._user_snapshot())
        self.assert_invariants()

    def apply(self, op: dict[str, Any]) -> dict[str, Any]:
        """Apply an operation transactionally and return its result/error."""
        snapshot = deepcopy(self.__dict__)
        self.now = int(op.get("at", self.now))
        kind = op["kind"]
        try:
            if kind == "create":
                result = self.create_series(op["series"], op["expiry"])
                out = {"ok": True, "seriesId": result}
            elif kind == "deposit":
                self.deposit(op["user"], op["amount"])
                out = {"ok": True}
            elif kind == "withdraw":
                self.withdraw(op["user"], op["amount"])
                out = {"ok": True}
            elif kind == "split":
                self.split(op["user"], op["series"], op["qty"])
                out = {"ok": True}
            elif kind == "merge":
                self.merge(op["user"], op["series"], op["qty"])
                out = {"ok": True}
            elif kind == "place":
                out = {"ok": True, **self.place_order(
                    op["user"], op["series"], op["side"], op["tick"], op["qty"],
                    op.get("fromHeld", False), op.get("tif", "GTC"), op.get("maxFills", 0))}
            elif kind == "cancel":
                self.cancel(op["user"], op["orderId"])
                out = {"ok": True}
            elif kind == "resolve":
                self.resolve(op["series"], op["ready"], op.get("yes", False))
                out = {"ok": True}
            elif kind == "redeem":
                payout = self.redeem(op["user"], op["series"], op["yesQty"], op["noQty"])
                out = {"ok": True, "payout": payout}
            else:
                raise ValueError(f"unknown operation {kind}")
            for sid in self.series:
                # Materialize the reference model's per-tick level totals and occupancy bitsets.
                self._rebuild_levels(sid)
            self.assert_invariants()
            return out
        except ModelRevert as exc:
            self.__dict__.clear()
            self.__dict__.update(snapshot)
            self.assert_invariants()
            return {"ok": False, "error": exc.name}
        except Exception:
            self.__dict__.clear()
            self.__dict__.update(snapshot)
            raise

    def state(self, users, series_ids):
        """JSON-friendly complete replay checkpoint."""
        return {
            "users": [{
                "cash": self.accounts[str(u)].cash,
                "locked": self.accounts[str(u)].locked,
                "yes": [self._user_token(u, sid, "YES") for sid in series_ids],
                "no": [self._user_token(u, sid, "NO") for sid in series_ids],
            } for u in users],
            "protocolFees": self.protocol_fees,
            "series": [{
                "pool": self.series[sid].pool,
                "yesSupply": self.total_supply(sid, "YES"),
                "noSupply": self.total_supply(sid, "NO"),
                "bestBidAsk": {
                    "bidTick": self.best_bid_ask(sid)[0], "bidQty": self.best_bid_ask(sid)[1],
                    "askTick": self.best_bid_ask(sid)[2], "askQty": self.best_bid_ask(sid)[3],
                },
                "depthBid": [{"tick": t, "qty": q} for t, q in self.depth(sid, "Bid", 10)],
                "depthBidCount": len(self.depth(sid, "Bid", 10)),
                "depthAsk": [{"tick": t, "qty": q} for t, q in self.depth(sid, "Ask", 10)],
                "depthAskCount": len(self.depth(sid, "Ask", 10)),
                "status": self.series[sid].status,
                "yes": self.series[sid].yes_wins,
                "lastTradeTick": self.series[sid].last_tick,
                "volume": self.series[sid].volume,
                "trades": list(self.recent_trades(sid, TRADE_RING)),
                "tradeCount": len(self.recent_trades(sid, TRADE_RING)),
            } for sid in series_ids],
        }

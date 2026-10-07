#!/usr/bin/env python3
"""Generate deterministic Solidity differential-replay vectors from BookModel."""
from __future__ import annotations

import json
import random
from pathlib import Path

from book_model import BookModel, UNIT

ROOT = Path(__file__).resolve().parents[2]
VECTOR_DIR = ROOT / "test" / "diff" / "vectors"
USER_COUNT = 5
USERS = list(range(USER_COUNT))
USER_NAMES = [str(i) for i in USERS]
OPS_PER_SCENARIO = 220
BASE_TIME = 1_800_000_000


def enrich(op, result):
    out = dict(op)
    out.update({
        "ok": result["ok"],
        "error": result.get("error", ""),
        "orderId": result.get("orderId", 0),
        "filled": result.get("filled", 0),
        "resting": result.get("resting", 0),
        "payout": result.get("payout", 0),
    })
    return out


class Scenario:
    def __init__(self, seed: int):
        self.seed = seed
        self.rng = random.Random(seed)
        self.count = 1 + seed % 3
        self.base = BASE_TIME + seed * 100_000
        # Across the ten seeds this exercises both resolved outcomes and voids.
        self.outcomes = [((seed + i) % 3) for i in range(self.count)]  # 0=no, 1=yes, 2=void
        self.expiries = [self.base + 20_000 + i * 20_000 for i in range(self.count)]
        self.model = BookModel(USER_NAMES, taker_fee_bps=100, now=self.base)
        self.ops = []
        self.checkpoints = []
        self.series = [
            {"index": i, "outcome": self.outcomes[i], "expiry": self.expiries[i],
             "data": "0x" + f"{self.outcomes[i]:064x}"}
            for i in range(self.count)
        ]

    def add(self, kind, **fields):
        op = {"kind": kind, "at": fields.pop("at", self.model.now), **fields}
        result = self.model.apply(op)
        self.ops.append(enrich(op, result))
        if len(self.ops) > 0 and len(self.ops) % 10 == 0:
            self._checkpoint()
        return result

    def _checkpoint(self):
        self.checkpoints.append({
            "opIndex": len(self.ops) - 1,
            "state": self.model.state(USER_NAMES, list(range(self.count))),
        })

    def bootstrap(self):
        for i in range(self.count):
            self.add("create", series=i, expiry=self.expiries[i], outcome=self.outcomes[i], at=self.base)
        for u in USERS:
            self.add("deposit", user=u, amount=2_000 * UNIT, at=self.base)
        # Give each user enough paired inventory for held asks and merge coverage.
        for sid in range(self.count):
            for u in USERS:
                self.add("split", user=u, series=sid, qty=20 + self.rng.randrange(10), at=self.base)

    def curated_trades(self):
        sid = 0
        # Multi-level maker asks, partial fills and multiple price-time matches.
        self.add("place", user=0, series=sid, side="Ask", tick=42, qty=5,
                 fromHeld=False, tif="GTC", maxFills=0)
        self.add("place", user=1, series=sid, side="Ask", tick=43, qty=4,
                 fromHeld=False, tif="GTC", maxFills=0)
        self.add("place", user=2, series=sid, side="Bid", tick=50, qty=3,
                 fromHeld=False, tif="GTC", maxFills=0)
        self.add("place", user=3, series=sid, side="Bid", tick=49, qty=8,
                 fromHeld=False, tif="GTC", maxFills=0)

        # Held-YES maker sale, with cash paid to the writer and no pool/supply change.
        bid30 = self.add("place", user=4, series=sid, side="Bid", tick=30, qty=3,
                         fromHeld=False, tif="GTC", maxFills=0)
        self.add("place", user=0, series=sid, side="Ask", tick=25, qty=2,
                 fromHeld=True, tif="GTC", maxFills=0)
        if bid30["ok"] and bid30["resting"]:
            self.add("cancel", user=4, orderId=bid30["orderId"])

        # IOC partial execution followed by remainder refund.
        self.add("place", user=2, series=sid, side="Bid", tick=38, qty=2,
                 fromHeld=False, tif="GTC", maxFills=0)
        self.add("place", user=1, series=sid, side="Ask", tick=35, qty=5,
                 fromHeld=False, tif="IOC", maxFills=0)
        self._cancel_open(sid)

        # POST_ONLY must revert on a genuine cross, then a maxFills=1 remainder
        # is dropped instead of becoming a crossing resting order.
        self.add("place", user=4, series=sid, side="Ask", tick=60, qty=1,
                 fromHeld=False, tif="GTC", maxFills=0)
        self.add("place", user=3, series=sid, side="Bid", tick=65, qty=1,
                 fromHeld=False, tif="POST_ONLY", maxFills=0)
        self.add("place", user=2, series=sid, side="Ask", tick=20, qty=1,
                 fromHeld=False, tif="GTC", maxFills=0)
        self.add("place", user=1, series=sid, side="Ask", tick=21, qty=1,
                 fromHeld=False, tif="GTC", maxFills=0)
        self.add("place", user=3, series=sid, side="Bid", tick=30, qty=3,
                 fromHeld=False, tif="GTC", maxFills=1)
        self._cancel_open(sid)

        # Self trade prevention cancels the resting ask, then allows the taker to rest.
        ask = self.add("place", user=4, series=sid, side="Ask", tick=90, qty=2,
                       fromHeld=False, tif="GTC", maxFills=0)
        stp = self.add("place", user=4, series=sid, side="Bid", tick=95, qty=1,
                       fromHeld=False, tif="GTC", maxFills=0)
        if stp["ok"] and stp["resting"]:
            self.add("cancel", user=4, orderId=stp["orderId"])

        # Split/merge every available market and cancel one level at a time.
        for sid in range(self.count):
            self.add("split", user=sid % USER_COUNT, series=sid, qty=2)
            self.add("merge", user=sid % USER_COUNT, series=sid, qty=1)

    def _cancel_open(self, sid):
        for order in list(self.model._open_orders(sid)):
            self.add("cancel", user=int(order.maker), orderId=order.id)

    def random_phase(self):
        # Fixed operation count independent of the curated prefix and setup.
        target = OPS_PER_SCENARIO - 15
        while len(self.ops) < target:
            sid = self.rng.randrange(self.count)
            user = self.rng.choice(USERS)
            action = self.rng.choices(
                ["place", "cancel", "splitmerge", "deposit"], [62, 18, 15, 5], k=1
            )[0]
            if action == "cancel":
                owned = [o for o in self.model._open_orders(sid) if o.maker == str(user)]
                if owned:
                    order = self.rng.choice(owned)
                    self.add("cancel", user=user, orderId=order.id)
                else:
                    action = "place"
            if action == "splitmerge":
                y = self.model._user_token(user, sid, "YES")
                n = self.model._user_token(user, sid, "NO")
                if min(y, n) and self.rng.random() < 0.5:
                    self.add("merge", user=user, series=sid, qty=self.rng.randint(1, min(3, y, n)))
                else:
                    self.add("split", user=user, series=sid, qty=self.rng.randint(1, 3))
            elif action == "deposit":
                self.add("deposit", user=user, amount=100 * UNIT)
            elif action == "place":
                side = self.rng.choice(["Bid", "Ask"])
                held = side == "Ask" and self.rng.random() < 0.28
                if held:
                    held_qty = self.model._user_token(user, sid, "YES")
                    if held_qty < 6:
                        self.add("split", user=user, series=sid, qty=10)
                qty = self.rng.randint(1, 5)
                tif = self.rng.choices(["GTC", "IOC", "POST_ONLY"], [65, 23, 12], k=1)[0]
                self.add("place", user=user, series=sid, side=side,
                         tick=self.rng.randint(5, 95), qty=qty, fromHeld=held,
                         tif=tif, maxFills=self.rng.choice([0, 0, 0, 1, 2, 4]))

    def settle(self):
        # Preserve a live order through expiry/resolution to verify explicit cancel.
        for sid in range(self.count):
            if not any(o.open and o.series == sid for o in self.model.orders.values()):
                self.add("place", user=0, series=sid, side="Ask", tick=99, qty=1,
                         fromHeld=False, tif="GTC", maxFills=0)

        # Cancel all but one open order per series while still Open.
        keep = {}
        for sid in range(self.count):
            live = [o for o in self.model._open_orders(sid)]
            keep[sid] = live[-1].id if live else 0
            for order in live:
                if order.id != keep[sid]:
                    self.add("cancel", user=int(order.maker), orderId=order.id)

        # At expiry, ready resolvers settle; unresolved ones revert until grace.
        for sid in range(self.count):
            at = self.expiries[sid]
            result = self.outcomes[sid]
            self.add("resolve", series=sid, ready=(result != 2), yes=(result == 1), at=at)
        for sid in range(self.count):
            if self.outcomes[sid] == 2:
                self.add("resolve", series=sid, ready=False, yes=False,
                         at=self.expiries[sid] + 2 * 24 * 3600)

        # Orders are not auto-cancelled when a series settles.
        for sid, oid in keep.items():
            if oid and self.model.orders[oid].open:
                self.add("cancel", user=int(self.model.orders[oid].maker), orderId=oid,
                         at=max(self.model.now, self.expiries[sid]))

        final_at = max(self.expiries) + 2 * 24 * 3600 + 1
        for sid in range(self.count):
            for user in USERS:
                yes = self.model._user_token(user, sid, "YES")
                no = self.model._user_token(user, sid, "NO")
                if yes or no:
                    self.add("redeem", user=user, series=sid, yesQty=yes, noQty=no, at=final_at)

    def build(self):
        self.bootstrap()
        self.curated_trades()
        self.random_phase()
        self.settle()
        if len(self.ops) < 200:
            raise AssertionError(f"scenario {self.seed} has only {len(self.ops)} operations")
        # Settlement can push the scenario above the 220-operation target.
        if not self.checkpoints or self.checkpoints[-1]["opIndex"] != len(self.ops) - 1:
            self._checkpoint()
        doc = {
            "format": 1,
            "seed": self.seed,
            "baseTimestamp": self.base,
            "feeBps": self.model.taker_fee_bps,
            "users": USERS,
            "userCount": len(USERS),
            "series": self.series,
            "seriesCount": self.count,
            "ops": self.ops,
            "opCount": len(self.ops),
            "checkpoints": self.checkpoints,
            "checkpointCount": len(self.checkpoints),
            "end": self.model.state(USER_NAMES, list(range(self.count))),
        }
        return doc


def main():
    VECTOR_DIR.mkdir(parents=True, exist_ok=True)
    for seed in range(10):
        doc = Scenario(seed).build()
        path = VECTOR_DIR / f"scenario_{seed:02d}.json"
        path.write_text(json.dumps(doc, separators=(",", ":")) + "\n")
        size = path.stat().st_size
        if size >= 300_000:
            raise SystemExit(f"{path} exceeds the 300 KB limit: {size}")
        print(f"{path}: {len(doc['ops'])} ops, {len(doc['checkpoints'])} checkpoints, {size} bytes")


if __name__ == "__main__":
    main()

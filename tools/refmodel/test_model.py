"""Plain-assert regression tests for the independent reference model."""
from book_model import BOOK, UNIT, TICK_UNIT, BookModel


def test_write_bid_fill_and_fee():
    m = BookModel(["writer", "buyer"], taker_fee_bps=100)
    m.create_series(0, 10_000)
    m.deposit("writer", 20 * UNIT)
    m.deposit("buyer", 20 * UNIT)
    ask = m.place_order("writer", 0, "Ask", 40, 3)
    assert ask == {"orderId": 1, "filled": 0, "resting": 3}
    bid = m.place_order("buyer", 0, "Bid", 50, 2)
    assert bid == {"orderId": 2, "filled": 2, "resting": 0}
    assert m.series[0].pool == 2 * UNIT
    assert m._user_token("buyer", 0, "YES") == 2
    assert m._user_token("writer", 0, "NO") == 2
    assert m.accounts["writer"].locked == TICK_UNIT * 60
    assert m.protocol_fees == 2 * 40 * TICK_UNIT // 100
    assert m.recent_trades(0)[0] == {"ts": 0, "tick": 40, "qty": 2, "takerIsBuyer": True}
    m.assert_invariants()


def test_held_ask_cancel_ioc_post_only_and_priority():
    m = BookModel(["a", "b", "c"], taker_fee_bps=0)
    m.create_series(0, 10_000)
    for u in ("a", "b", "c"):
        m.deposit(u, 100 * UNIT)
    m.split("a", 0, 5)
    m.place_order("b", 0, "Bid", 30, 2)
    first = m.place_order("a", 0, "Ask", 25, 2, from_held=True)
    assert first["filled"] == 2
    assert m._user_token("b", 0, "YES") == 2
    assert m.accounts["a"].cash == 95 * UNIT + 60 * TICK_UNIT
    assert m.series[0].pool == 5 * UNIT
    # Better price and then FIFO are selected by the taker.
    m.place_order("a", 0, "Ask", 45, 2)
    older = m.place_order("b", 0, "Ask", 40, 2)
    m.place_order("c", 0, "Bid", 35, 1, tif="IOC")
    assert m.orders[older["orderId"]].open
    crossing = m.apply({"kind": "place", "user": "c", "series": 0, "side": "Bid",
                        "tick": 45, "qty": 1, "tif": "POST_ONLY"})
    assert crossing == {"ok": False, "error": "WouldCross"}
    assert m.cancel("a", 3) is None
    m.assert_invariants()


def test_self_trade_max_fills_and_remainder_disposition():
    m = BookModel(["u", "v"], taker_fee_bps=0)
    m.create_series(0, 10_000)
    for u in ("u", "v"):
        m.deposit(u, 100 * UNIT)
    ask_id = m.place_order("u", 0, "Ask", 40, 2)["orderId"]
    result = m.place_order("u", 0, "Bid", 50, 1)
    assert result["filled"] == 0 and result["resting"] == 1
    assert not m.orders[ask_id].open  # STP cancels the maker and continues.
    m.cancel("u", result["orderId"])
    # Two eligible asks, one fill allowed: still-crossing remainder is refunded.
    m.place_order("v", 0, "Ask", 30, 1)
    m.place_order("v", 0, "Ask", 31, 1)
    bounded = m.place_order("u", 0, "Bid", 40, 2, max_fills=1)
    assert bounded["filled"] == 1 and bounded["resting"] == 0
    assert m.depth(0, "Ask", 10) == [[31, 1]]
    m.assert_invariants()


def test_split_merge_resolve_and_void_redeem():
    m = BookModel(["alice", "bob"], now=1_000)
    m.create_series(0, 2_000)
    m.create_series(1, 2_000)
    m.deposit("alice", 10 * UNIT)
    m.deposit("bob", 10 * UNIT)
    m.split("alice", 0, 4)
    m.merge("alice", 0, 1)
    assert m.series[0].pool == 3 * UNIT
    m.now = 2_000
    m.resolve(0, True, True)
    assert m.redeem("alice", 0, 3, 3) == 3 * UNIT
    assert m.series[0].pool == 0
    m.now = 2_000 + 2 * 24 * 3600
    m.resolve(1, False)
    # Seed a balanced void position through an Open split before settling.
    # Here series 1 is empty; exercise its zero redemption, and the nonzero
    # Void payout separately on a fresh series.
    assert m.redeem("bob", 1, 0, 0) == 0
    m.create_series(2, m.now + 500)
    m.split("bob", 2, 2)
    m.now = m.series[2].expiry + 2 * 24 * 3600
    m.resolve(2, False)
    assert m.redeem("bob", 2, 1, 1) == UNIT
    assert m.series[2].pool == UNIT
    m.assert_invariants()


def test_reverts_are_atomic_and_owner_cannot_touch_users():
    m = BookModel(["x"], taker_fee_bps=0)
    m.create_series(0, 1_000)
    m.deposit("x", UNIT)
    before = m.state(["x"], [0])
    out = m.apply({"kind": "place", "user": "x", "series": 0, "side": "Bid",
                   "tick": 100, "qty": 1, "at": 1})
    assert out == {"ok": False, "error": "BadTick"}
    assert m.state(["x"], [0]) == before
    user_before = m._user_snapshot()
    m.owner_set_fee(75)
    assert m._user_snapshot() == user_before
    m.assert_invariants()


def run():
    test_write_bid_fill_and_fee()
    test_held_ask_cancel_ioc_post_only_and_priority()
    test_self_trade_max_fills_and_remainder_disposition()
    test_split_merge_resolve_and_void_redeem()
    test_reverts_are_atomic_and_owner_cannot_touch_users()
    print("book_model.py: 5 tests passed")


if __name__ == "__main__":
    run()

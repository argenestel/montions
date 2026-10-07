"""Plain-assert regression tests for the independent v0.2 reference model."""
from book_model import BOOK, MAX_QTY, UNIT, TICK_UNIT, BookModel


def test_write_bid_fee_and_order_reserve():
    m = BookModel(["writer", "buyer"], taker_fee_bps=100)
    m.create_series(0, 10_000)
    m.deposit("writer", 20 * UNIT)
    m.deposit("buyer", 20 * UNIT)
    ask = m.place_order("writer", 0, "Ask", 40, 3)
    assert ask == {"orderId": 1, "filled": 0, "resting": 3}
    assert m.orders[1].fee_reserve == 0  # maker reserve refunded on resting
    bid = m.place_order("buyer", 0, "Bid", 50, 2)
    assert bid == {"orderId": 2, "filled": 2, "resting": 0}
    assert m.series[0].pool == 2 * UNIT
    assert m._user_token("buyer", 0, "YES") == 2
    assert m._user_token("writer", 0, "NO") == 2
    assert m.accounts["writer"].locked == TICK_UNIT * 60
    assert m.protocol_fees == 2 * 40 * TICK_UNIT // 100
    assert m.recent_trades(0)[0] == {"ts": 0, "tick": 40, "qty": 2, "takerIsBuyer": True}
    m.assert_invariants()

    # Escrow alone is insufficient when the maximum taker fee reserve is due.
    n = BookModel(["u"], taker_fee_bps=100)
    n.create_series(0, 10_000)
    n.deposit("u", 50 * TICK_UNIT)
    failed = n.apply({"kind": "place", "user": "u", "series": 0, "side": "Bid",
                      "tick": 50, "qty": 1})
    assert failed == {"ok": False, "error": "InsufficientCash"}
    assert n.next_order_id == 1
    n.deposit("u", TICK_UNIT // 2)
    resting = n.place_order("u", 0, "Bid", 50, 1)
    assert resting == {"orderId": 1, "filled": 0, "resting": 1}
    assert n.accounts["u"].locked == 50 * TICK_UNIT
    assert n.accounts["u"].cash == TICK_UNIT // 2  # unused fee reserve refunded
    assert n.orders[1].fee_reserve == 0
    n.assert_invariants()


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
    crossing = m.apply({"kind": "place", "user": "c", "series": 0, "side": "Bid",
                        "tick": 45, "qty": 1, "tif": "POST_ONLY"})
    assert crossing == {"ok": False, "error": "WouldCross"}
    assert m.cancel("a", 3) is None
    assert m.orders[older["orderId"]].open

    # POST_ONLY rejects even the caller's own crossing maker before STP.
    self_cross = m.apply({"kind": "place", "user": "b", "series": 0, "side": "Bid",
                          "tick": 50, "qty": 1, "tif": "POST_ONLY"})
    assert self_cross == {"ok": False, "error": "WouldCross"}
    m.assert_invariants()


def test_stp_cancellations_consume_max_fills_and_ids_are_sequential():
    m = BookModel(["u", "v"], taker_fee_bps=0)
    m.create_series(0, 10_000)
    for u in ("u", "v"):
        m.deposit(u, 100 * UNIT)
    own = m.place_order("u", 0, "Ask", 40, 1)
    other = m.place_order("v", 0, "Ask", 41, 1)
    post_only = m.apply({"kind": "place", "user": "u", "series": 0, "side": "Bid",
                         "tick": 50, "qty": 1, "tif": "POST_ONLY"})
    assert post_only == {"ok": False, "error": "WouldCross"}

    # Cancelling the best self order consumes the sole maxFills slot.
    bounded = m.place_order("u", 0, "Bid", 50, 1, max_fills=1)
    assert bounded == {"orderId": 3, "filled": 0, "resting": 0}
    assert not m.orders[own["orderId"]].open
    assert m.orders[other["orderId"]].open

    # A later immediate fill still consumes an id; the next placement gets id 5.
    immediate = m.place_order("u", 0, "Bid", 50, 1, tif="IOC", max_fills=1)
    assert immediate == {"orderId": 4, "filled": 1, "resting": 0}
    resting = m.place_order("v", 0, "Ask", 90, 1)
    assert resting["orderId"] == 5
    m.assert_invariants()


def test_close_no_taker_and_maker_against_both_ask_kinds():
    users = ["closer", "writer", "yesSeller", "closeMaker", "writeTaker", "heldTaker"]
    m = BookModel(users, taker_fee_bps=25)
    m.create_series(0, 10_000)
    for user in users:
        m.deposit(user, 20 * UNIT)
        m.split(user, 0, 5)

    # Taker close-NO against a resting write Ask: NO is transferred to the writer;
    # the writer's new collateral funds the close proceeds without changing pool/supply.
    pool_before = m.series[0].pool
    supply_before = (m.total_supply(0, "YES"), m.total_supply(0, "NO"))
    m.place_order("writer", 0, "Ask", 40, 1)
    cash_before = m.accounts["closer"].cash
    m.place_order("closer", 0, "Bid", 50, 1, from_held=True)
    assert m.accounts["closer"].cash - cash_before == 60 * TICK_UNIT - 60 * TICK_UNIT * 25 // 10_000
    assert m._user_token("writer", 0, "NO") == 6
    assert m.series[0].pool == pool_before
    assert (m.total_supply(0, "YES"), m.total_supply(0, "NO")) == supply_before

    # Taker close-NO against a held-YES Ask: both tokens burn and pool releases UNIT.
    pool_before = m.series[0].pool
    supply_before = (m.total_supply(0, "YES"), m.total_supply(0, "NO"))
    m.place_order("yesSeller", 0, "Ask", 35, 1, from_held=True)
    cash_before = m.accounts["closer"].cash
    m.place_order("closer", 0, "Bid", 45, 1, from_held=True)
    assert m.accounts["closer"].cash - cash_before == 65 * TICK_UNIT - 65 * TICK_UNIT * 25 // 10_000
    assert m.series[0].pool == pool_before - UNIT
    assert (m.total_supply(0, "YES"), m.total_supply(0, "NO")) == (
        supply_before[0] - 1, supply_before[1] - 1
    )

    # Resting close-NO bid against a write Ask taker: escrowed NO replaces the
    # writer's new NO leg; bid maker receives UNIT gross, with no pool/supply delta.
    pool_before = m.series[0].pool
    supply_before = (m.total_supply(0, "YES"), m.total_supply(0, "NO"))
    cash_before = m.accounts["closeMaker"].cash
    m.place_order("closeMaker", 0, "Bid", 60, 1, from_held=True)
    m.place_order("writeTaker", 0, "Ask", 50, 1)
    assert m.accounts["closeMaker"].cash - cash_before == 40 * TICK_UNIT
    assert m._user_token("writeTaker", 0, "NO") == 6
    assert m.series[0].pool == pool_before
    assert (m.total_supply(0, "YES"), m.total_supply(0, "NO")) == supply_before

    # Resting close-NO bid against held-YES Ask taker: pair burns; fee is taken
    # from the held seller's proceeds, while the maker remains fee-free.
    pool_before = m.series[0].pool
    supply_before = (m.total_supply(0, "YES"), m.total_supply(0, "NO"))
    cash_before = m.accounts["closeMaker"].cash
    m.place_order("closeMaker", 0, "Bid", 60, 1, from_held=True)
    m.place_order("heldTaker", 0, "Ask", 45, 1, from_held=True)
    assert m.accounts["closeMaker"].cash - cash_before == 40 * TICK_UNIT
    assert m.accounts["heldTaker"].cash == 15 * UNIT + 60 * TICK_UNIT - (60 * TICK_UNIT * 25 // 10_000)
    assert m.series[0].pool == pool_before - UNIT
    assert (m.total_supply(0, "YES"), m.total_supply(0, "NO")) == (
        supply_before[0] - 1, supply_before[1] - 1
    )

    # Cancellation restores both cash and the escrowed NO token.
    no_before = m._user_token("closer", 0, "NO")
    cash_before = m.accounts["closer"].cash
    order = m.place_order("closer", 0, "Bid", 10, 1, from_held=True)
    m.cancel("closer", order["orderId"])
    assert m._user_token("closer", 0, "NO") == no_before
    assert m.accounts["closer"].cash == cash_before
    m.assert_invariants()


def test_time_bounds_long_data_and_settlement():
    m = BookModel(["alice", "bob"], now=1_000)
    m.create_series(0, 2_000)
    m.create_series(1, 2_000)
    m.deposit("alice", 10 * UNIT)
    m.deposit("bob", 10 * UNIT)
    m.split("alice", 0, 4)

    for op in (
        {"kind": "split", "user": "alice", "series": 0, "qty": 0},
        {"kind": "split", "user": "alice", "series": 0, "qty": MAX_QTY + 1},
        {"kind": "merge", "user": "alice", "series": 0, "qty": 0},
        {"kind": "merge", "user": "alice", "series": 0, "qty": MAX_QTY + 1},
        {"kind": "place", "user": "alice", "series": 0, "side": "Bid", "tick": 50, "qty": 0},
        {"kind": "place", "user": "alice", "series": 0, "side": "Bid", "tick": 50, "qty": MAX_QTY + 1},
    ):
        out = m.apply(op)
        assert out == {"ok": False, "error": "BadQty"}

    long_data = m.apply({"kind": "create", "series": 2, "expiry": 3_000, "dataLength": 513})
    assert long_data == {"ok": False, "error": "DataTooLong"}
    at_expiry_trade = m.apply({"kind": "place", "user": "alice", "series": 0,
                               "side": "Bid", "tick": 50, "qty": 1, "at": 2_000})
    assert at_expiry_trade == {"ok": False, "error": "Expired"}
    assert m.apply({"kind": "resolve", "series": 0, "ready": True, "yes": True,
                    "at": 2_000}) == {"ok": False, "error": "NotExpired"}
    assert m.apply({"kind": "resolve", "series": 0, "ready": False,
                    "at": 2_001}) == {"ok": False, "error": "NotExpired"}
    assert m.apply({"kind": "resolve", "series": 0, "ready": True, "yes": True,
                    "at": 2_001}) == {"ok": True}

    assert m.apply({"kind": "resolve", "series": 1, "ready": False,
                    "at": 2_000}) == {"ok": False, "error": "NotExpired"}
    assert m.apply({"kind": "resolve", "series": 1, "ready": False,
                    "at": 2_000 + 2 * 24 * 3600}) == {"ok": True}
    assert m.series[1].status == "Void"
    assert m.redeem("alice", 0, 4, 4) == 4 * UNIT
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
    m.owner_withdraw_fees(0)
    assert m._user_snapshot() == user_before
    m.assert_invariants()


def run():
    tests = [
        test_write_bid_fee_and_order_reserve,
        test_held_ask_cancel_ioc_post_only_and_priority,
        test_stp_cancellations_consume_max_fills_and_ids_are_sequential,
        test_close_no_taker_and_maker_against_both_ask_kinds,
        test_time_bounds_long_data_and_settlement,
        test_reverts_are_atomic_and_owner_cannot_touch_users,
    ]
    for test in tests:
        test()
    print(f"book_model.py: {len(tests)} tests passed")


if __name__ == "__main__":
    run()

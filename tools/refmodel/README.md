# Montions independent reference model

`book_model.py` is a dependency-free, exact-integer model of SPEC §§3–4, including normative v0.2 amendments. It tracks cash/locked collateral, YES/NO ownership (including Book-held escrow), pools, FIFO levels, trades, fees, split/merge, cancellation, resolution and redemption. `apply()` is transaction-atomic for modeled state, retains the operation timestamp on revert, and asserts the seven §4.8 invariants after every operation.

Run from the repository root:

```sh
python3 tools/refmodel/test_model.py
python3 tools/refmodel/gen_vectors.py
```

The generator writes 12 deterministic scenarios to `test/diff/vectors/`, with fee rates cycling through **0, 25 and 100 bps**. Scenarios are roughly 95–128 KB, each with 235–280 operations and periodic state checkpoints. They cover immediate-fill/IOC order IDs, fee reserves, close-NO bids as taker and maker against both write and held-YES Asks, STP/maxFills, POST_ONLY against own orders, quantity bounds, oversized series data, strict expiry, fills, split/merge, cancellation, settlement and redemption.

## v0.2 decisions modeled

- Fee is `ceil(sum(takerCollateralConsumed) * bps / 10_000)` once per taker order. Cash-backed Bids and write Asks pre-lock the maximum fee reserve on top of escrow and refund unused reserve when the taker finishes or starts resting. A resting maker has no fee reserve and pays no fee. Held-token sells pay their fee from proceeds. Insufficient cash for escrow plus reserve fails up front.
- Every fill or STP cancellation consumes one `maxFills` slot.
- POST_ONLY rejects any crossing best opposite order before STP, including the caller's own order.
- `Bid.fromHeld` closes NO: placement escrows NO plus limit cash. Against a held-YES Ask, the escrowed pair burns and the pool pays UNIT; against a write Ask, the NO leg is transferred to the writer and the writer's collateral funds the close. In both cases the caller's net proceeds are `100 - makerTick` ticks and unused limit cash is released. The same accounting applies when the close-NO bid rests as maker against either kind of Ask. `Ask.fromHeld` continues to sell held YES.
- Resolve at or before expiry reverts `NotExpired`; a not-ready resolver also reverts `NotExpired` until VOID_GRACE. Trading is allowed only before expiry; resolver readiness in the replay mock requires `timestamp > expiry`.
- Successful placements consume sequential IDs starting at 1, including fully-filled and IOC orders.
- Place/split/merge quantities must be `1..2^40-1`; otherwise `BadQty`. Series data over 512 bytes is modeled as `DataTooLong`. The replay harness accepts any revert for that one oversized-data operation because the interface has no `DataTooLong` selector.

`test/diff/DiffReplay.t.sol` uses `deployCode("MontionsBook.sol:MontionsBook", ...)` and imports only the frozen interface, so it builds without the Book source. It replays each vector when the Book artifact exists, checks each operation's result/custom error, and compares cash, locked cash, token balances/supply, pools, depth, trades, status and collateral conservation at checkpoints and end state. The model itself checks all seven invariants after every operation.

The harness matches exactly these interface custom-error names: `BadTick`, `BadQty`, `SeriesNotOpen`, `SeriesExists`, `SeriesUnknown`, `ResolverNotAllowed`, `BadExpiry`, `NotExpired`, `AlreadySettled`, `NotOrderOwner`, `OrderNotOpen`, `InsufficientCash`, `InsufficientTokens`, `WouldCross`, `Expired`, `FeeTooHigh`. `DataTooLong` is deliberately excluded and handled by the oversized-data any-revert case.

No v0.2 ambiguity remains open in this model. Replay execution against a deployed Book remains conditional on that separately-owned artifact being present.

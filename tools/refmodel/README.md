# Montions independent reference model

`book_model.py` is a dependency-free, exact-integer model of SPEC §§3–4. It supports both the v0.1 Book behavior and normative v0.2 amendments. It tracks cash/locked collateral, YES/NO ownership (including Book-held escrow), pools, FIFO levels, trades, fees, split/merge, cancellation, resolution and redemption. `apply()` is transaction-atomic for modeled state, retains the operation timestamp on revert, and asserts the seven §4.8 invariants after every operation.

Run from the repository root:

```sh
python3 tools/refmodel/test_model.py
python3 tools/refmodel/gen_vectors.py
forge test --match-path 'test/diff/*' -vv
DIFF_MODE=v02 forge test --match-path 'test/diff/*' -vv
```

The default replay is `DIFF_MODE=v01`, loading `scenario_NN.json`; `DIFF_MODE=v02` loads `scenario_NN_v02.json`. Vectors flag v0.2-dependent operations with `v02Features` (`A3`, `A4`, `A7`). The v0.1 scenarios omit A3 close-NO orders; fees and A7 boundary inputs use v0.1 expectations so they still test the current Book behavior. The v0.2 mode replays all operations and expects all amendments. Against the current pre-amendment Book, v0.2 fails on the oversized-data A7 operation before reaching later A3/A4 differences.

The generator writes 12 deterministic scenarios per mode to `test/diff/vectors/`, with fee rates cycling through **0, 25 and 100 bps**. Scenarios have periodic state checkpoints. They cover immediate-fill/IOC order IDs, fees, close-NO bids as taker and maker against both write and held-YES Asks, STP/maxFills, POST_ONLY against own orders, quantity bounds, oversized series data, strict expiry, fills, split/merge, cancellation, settlement and redemption.

## Mode-specific behavior

- V0.1 charges the legacy premium fee on each fill, without a prepaid reserve. It rejects `Bid.fromHeld` with `BadQty`, matching the current Book. V0.1 does not enforce the A7 maximum quantity or data length; the oversized-data replay resolver accepts arbitrary input so that this difference is observable.
- V0.2 fees are `ceil(sum(takerCollateralConsumed) * bps / 10_000)` once per taker order. Cash-backed Bids and write Asks pre-lock the maximum fee reserve on top of escrow and refund unused reserve when the taker finishes or starts resting. A resting maker has no fee reserve and pays no fee. Held-token sells pay their fee from proceeds. Insufficient cash for escrow plus reserve fails up front.
- Every fill or STP cancellation consumes one `maxFills` slot.
- POST_ONLY rejects any crossing best opposite order before STP, including the caller's own order.
- `Bid.fromHeld` closes NO: placement escrows NO plus limit cash. Against a held-YES Ask, the escrowed pair burns and the pool pays UNIT; against a write Ask, the NO leg is transferred to the writer and the writer's collateral funds the close. In both cases the caller's net proceeds are `100 - makerTick` ticks and unused limit cash is released. The same accounting applies when the close-NO bid rests as maker against either kind of Ask. `Ask.fromHeld` continues to sell held YES.
- Resolve at or before expiry reverts `NotExpired`; a not-ready resolver also reverts `NotExpired` until VOID_GRACE. Trading is allowed only before expiry; resolver readiness in the replay mock requires `timestamp > expiry`.
- Successful placements consume sequential IDs starting at 1, including fully-filled and IOC orders.
- Place/split/merge quantities must be `1..2^40-1`; otherwise `BadQty`. Series data over 512 bytes is rejected. The replay harness accepts any revert for that oversized-data operation because the frozen interface has no `DataTooLong` selector.

`test/diff/DiffReplay.t.sol` uses `deployCode("MontionsBook.sol:MontionsBook", ...)` and imports only the frozen interface, so it builds without the Book source. It replays each vector when the Book artifact exists, checks each operation's result/custom error, and compares cash, locked cash, token balances/supply, pools, depth, trades, status and collateral conservation at checkpoints and end state. Cancel vectors contain explicit, real order IDs: the generator rejects zero, closed, unknown, or wrong-owner targets, and the harness verifies a successful cancel points to a live caller-owned order via `orderInfo`. The model itself checks all seven invariants after every operation.

The harness matches exactly these interface custom-error names: `BadTick`, `BadQty`, `SeriesNotOpen`, `SeriesExists`, `SeriesUnknown`, `ResolverNotAllowed`, `BadExpiry`, `NotExpired`, `AlreadySettled`, `NotOrderOwner`, `OrderNotOpen`, `InsufficientCash`, `InsufficientTokens`, `WouldCross`, `Expired`, `FeeTooHigh`. `DataTooLong` is deliberately excluded and handled by the oversized-data any-revert case.

Scenario 00 deliberately configures the mock resolver to report ready at the exact expiry. The retained `NotExpired` expectation at op 233 is required by SPEC A6; the current Book resolves successfully because its time guard rejects only timestamps strictly before expiry. This is a genuine Book discrepancy, not an A3/A4/A7 mode difference. Current results: V01 has 11 passing scenarios and this one expected failing discrepancy; V02 fails all 12 at the earlier, deliberate A7 oversized-data gap. A3/A4 are also still pending in the Book but are not reached in the current V02 run.

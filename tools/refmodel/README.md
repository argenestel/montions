# Montions independent reference model

`book_model.py` is a dependency-free, exact-integer model of SPEC §3–4. It tracks free/locked collateral, YES/NO holdings (including YES escrow held by the Book), per-series pool and settlement state, FIFO price levels and occupancy masks, maker-tick trades, fees, the 64-trade ring, volume, split/merge, cancellation, resolution, and redemption. `apply()` gives operations transaction-like atomicity and calls invariant assertions after successful operations and modeled reverts.

Run the direct assertions and regenerate the deterministic replay corpus from the repository root:

```sh
python3 tools/refmodel/test_model.py
python3 tools/refmodel/gen_vectors.py
```

The generator uses seeds 0–9 and writes 10 compact JSON scenarios to `test/diff/vectors/`. Each has at least 200 operations and a checkpoint every 10 operations plus an end state. The corpus includes 1–3 series, both resolved outcomes and unresolved/void series, fills and partial fills, held-token asks, IOC/POST_ONLY, max-fills truncation, STP, cancellations (including post-resolution), fees, split/merge, resolve and redeem. `MockResolver` consumes `abi.encode(uint256 outcome)`: 0 resolves NO, 1 resolves YES, and 2 stays not-ready until VOID_GRACE.

`test/diff/DiffReplay.t.sol` deploys the Book from the Foundry artifact using `deployCode("MontionsBook.sol:MontionsBook", ...)`; it imports only the frozen interface, so it compiles without the separately-owned Book source. Individual replay tests are skipped when that artifact is absent. When present, each op is checked for its return tuple or custom-error selector and every checkpoint checks cash, locked cash, token balances/supply, pool, depth, best bid/ask, trade ring, last tick, volume, and collateral conservation. Mismatches include the vector name and operation index. The current sandbox `foundry.toml` grants filesystem access only to `deployments/`; the main agent must add read permission for `test/diff/vectors/` before running with the Book artifact, because Foundry rejects `vm.readFile` outside configured paths.

## Modeling choices / SPEC ambiguities

These choices make the model executable but need confirmation against the Book implementation / owner interpretation:

1. **Fee rounding and source:** the model sums execution premiums across a taker order, applies `ceil(totalPremium * bps / 10_000)` once, then debits free cash. The spec gives the ceil formula but does not say whether rounding is once per order or once per fill, nor how fees are reserved/collected if the taker has no free cash after escrow. Vectors use 100 bps and well-funded users, avoiding rounding and insufficient-fee-cash ambiguity.
2. **`maxFills` and STP:** the model counts successful fills toward the bound; STP cancellations do not consume a fill. “maxFills bounds the loop” could instead mean loop iterations, which would make STP cancellations consume the bound.
3. **Post-only + self trade:** the model treats any eligible opposite order as `WouldCross` before matching, including an order by the same user. The spec says POST_ONLY reverts if any match would occur while STP says a same-user order is canceled and matching continues; whether POST_ONLY should first apply STP is unspecified.
4. **`fromHeld` on Bid:** the field is declared for Ask only, but there is no specified error for setting it on Bid. The model rejects it as `BadQty`; generated vectors do not exercise this undefined input.
5. **Unready resolver error:** §4.5 says to revert `NotExpired`/not-ready before VOID_GRACE, but the frozen interface declares no `NotReady` custom error. The model and vectors use `NotExpired` for that case.
6. **Order IDs without resting:** the model allocates a sequential ID for every successful placement, including fully filled or IOC placements, and a revert rolls the ID back. The return type implies an ID, but the text does not explicitly specify allocation for non-resting takers.
7. **Zero split/merge quantities:** the model rejects `q == 0` as `BadQty`, inferred from the interface error but not stated explicitly by the split/merge prose. The vectors do not exercise zero quantities.

The generator deliberately avoids invalid/unsupported inputs beyond POST_ONLY and the pre-grace resolver revert, so it does not impose choices for unspecified error ordering. Resolved/void redemption rounds exactly in base units because UNIT is even; no odd-half-unit case exists for whole-contract quantities.

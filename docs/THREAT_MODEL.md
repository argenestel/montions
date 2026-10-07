# Threat model (v0.2)

## Assets
User collateral (USDC) held by `MontionsBook`; outcome tokens; vault depositor funds; protocol fees.

## Trust assumptions
| Component | Assumption |
|---|---|
| Collateral token | Exact-transfer, non-rebasing, 6 decimals. **USDC is issuer-controlled: Circle can blacklist an address (including the Book) or upgrade the token.** This is an unavoidable custody risk of using USDC. |
| Price source (mainnet) | Pyth: signed price updates verified onchain by the Pyth contract. We trust Pyth's publishers/aggregation and its contract upgrade key. |
| Price source (testnet/demo) | Pool-TWAP over a mock AMM — **manipulable at low liquidity; demo only.** |
| Owner | Can: allow/deny resolvers for NEW series, set fee ≤ 100 bps, pause NEW risk, set caps, sweep stray native currency. **Cannot:** move user cash/locked/tokens, alter an outcome, block `cancel`/`merge`/`resolve`/`redeem`/`withdraw`. Ownership uses a two-step handover and should be a multisig (Safe). |
| Keepers | Untrusted and permissionless: anyone can settle/resolve/refresh. Liveness only. |

## Main risks and mitigations
1. **Oracle manipulation / wrong settlement.** Mainnet settles from Pyth's *first published price at or after expiry* via `parsePriceFeedUpdatesUnique`: deterministic, nobody can choose a favourable timestamp. Wide-confidence or non-positive prices make the series *invalid* → Book voids it 50/50 after the grace period. Residual: Pyth itself being wrong.
2. **Settlement liveness.** If no valid price is submitted within the window the market is voided (50/50) after `VOID_GRACE` (2 days) — funds are never stuck.
3. **Book accounting bugs.** 7 invariants (pool == supply × UNIT, cash conservation, escrow == open orders, level/bitmap consistency, …) tested under stateful fuzzing and differentially against an independent model.
4. **Griefing / DoS.** Bounded matching loop (`maxFills` ≤ 256), ≤ 512-byte series data, quantity caps, STP, dust-wall limits are documented; permissionless `createSeries` is restricted to owner-allowlisted resolvers and oracles.
5. **Unaudited-launch loss limits.** Owner-set `collateralCap` and `seriesPoolCap`, plus vault `maxTotalAssets`, bound the worst case; caps are raised in stages.
6. **MakerVault adverse selection.** Resting quotes lose to informed flow. Per-series (≤ 0.8–1% NAV) and global (≤ 30% NAV, ≥ 20% free cash) exposure caps, no quoting near expiry, keeper-only refresh, ERC-4626 inflation defence. **The vault can still lose money; depositors must understand this.**
7. **Frontend risk.** Static page, no backend; CSP in production builds; every number shown is read from contracts; slippage limit and re-quote before sending; mainnet risk gate.

## Not mitigated / out of scope
USDC freezing; Pyth outage beyond the void path; chain halts/reorgs; legal/regulatory restrictions on binary options in your jurisdiction; user wallet compromise.

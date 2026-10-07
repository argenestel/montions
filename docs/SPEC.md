# Montions — Spec (v0.1)

Outcome-first binary options on Monad with a **fully onchain central limit order book**. Every component that
decides money lives in a contract: the order book, collateral, settlement oracle (TWAP from onchain pools),
fair-value model, a market-making vault, and the data views the UI reads. No indexer, no offchain matcher, no
signed price feeds. The frontend is a static page that reads the chain over RPC.

Target: Monad testnet (chain 10143, RPC https://testnet-rpc.monad.xyz). Solidity 0.8.28, EVM `cancun`, Foundry,
Solady (`lib/solady`) for ERC20/ERC1155/FixedPointMath/ReentrancyGuard/Multicallable/SafeTransferLib/Ownable.

## 1. Product

A *series* is a yes/no question settled by a resolver contract. A *contract* pays 1 USDC if its outcome is true.
Example: "MON finishes above $1.50 at 12:00 UTC (60s TWAP)". YES at 35 ticks costs $0.35 and pays $1.00.
NO costs 100 - (YES price) ticks. Users never see ticks: the UI is a sentence ("I want to make $1,000 if MON
ends above $1.50 by Friday") that is compiled to quotes against the book.

Value capture: taker fee (0–100 bps on premium, default 0 for the hackathon), MakerVault performance fee (later).

## 2. Components and owners

| Path | What | Owner |
|---|---|---|
| `src/interfaces/*` | frozen interfaces (change only via main agent) | main |
| `src/MontionsBook.sol`, `src/libs/*` | series registry, CLOB, escrow, split/merge, resolution, ERC1155 outcome tokens | **book** |
| `src/mocks/*` | MockERC20 (faucet), tUSDC (6 dec, EIP-2612 permit, faucet) | **oracle** |
| `src/oracle/SpotPool.sol`, `OracleHub.sol` | onchain constant-product pools with TWAP ring buffer; hub implements `IPriceOracle` | **oracle** |
| `src/pricing/PricingLib.sol` | normal CDF, digital-option fair probability, tick rounding | **pricing** |
| `src/resolvers/*` | `TwapThresholdResolver`, `TimelockOpResolver` | **pricing** |
| `src/Quoter.sol` | `IQuoter` implementation | **quoter** |
| `src/MakerVault.sol` | onchain market maker (ERC4626-style shares) | **vault** |
| `script/*`, `bots/*` | Foundry deploy/seed scripts, TS price bot + keeper | **deploy** |
| `sdk/*` | TS SDK (viem): ABIs, tick/quote/payoff math, sentence→params | **sdk** |
| `app/*` | frontend | main |
| `test/**` | each owner tests their own area; `test/invariant/*` owned by **invariants** | — |

## 3. Units

- Collateral = USDC-like token, **6 decimals**. `UNIT = 1_000_000` pays out per winning contract.
- Prices are ticks `1..99`; `TICK_UNIT = 10_000`. `TICKS = 100`.
- A BID at tick `p` for `q` contracts escrows `q * p * TICK_UNIT`.
- An ASK (write) at tick `p` for `q` contracts escrows `q * (100 - p) * TICK_UNIT`.
- Oracle prices: USD per one whole asset unit, 1e18-scaled.

## 4. MontionsBook semantics (normative)

### 4.1 Series
- `seriesId = keccak256(abi.encode(resolver, data, expiry))`. Permissionless `createSeries`; resolver must be allowed by owner;
  `resolver.validate(data, expiry)` must not revert; `now + MIN_DURATION <= expiry <= now + MAX_DURATION`.
- Token ids: `yesId = uint256(keccak256(abi.encode(seriesId, "YES")))`, `noId = ...("NO")`.
- Enumeration via `seriesCount/seriesIdAt/seriesIds`. Status: Open → Resolved | Void.

### 4.2 Cash account
Users `deposit` USDC into the Book (`depositWithPermit` for one-signature UX) and `withdraw` free cash.
All escrow and fills move internal `cash` / `locked` bookkeeping only; no ERC20 transfer inside the matching loop.
`lockedCash(user)` = sum of USDC escrowed in the user's resting orders.

### 4.3 Orders
`placeOrder(PlaceParams)` returns `(orderId, filled, resting)`. Reverts `Expired` if `block.timestamp >= expiry`.
Order ids are sequential from 1. Matching is **price-time priority**; trade price = **resting (maker) order's tick**.

**Bid (buy YES) taker at limit L** — matches resting Asks with tick ≤ L, lowest tick first, FIFO inside a tick.
- Taker locks `qty*L*TICK_UNIT` up front; each fill at maker tick `p` costs `p*TICK_UNIT` per contract, the difference `(L-p)*TICK_UNIT` is released back to free cash.
- Maker is a *write* ask: their locked `(100-p)*TICK_UNIT` per contract stays in the series pool, taker's `p*TICK_UNIT` goes to the pool: pool += UNIT per contract; mint YES to taker, NO to maker.
- Maker is a *fromHeld* ask: YES tokens escrowed in the Book transfer to taker; maker's cash += `p*TICK_UNIT` per contract; no pool change, no minting.

**Ask (sell YES) taker at limit L** — matches resting Bids with tick ≥ L, highest tick first.
- Write (`fromHeld=false`): taker locks `qty*(100-L)*TICK_UNIT`; each fill at bid tick `p` consumes `(100-p)*TICK_UNIT` per contract (≤ locked; difference `(p-L)*TICK_UNIT` released). Pool += UNIT per contract (bid maker's escrowed `p*TICK_UNIT` + writer's `(100-p)*TICK_UNIT`). Mint YES to bid maker, NO to taker.
- `fromHeld=true`: taker's `qty` YES tokens move into Book escrow at placement; each fill transfers YES to bid maker and credits taker cash `p*TICK_UNIT` per contract.
- Unfilled remainder of a GTC order rests at its limit tick (collateral/tokens stay locked); IOC drops the remainder (refund); POST_ONLY reverts `WouldCross` if any match would occur.
- Self-trade prevention: if the best resting order's maker == taker, cancel that resting order (refund it) and continue.
- Taker fee: `fee = ceil(notionalPremium * takerFeeBps / 10_000)` where `notionalPremium = qty_filled * tick * TICK_UNIT`; paid from the taker's cash, added to `protocolFees`. Makers pay nothing.
- `maxFills` bounds the loop (0 ⇒ 32). Hitting the bound ends matching; GTC remainder then rests *only if it does not cross*; otherwise (still crossing) it is returned as `resting = 0` and refunded (document this in NatSpec).
- No external calls inside the matching loop. Outcome-token credits from fills must not invoke ERC1155 receiver hooks (so contracts like MakerVault can be makers safely). Plain `safeTransferFrom` by users may.

### 4.4 Cancel, split, merge
- `cancelOrder` owner only, any time (even after expiry); refunds remaining escrow.
- `split(seriesId, q)`: free cash -= q*UNIT; pool += q*UNIT; mint q YES + q NO. Only while Open and before expiry.
- `merge(seriesId, q)`: burn q YES + q NO; pool -= q*UNIT; cash += q*UNIT. Allowed while Open (before or after expiry, until resolved).

### 4.5 Resolution
- `resolve(seriesId)` after `expiry`: staticcall `resolver.resolve(data, expiry)` with gas cap 500k. If `ready` → Resolved(yes). If not ready (or call reverts) and `now >= expiry + VOID_GRACE` → Void. Otherwise revert `NotExpired`/not-ready.
- Redeem: Resolved ⇒ payout = `(yes ? yesQty : noQty) * UNIT`, the losing side's tokens burn for 0; Void ⇒ `(yesQty+noQty) * UNIT / 2`. Payout credited to free cash. `pool[seriesId] -= payout`.
- Resting orders are not auto-cancelled at resolution; users cancel to reclaim.

### 4.6 Views (must not require event logs)
`bestBidAsk`, `depth` (aggregated qty per tick via per-tick running totals), `orderInfo`, `ordersOf(user, offset, limit)` (newest first), `recentTrades` (ring buffer of last 64 per series), `lastTradeTick`, `volumeOf`, plus all `IMontionsBook` getters.

### 4.7 Data structures (suggested, not mandatory)
Per series & side: `uint128` occupancy bitmask over ticks 1..99 (best bid = highest set bit, best ask = lowest set bit);
per tick: doubly-linked FIFO of order ids with `head/tail` and `levelQty`. Orders packed in ≤ 2 slots.

### 4.8 Invariants (the invariant tests assert these)
1. For every Open series: `pool == totalSupply(yesId) * UNIT == totalSupply(noId) * UNIT` (YES tokens held in Book escrow count as supply).
2. After Resolved(yes=true): `pool == totalSupply(yesId) * UNIT` still; (yes=false): `pool == totalSupply(noId) * UNIT`... until losing tokens are burned in `redeem`; every winning token is redeemable for exactly UNIT. Void: `pool*2 == (yesSupply+noSupply)*UNIT` holds for tokens not yet redeemed.
3. `USDC.balanceOf(book) == Σ cash + Σ locked + Σ pool + protocolFees` (exact, absent donations).
4. `Σ locked(user) == Σ over open orders of their escrow` (Bid: `qty*tick*TICK_UNIT`, write Ask: `qty*(100-tick)*TICK_UNIT`, fromHeld Ask: 0 cash).
5. Level quantities equal the sum of open order remaining qty at that tick; occupancy bitmask bit set ⇔ level qty > 0.
6. Price-time priority: for every trade, no better-priced or older same-priced resting order on the opposite side was skipped (except STP cancels).
7. Owner can never reduce any user's cash/locked/token balances.

## 5. Oracle (src/oracle)

`SpotPool(baseToken, quoteToken=tUSDC)`: constant-product, 0.30% fee, `addLiquidity` (owner only for the demo), `swapExactIn`.
Observations: struct `{uint32 ts; uint224 cum (price*seconds, 1e18-scaled, wraps allowed with care); uint192 price}` in a ring of 1024.
A new observation is written on the first swap of each block (Uniswap-v2 style) and by `checkpoint()` (anyone).
`OracleHub` registers `assetId => pool` (owner), implements `IPriceOracle` incl. `twapAt` via binary search on the ring (+ extrapolation with the
following observation's price), and `realizedVol` (annualised stdev of log returns of `step`-second TWAP samples; use Solady `lnWad`).
`assetId = keccak256("MON")`, `keccak256("NVDA")`, ... Mock assets: `tMON` (18 dec), `tNVDA` (18 dec, labelled MOCK tokenized equity).
**Honesty requirement:** docs/NatSpec must state that pool-TWAP oracles are manipulable at low liquidity and that the demo uses deep seeded pools.

## 6. Resolvers (src/resolvers)

`TwapThresholdResolver` — `data = abi.encode(address oracle, bytes32 assetId, uint256 strikeWad, bool above, uint32 window)`.
`resolve`: `ready = block.timestamp > expiry`; price = `oracle.twapAt(assetId, expiry, window)` (revert ⇒ not ready);
`yes = above ? price >= strike : price < strike`. `validate`: asset exists, strike > 0, `30 <= window <= 3600`.
Also exposes `decode(data)` and `describe` ("MON ≥ $1.50 at 12:00 UTC (60s TWAP)").

`TimelockOpResolver` — `data = abi.encode(address timelock, bytes32 operationId)`; YES iff `ITimelock(timelock).isOperationDone(id)` at/after expiry
(ready after expiry; if not done by expiry, still resolves NO). This is the UpgradePut-style "did this governance migration execute" market and shows the
Book is a generic outcome market, not only a price-option venue.

## 7. Pricing (src/pricing/PricingLib.sol)

Digital (cash-or-nothing) fair probability, zero rate: `P(S_T > K) = N(d2)`, `d2 = (ln(S/K) - σ²T/2) / (σ√T)`.
All WAD fixed point; `normCdfWad(int256 x)` with absolute error < 1e-4 (Abramowitz–Stegun 7.1.26/26.2.17 or Hart; document the choice);
`digitalProbWad(spot, strike, vol, secondsToExpiry, above)`; `probToTick(probWad)` clamps to 1..99 with round-to-nearest.
Edge cases: T = 0, σ = 0, extreme moneyness must not revert (clamp). Fuzz-compare against a Python/mpmath golden table (check in `test/pricing/golden.json`).

## 8. Quoter (src/Quoter.sol)
Implements `IQuoter`: `fair` (uses resolver `decode` when the series resolver is the configured `TwapThresholdResolver`; otherwise zeros),
`quoteBuy/quoteSell` walk the book via `IMontionsBook.depth`/`bestBidAsk` (buy NO = hit bids, price per NO = 100 - bidTick), `snapshot(s)` bundles everything the UI needs in one call.
Default vol: `oracle.realizedVol(asset, 6h, 5min)` floored at 30% annualised and capped at 400%; if 0, use 80%.

## 9. MakerVault (src/MakerVault.sol)
ERC4626-style vault over the Book collateral. Anyone may call `refresh(seriesId)`: cancels the vault's stale orders for the series and posts a symmetric ladder (3 levels per side, 2-tick spacing, half-spread
= `max(2 ticks, 4 * time-decay width)`) around `Quoter.fair`, sized so total exposure per series ≤ `maxSeriesExposureBps` (default 10%) of NAV, not quoting when `timeToExpiry < 10 min`,
price series only. Vault never lends or leaves the Book; withdrawals only from free cash; NAV = free cash + locked + inventory marked at fair (settled series at redemption value).
Owner-set params only within hard caps; owner cannot withdraw depositor funds. Document adverse-selection risk honestly.

## 10. Deploy / bots (script, bots)
`script/Deploy.s.sol` deploys tUSDC, tokens, pools, OracleHub, resolvers, Book (allowing both resolvers), Quoter, MakerVault and writes `deployments/<chain>.json`:
`{ chainId, rpc, contracts: {name: address}, assets: [{symbol, assetId, pool, token, decimals}], startBlock }`.
`script/Seed.s.sol` seeds pools (MON ≈ $1.00 demo price, NVDA ≈ $180 demo price), faucet, a rolling ladder of series (expiries +10m/+1h/+1d/+7d × 3 strikes × above/below), vault deposit, vault refresh.
`bots/` (TypeScript, viem): `price-bot` (random-walk swaps so TWAP moves; clearly labelled DEMO), `keeper` (create next series, `OracleHub.checkpoint`, `Book.resolve`, `Vault.refresh`).

## 11. SDK (sdk)
Pure TS, no React: ABIs (from forge artifacts), `ticks.ts`, `payoff.ts` (P&L at expiry for YES/NO positions), `sentence.ts` (payout/asset/strike/expiry/direction → series candidates + quoteBuy params), `client.ts` (viem read/write wrappers incl. `depositWithPermit + placeOrder` multicall), tests with vitest.

## 12. Conventions
- NatSpec on every external function. Custom errors. No `tx.origin`. `nonReentrant` on state-changing Book entry points. Checks-effects-interactions.
- Tests: Foundry unit + fuzz; every normative rule above has at least one test. Gas snapshot for `placeOrder` (0, 1, 10 fills).
- Agents work in a private copy (see AGENTS.md), never run `git`, and report any needed interface change instead of editing `src/interfaces/*`.
- Everything labelled MOCK/DEMO must be labelled in code comments and UI. No claim that the demo oracle is manipulation-resistant at low liquidity.

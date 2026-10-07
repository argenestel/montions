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

## 13. Constructors / public surface that other components may rely on (frozen)

```solidity
// src/mocks/TestUSDC.sol  (Solady ERC20 + EIP-2612 permit via Solady ERC20, 6 decimals, name "Test USDC", symbol "tUSDC")
constructor(address owner_);  function mint(address to, uint256 amount) external; /* owner only */  function faucet() external; /* 10_000e6 per address per 1 hour */
// src/mocks/MockERC20.sol (18 decimals default param)
constructor(string memory name_, string memory symbol_, uint8 decimals_, address owner_);  function mint(address to, uint256 amount) external; /* owner */  function faucet() external; /* 1_000 whole tokens per address per hour */

// src/oracle/SpotPool.sol
constructor(address base, address quote, address owner_);   // quote is tUSDC (6 dec); base 18 dec
function addLiquidity(uint256 baseAmt, uint256 quoteAmt) external;           // owner only
function swapExactIn(address tokenIn, uint256 amountIn, uint256 minOut, address to) external returns (uint256 out);
function priceWad() external view returns (uint256);                         // USD per 1 whole base, 1e18
function checkpoint() external;                                              // anyone: write an observation now
function observationCount() external view returns (uint256);
// src/oracle/OracleHub.sol  (implements IPriceOracle)
constructor(address owner_);  function registerAsset(bytes32 assetId, address pool, uint256 minQuoteReserve) external; /* owner, one-time per asset */ function isHealthy(bytes32 assetId) external view returns (bool);  function poolOf(bytes32 assetId) external view returns (address);
function checkpoint(bytes32 assetId) external;                                 // anyone

// src/resolvers/TwapThresholdResolver.sol (implements IResolver)
constructor(address trustedOracle, address owner_);  function decode(bytes calldata data) external pure returns (address oracle, bytes32 assetId, uint256 strikeWad, bool above, uint32 window);
function encode(address oracle, bytes32 assetId, uint256 strikeWad, bool above, uint32 window) external pure returns (bytes memory);
// src/resolvers/TimelockOpResolver.sol (implements IResolver)
constructor(address owner_); function setTimelockAllowed(address timelock, bool allowed) external;  function encode(address timelock, bytes32 operationId) external pure returns (bytes memory);

// src/pricing/PricingLib.sol  (internal library, WAD math)
function normCdfWad(int256 xWad) internal pure returns (uint256 pWad);
function digitalProbWad(uint256 spotWad, uint256 strikeWad, uint256 volWad, uint256 secondsToExpiry, bool above) internal pure returns (uint256 pWad);
function probToTick(uint256 probWad) internal pure returns (uint8 tick);

// src/MontionsBook.sol (implements IMontionsBook, is Solady Multicallable + ReentrancyGuard + Ownable-like)
constructor(address collateral_, address owner_);

// src/Quoter.sol (implements IQuoter)
constructor(address book_, address twapResolver_);

// src/MakerVault.sol
constructor(address book_, address quoter_, address owner_);   // ERC20 shares, name "Montions Maker Vault", symbol "mmUSDC", 6 decimals
function deposit(uint256 assets, address receiver) external returns (uint256 shares);
function withdraw(uint256 assets, address receiver, address owner_) external returns (uint256 shares);
function totalAssets() external view returns (uint256);
function refresh(bytes32 seriesId) external;
```

## 14. Amendments v0.2 (NORMATIVE — supersede any conflicting text above)

Source: independent adversarial reviews by Grok 4.6 and Codex Luna 6 (see research notes). Numbers are decisions, not suggestions.

**A1 Oracle / data trust.** `TwapThresholdResolver` is constructed with a single trusted oracle: `constructor(address trustedOracle, address owner_)`; `validate` reverts unless the decoded `oracle == trustedOracle`.
`TimelockOpResolver` has an owner-managed allowlist of timelock contracts (`constructor(address owner_)`, `setTimelockAllowed(address,bool)`); `validate` reverts for non-allowlisted timelocks.
`Book.createSeries` rejects `data.length > 512`. Quoter and MakerVault ignore any series whose resolver is not the configured TwapThresholdResolver.
Optional liquidity guard: `OracleHub.isHealthy(bytes32 assetId) returns (bool)` (pool quote reserve ≥ owner-set `minQuoteReserve[assetId]`); the TWAP resolver's `validate` requires it when the oracle exposes it (try/catch; absent ⇒ treated as healthy).

**A2 TWAP history.** SpotPool ring size = 8192 observations. At most ONE observation per `block.timestamp` (a second write at the same timestamp updates that observation in place, never advances the ring). Between observations the price used is the price of the observation at or before `t` (extrapolation uses the last PRE-t price). `OracleHub.registerAsset` is one-time per assetId. If history is unavailable `twapAt` reverts `HistoryUnavailable`; `resolve` then reverts "not ready" until `VOID_GRACE`, after which anyone may void.
NatSpec/UI must state: an attacker who moves the pool in the last seconds of an idle window influences the TWAP; mitigated only by depth + window, never eliminated.
`SpotPool.priceWad() = quoteReserves * 1e30 / baseReserves` for 6-decimal quote and 18-decimal base (USD per whole base, 1e18).

**A3 Selling NO (close-NO bids).** `PlaceParams.fromHeld` on a **Bid** means "buy YES to merge with NO I already hold": the Book escrows `qty` NO tokens (from the caller) plus cash `qty*L*TICK_UNIT`. Economically it is a sale of NO at price `100 - fillTick`: for each fill of `f` contracts at maker tick `p`, the caller's escrowed NO is consumed (burned against the YES leg or transferred to the writer — implementation's choice as long as pool/supply stay consistent), the caller's cash receives `f*(100-p)*TICK_UNIT` net, unused cash escrow `(L-p)*f*TICK_UNIT` is released. `Ask.fromHeld` still means "sell held YES". Update `IMontionsBook` NatSpec only; no signature change. `IQuoter.quoteSell(…, yes=false, …)` follows these rules (walks resting Asks).

**A4 Fees.** `fee = ceil( takerCollateralConsumed * takerFeeBps / 10_000 )`, one `ceil` per order, where `takerCollateralConsumed = Σ over fills` of: Bid ⇒ `fill*tick*TICK_UNIT`; write-Ask ⇒ `fill*(100-tick)*TICK_UNIT`; fromHeld sells ⇒ proceeds `fill*tick*TICK_UNIT` (Ask) / `fill*(100-tick)*TICK_UNIT` (close-NO bid). For Bids and write-Asks the maximum fee on the full limit is locked UP FRONT in addition to the escrow (`ceil(escrow*bps/10_000)`) and the unused reserve is refunded when the order finishes or is cancelled; for fromHeld sells the fee is deducted from proceeds. The fee is never taken from `pool`. Fee is 0 by default.

**A5 Reentrancy.** `nonReentrant` is applied per external state-changing function; `multicall` itself MUST NOT be `nonReentrant` (sequential inner calls each take and release the guard). The matching loop makes no external calls.

**A6 Time semantics.** Trading is allowed while `block.timestamp < expiry`; `resolve` requires `block.timestamp > expiry`; resolvers report ready iff `block.timestamp > expiry`. Resolver staticcall gas cap is 500k everywhere (ignore the "300k" wording in IResolver NatSpec). TimelockOpResolver: `yes = isOperationDone(operationId)` at the moment of the first successful `resolve` call (operations never become "undone"); a reverting timelock is "not ready" and voids after `VOID_GRACE`.

**A7 Bounds.** Max order `qty` = 2^40 - 1 contracts; per-level aggregate quantities are `uint128`; min qty 1; `data.length <= 512`. `maxFills` counts every matched or STP-cancelled resting order.

**A8 MakerVault hardening.** `refresh(seriesId)` is callable only by `owner` or an owner-set `keeper` (events emitted). Global caps enforced on every refresh: total worst-case exposure (locked + inventory at 100 for the losing side) ≤ 30% of NAV, free Book cash ≥ 20% of NAV after quoting; otherwise cancel quotes instead of posting. Ladder ticks are clamped to 1..99. ERC4626 inflation defence: virtual offset (decimalsOffset 6 or equivalent). `withdraw` first cancels the vault's own tracked orders (bounded: ≤ 8 orders per series, ≤ 64 per call) until enough cash is free; if still insufficient it reverts. NAV uses fair-value marks only for series that are Open and for which the model has data, and never marks above the best-ask for inventory that cannot be sold at that price (use `min(fair, bestBid-based conservative mark)` for YES inventory and symmetric for NO).

**A9 Collateral token.** The Book requires an exact-transfer, non-rebasing 6-decimal collateral (tUSDC). `deposit` must verify the balance delta equals `amount`.

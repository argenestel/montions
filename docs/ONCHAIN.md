# Montions onchain reference

Everything that touches money is a contract. The web app is a static page that reads these contracts over RPC: there is no backend, no matching server, no indexer and no signed price feed. This page is the reference for what is onchain and how to verify it yourself.

## Contracts

| Contract | Source | Role |
|---|---|---|
| `MontionsBook` | `src/MontionsBook.sol` | Series registry, central limit order book (tick bitmaps, FIFO queues), escrow, split/merge, resolution, redemption, ERC-1155 YES/NO outcome tokens |
| `Quoter` | `src/Quoter.sol`, `src/pricing/PricingLib.sol` | Fair value (digital-option `N(d2)`), book-walking quotes, one-call `snapshots()` for UIs |
| `MakerVault` | `src/MakerVault.sol` | ERC-4626-style market maker: posts a ladder around the fair value, capped per series and globally |
| `PythSettlementResolver` + `PythOracle` | `src/resolvers/`, `src/oracle/pyth/` | Mainnet settlement from Pyth's first price at or after expiry |
| `TwapThresholdResolver` + `OracleHub` + `SpotPool` | `src/resolvers/`, `src/oracle/` | Testnet/demo settlement from a 60 s TWAP of an onchain demo pool |
| `TimelockOpResolver` | `src/resolvers/` | Event markets ("did this governance operation execute?") |
| Collateral token | external | USDC on mainnet (AUSD optional); a mintable test token on testnet |

## Units

- 1 contract pays **1 collateral unit** (`UNIT = 1e6`, 6 decimals) if its outcome is true, else 0.
- Prices are integer **ticks 1–99** (cents). `TICK_UNIT = 1e4`, so one tick of one contract is `10_000` base units.
- YES at tick `t` costs `t` cents; NO at the same book costs `100 − t`. YES + NO is always exactly 1 unit, locked in the Book (100% collateralised).

## Lifecycle of a trade

1. **Fund and place** — one transaction: `Book.multicall([depositWithPermit(...), placeOrder(...)])`. The collateral permit is EIP-2612, so there is no separate approval transaction.
2. **Match** — `placeOrder` matches against resting orders by price-time priority, atomically, inside the Book. Filled YES/NO tokens are minted against locked collateral. Time-in-force: `GTC`, `IOC`, `POST_ONLY`.
3. **Hold or exit** — sell back into the book, `merge` YES+NO into collateral, or wait.
4. **Resolve** — after expiry anyone calls `resolve(seriesId)`. The series' resolver contract decides the outcome from onchain facts only.
5. **Redeem** — `redeem(seriesId, yesQty, noQty)` pays 1 unit per winning contract. If no valid oracle result arrives within `VOID_GRACE` (2 days) the series is **voided** and pays 50/50.

## Settlement

- **Mainnet:** `PythSettlementResolver` calls Pyth's `parsePriceFeedUpdatesUnique` and accepts the **first** price in `[expiry, expiry + 300 s]`. Nobody can choose a favourable timestamp. `PythOracle` reads pushed prices for pricing with a maximum age (default 3900 s, bound 7200 s).
- **Testnet:** `TwapThresholdResolver` reads a 60 s TWAP from `OracleHub`, fed by demo `SpotPool`s. This is labelled demo in the app and is manipulable at low liquidity. Pyth exists on Monad testnet, but its feeds are not pushed regularly there (hours stale), so a Pyth-priced testnet would need a Hermes key and a push bot.

## Reading the market without an indexer

| Need | Call |
|---|---|
| All markets with fair value and top of book | `Quoter.snapshots(offset, limit)` (limit ≤ 50) |
| Order book | `Book.depth(seriesId, side, maxLevels)` |
| Best bid / ask | `Book.bestBidAsk(seriesId)` |
| Recent trades | `Book.recentTrades(seriesId, n)` |
| A user's resting orders | `Book.ordersOf(user, offset, limit)` |
| Positions | ERC-1155 `balanceOf` / `balanceOfBatch` on the Book |
| Cash | `Book.cash(user)`, `Book.lockedCash(user)` |

Gotchas learned on Monad:

- Gas is charged on the **gas limit**, not gas used. Give transactions a realistic limit.
- Do not wrap large view calls (`Quoter.snapshots`) in Multicall3 on public RPCs: they run out of gas inside `aggregate3`. Call them directly.
- Some free RPC tiers cap `eth_call` gas or lack methods; keep a fallback list of endpoints that were tested.

## Safety controls

- The owner can **pause new risk only**: placing orders and creating series. Cancelling, withdrawing, merging, resolving and redeeming always work.
- Launch caps: total collateral, per-series pool, vault deposits. Owner is a two-step transfer (`Ownable2Step`-style) so it can be handed to a Safe.
- The owner can **never** move user funds or change an outcome. Allowed resolvers are an explicit allow-list (`setResolverAllowed`).
- `MakerVault` quotes only from a trusted resolver set, stops quoting near expiry, and caps exposure per series and globally; depositors can lose money.
- Threat model: `docs/THREAT_MODEL.md`. Reporting: `SECURITY.md`. This software is unaudited.

## Deployments

### Monad testnet (10143)

Explorer: https://testnet.monadexplorer.com

| Contract | Address |
|---|---|
| `MontionsBook` | `0x4094e4CC956d989580233034b6B898db4aE6b78e` |
| `Quoter` | `0x6EBFA2426f1ae0Bfd87fDFAFde093C1E583f457A` |
| `MakerVault` | `0x20D88194103F8aF56332e9A45bd39Ff6Cb631E1C` |
| Test collateral (mintable, `faucet()`) | `0x844EAC441D9c70Dc6745Ca1a41643995B7B04612` |
| `OracleHub` | `0xc907f4FEF8782d87f17D4CC181A3f0AE267735A3` |
| `TwapThresholdResolver` | `0x26F24a01ba7EE5C5Ca29f73b9BbB7d4cFAa0035e` |
| `TimelockOpResolver` | `0x95c443a409AafA0308EaFCDe93ED6fc59e4FA785` |
| MON demo pool / token | `0x3c82D5a0521e063bF4158DC4B9732dB1165beeC0` / `0xAE3Bc21Cf5A4bF961DbBeC69066A937b88e2704B` |
| NVDA demo pool / token | `0x393ac3CbE2c25771901A19664F1E80Ce7fB80893` / `0xc607bdAb40122fB3579bebde9D6a4019f9B9ab74` |

The machine-readable manifest the app uses is `app/public/deployment.testnet.json`.

### Monad mainnet (143)

Not deployed yet. Pyth: `0x2880aB155794e7179c9eE2e38200202908C17B43`. USDC: `0x754704Bc059F8C67012fEd69BC8A327a5aafb603`. AUSD: `0x00000000eFE302BEAA2b3e6e1b18d08D69a9012a`. See `docs/MAINNET.md` and `docs/LAUNCH_CHECKLIST.md`.

## Verify it yourself

```bash
RPC=https://testnet-rpc.monad.xyz
BOOK=0x4094e4CC956d989580233034b6B898db4aE6b78e
cast call $BOOK "seriesCount()(uint256)" --rpc-url $RPC
cast call $BOOK "collateral()(address)"  --rpc-url $RPC
cast call $BOOK "owner()(address)"       --rpc-url $RPC
cast call 0x6EBFA2426f1ae0Bfd87fDFAFde093C1E583f457A "snapshots(uint256,uint256)" 0 5 --rpc-url $RPC
```

Related: `docs/SPEC.md` (design), `docs/DEPLOY.md` and `docs/MAINNET.md` (operations), `docs/INTEGRATIONS.md` (partners).

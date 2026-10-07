# @montions/sdk

Strict TypeScript, ESM and viem 2; no React, indexer or event-log scanning. All
money amounts use `bigint` USDC base units (six decimals), quantities are whole
contracts, oracle prices/strikes are WAD (18 decimals), and timestamps are Unix
seconds. One winning contract pays one USDC. Order ticks range from 1 to 99.

## Build and validate

Requires Node 22+, pnpm 11+, and Foundry with solc 0.8.28 for ABI regeneration.
Run from `sdk/`:

```sh
pnpm install --frozen-lockfile
pnpm gen-abis
pnpm typecheck
pnpm test
pnpm build
```

`pnpm gen-abis` runs `forge inspect <Interface> abi --json` from the repository
root for the four frozen interfaces. Generated `src/abi/*.ts` files are delivery
artifacts and must be retained. ERC20/permit/faucet and MakerVault ABIs are
handwritten from SPEC §13. Foundry output/cache used by the generator stays in
`sdk/.foundry/`. No concrete Solidity implementations are required.

The package publishes compiled ESM and declarations from `dist/`; build before
importing `@montions/sdk`. `@montions/sdk/abi` exports the ABIs separately.

## Units and expiry payoff

```ts
import { parseUsdc, formatUsdc, tickToUsdc, pnlAtExpiry,
  steppedPayoffCurve } from '@montions/sdk';

const cost = tickToUsdc(35, 10n); // 3_500_000n ($3.50)
formatUsdc(cost);                // "$3.5"
parseUsdc('10.25');              // 10_250_000n
pnlAtExpiry({ side: 'YES', quantity: 10n, cost }, true); // 6_500_000n
const curve = steppedPayoffCurve({
  side: 'NO', quantity: 10n, cost,
  strikeWad: 1_500_000_000_000_000_000n,
});
```

Curve x coordinates are WAD prices; y coordinates are USDC P&L. An above series
wins YES at `price >= strike`, so NO loses exactly at the strike. These helpers
calculate resolved expiry outcomes, not mark-to-market values or a void payout.
USDC formatting truncates to the requested displayed precision; use
`formatUsdcExact` for exact ledger values and decimal strings for exact inputs.

## Demo risks

The collateral and asset tokens are MOCK/DEMO assets. Low-liquidity pool TWAPs
are manipulable; the demo assumes deep seeded pools. Vault shares face adverse
selection and withdrawal liquidity constraints. RPC reads and quote estimates
can become stale before execution. These SDK wrappers do not assert that the
concrete contracts, deployed Multicall3, or a live deployment have been audited.

## Outcome-first planning

`planSentence(input, candidates)` is pure: it does not fetch or scan logs. Feed
it snapshots from the configured TwapThresholdResolver and separately fetched
bid/ask depth. It decodes the canonical resolver data, or accepts explicit
`metadata: { asset, strikeWad, above }`. Other assets, strikes, expiries,
below-series rows and non-open statuses are ignored. Filter generic resolver
markets before passing them in.

```ts
import { planSentence } from '@montions/sdk';

const result = planSentence({
  asset: assetId,                 // bytes32 oracle asset id
  direction: 'below',
  strike: 1_500_000_000_000_000_000n,
  expiryCandidates: [expiry],
  payoffUsd: '1000.01',           // gross payout goal => 1001 contracts
  maxSlippageTicks: 2,
  feeBps: 0,                     // use the current Book fee, not a guess
}, [{ seriesId: snapshot.seriesId,
      snapshot: { ...snapshot, bids: depth.bids, asks: depth.asks } }]);

const plan = result.plans[0];
// plan.order contains the numeric Solidity enum values for placeOrder.
```

The planner's price cap is the model `fairTick` plus slippage (the complement
for NO), falling back to the executable best outcome price when the model is
unsupported. Limits clamp to 1..99. Above buys YES with Bid IOC; below buys NO
by writing an Ask IOC at `100 - maxNoTick`, `fromHeld=false`. This implements a
strictly-below outcome: NO loses at equality.

`expectedCost` and `maxLoss` include premium plus taker fee; implied probability
uses premium only. Model probabilities are WAD and are zero when unsupported.
`filledPayoff` and `maxProfit` use expected filled quantity, while `targetPayoff`
is the whole rounded contract goal. Check `complete`, `shortfall` and `filled`
before offering execution. An IOC can fill partially; a gross payout goal is
not a guaranteed profit or a guaranteed fill. Depth cannot reveal maker order
counts or self-trades, and the default matching cap is 32 fills, so plans are
estimates even with a fresh complete depth snapshot.

## Client and deployments

```ts
import { MontionsClient, monadTestnet } from '@montions/sdk';
import { loadDeployments } from '@montions/sdk/deployments'; // Node only

const deployment = loadDeployments(10143, '../deployments');
const client = new MontionsClient({ deployment, chain: monadTestnet, account });
const snapshots = await client.snapshots(0, 20);
const balances = await client.cashBalances(account.address);
const depth = await client.orderBookDepth(snapshots[0]!.seriesId);
const position = await client.positions(snapshots[0]!.seriesId, account.address);
```

In a browser, fetch/import the JSON and call `parseDeployment(manifest)` from
the main entry point. Inject a viem `walletClient` and `publicClient`, or provide
`transport`, `account` and addresses directly. Manifest `contracts` names such
as `MontionsBook`, `Quoter`, `TestUSDC`, `MakerVault` and `OracleHub` are mapped
to SDK addresses. Required Book/Quoter addresses must be present; collateral
and vault addresses are required only for their respective operations.

`loadDeployments` validates SPEC §10 manifests and returns `startBlock` as a
`bigint`. No deployment file is bundled: use the manifest produced by the
deploy agent. `monadTestnet` specifies chain 10143, native MON, the canonical
testnet RPC/explorer and Multicall3 at
`0xcA11bde05977b3631167028862bE2a173976CA11`.

Reads include `snapshots`, `snapshot`, `seriesInfo`, `depth`, `bestBidAsk`,
`orderBookDepth` (both sides in one batch), `orders`, `orderInfo`, `recentTrades`, `quoteBuy`, `quoteSell`, `positions`,
`cashBalances` and `collateralBalance`. Position reads use the frozen
`seriesInfo.yesId/noId` and ERC1155 `balanceOf`. Multi-value reads explicitly
use Multicall3 with `allowFailure: false`; failures surface to the caller.
Enumeration is paginated through contract views, never through event logs.

```ts
// plan.order is directly accepted by the client.
const hash = await client.depositWithPermitAndPlaceOrder(
  depositAmount, plan.order, { deadline },
);
await client.publicClient.waitForTransactionReceipt({ hash });
```

`signPermit` signs the collateral's EIP-2612 Permit with version `1` (Solady),
Book as spender and the token's current nonce. The combined method submits one
Book `multicall([depositWithPermit, placeOrder])`, preserving the user as
`msg.sender`. Returned hashes mean submission, not successful inclusion; await
the receipt before updating confirmed balances. Supply enough free/deposited
cash for the full quantity at the order limit **plus fees**, not merely the
expected execution cost. Unfilled IOC collateral is refunded internally.

Other write methods are `placeOrder`, `deposit`, `withdraw`, `cancelOrder`,
`cancelOrders`, `split`, `merge`, `resolve`, `redeem`, `faucet`, `vaultDeposit`
and `vaultWithdraw`. A vault deposit requires collateral allowance to the vault;
a plain Book deposit requires collateral allowance to the Book. Use
`approveCollateral(client.addresses.vault!, assets)` (or the Book address) and
wait for its receipt before depositing. Vault withdrawals
use asset amounts, not share quantities, and are constrained by vault free cash.
Faucet tokens have no real monetary value.

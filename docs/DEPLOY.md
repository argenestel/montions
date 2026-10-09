# Montions deployment and demo operations

Montions' price markets use MOCK/DEMO constant-product pools and pool TWAPs. These oracles are manipulable, especially at low liquidity: a pool move in the last seconds of an idle window can influence the TWAP. Deep seeded reserves and a longer window mitigate this risk; they do not eliminate it. Do not treat the demo oracle or tokenized NVDA price as production-grade or manipulation-resistant.

## Local Anvil

From the repository root, install the bots' dependencies (pnpm uses the lockfile), then run the complete local smoke test:

```sh
pnpm --dir bots install
./scripts/e2e-local.sh
```

The script selects a free localhost port, starts Anvil with chain ID 31337, uses Anvil's unlocked accounts (queried via `eth_accounts`), deploys contracts, seeds maker cash, exercises both bots, then performs a buy/resolve/redeem flow. It reads no private keys and does not connect to an external RPC.

One-command local stack (anvil + deploy + maker seed + canonical ladder + vault quotes + price bot):

```sh
pnpm --dir bots install
ANVIL_PORT=8547 UI_COPY=1 ./scripts/dev-up.sh
ANVIL_PORT=8547 ./scripts/dev-check.sh   # exactly N planned series, no duplicates, >= 20 quoted
./scripts/dev-down.sh
```

`dev-up.sh` uses Anvil unlocked accounts (never prints keys). Prefer a **free** `ANVIL_PORT` when running in parallel with other agents; do not collide with 8545/8547 if those are already taken. Set `UI_COPY=0` to skip copying the manifest into `app/public`.

For manual deployment and seeding, start Anvil in another terminal and use its RPC URL:

```sh
anvil --host 127.0.0.1 --port 8545 --chain-id 31337 --code-size-limit 30000
```

In a second terminal, set the local RPC and choose the standard first Anvil account key without echoing it or putting it in a file:

```sh
export RPC_URL=http://127.0.0.1:8545
export DEPLOYMENT="$PWD/deployments/31337.json"
read -rsp 'Anvil deployer private key: ' DEPLOYER_PRIVATE_KEY; echo
export DEPLOYER_PRIVATE_KEY
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" --broadcast --slow --disable-code-size-limit
forge script script/Seed.s.sol:Seed --rpc-url "$RPC_URL" --broadcast --slow --disable-code-size-limit
# Canonical UTC ladder (idempotent). Seed.s.sol only deposits maker cash / optional SEED_VAULT=1.
export BOT_PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY"
pnpm --dir bots exec tsx src/seed-ladder.ts
unset DEPLOYER_PRIVATE_KEY BOT_PRIVATE_KEY
```

The deploy script seeds MON at approximately $1.00 and NVDA at approximately $180 using deep reserves. It writes `deployments/31337.json`. The local Anvil command raises the contract-size cap for the current Book artifact; check the target Monad network's deployed-code limits before testnet deployment. The vault is optional and omitted by default. Set `DEPLOY_VAULT=1` only after the `MakerVault.sol:MakerVault` artifact is available; the manifest includes `contracts.vault` only when deployment succeeds.

The rolling ladder is **canonical and UTC-aligned** so creation is idempotent: 15m on `:00/:15/:30/:45`; 1h on the hour; 4h at 00/04/08/12/16/20 UTC; 1d at 00:00 UTC; 3d every third Unix-epoch day at 00:00 UTC; 7d on Fridays 08:00 UTC. Each bucket keeps the next two upcoming expiries that satisfy `MIN_DURATION` (120s). Strikes are `{0.8,0.9,0.95,1.0,1.05,1.1,1.2,1.35,1.5}` times a reference price rounded to 2 significant digits, then snapped to 3 significant digits. Overlapping bucket timestamps collapse to one series. `pnpm --dir bots exec tsx src/seed-ladder.ts` creates missing series via `Book.multicall` in chunks of 20 and skips any id that already has `seriesInfo` status ≠ None.

## Monad testnet (chain ID 10143)

Use the Monad testnet RPC and an account funded with testnet MON for gas. **Never put a private key in a command-line argument, `.env` file, or log.** Either load it into a Foundry keystore (`cast wallet import montions-deployer`) and let Foundry prompt for the password, or read it silently into the environment:

```sh
export RPC_URL=https://testnet-rpc.monad.xyz
export DEPLOYMENT="$PWD/deployments/10143.json"

# Option A: Foundry keystore; provide the matching public address for contract ownership.
export DEPLOYER_ADDRESS=0xYourDeployerAddress
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" --chain-id 10143 \
  --account montions-deployer --sender "$DEPLOYER_ADDRESS" --broadcast --slow --disable-code-size-limit
forge script script/Seed.s.sol:Seed --rpc-url "$RPC_URL" --chain-id 10143 \
  --account montions-deployer --sender "$DEPLOYER_ADDRESS" --broadcast --slow --disable-code-size-limit
# After Seed, create the canonical ladder with an unlocked/keystore signer (never echo the key):
# BOT_ADDRESS="$DEPLOYER_ADDRESS" pnpm --dir bots exec tsx src/seed-ladder.ts

# Option B: environment key (do not echo it or save it to disk).
# read -rsp 'Deployer private key: ' DEPLOYER_PRIVATE_KEY; echo
# export DEPLOYER_PRIVATE_KEY
# forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" --chain-id 10143 --broadcast --slow --disable-code-size-limit
# forge script script/Seed.s.sol:Seed --rpc-url "$RPC_URL" --chain-id 10143 --broadcast --slow --disable-code-size-limit
# BOT_PRIVATE_KEY="$DEPLOYER_PRIVATE_KEY" pnpm --dir bots exec tsx src/seed-ladder.ts
# unset DEPLOYER_PRIVATE_KEY BOT_PRIVATE_KEY
```

`DEPLOYER_ADDRESS` is the account that owns the demo contracts and funds the seed market maker. The scripts write `deployments/10143.json`; verify the chain ID, contract addresses, and asset entries before publishing it. To include the optional vault, set `DEPLOY_VAULT=1` for Deploy when its artifact is present, then run Seed, then `seed-ladder.ts`. `SEED_VAULT=1` on Seed deposits into the vault and refreshes every open series (heavy; prefer the keeper).

### Verification pointers

The deployment manifest is the source of the deployed addresses and constructor inputs. Verify the contracts with the Monad testnet explorer's contract verification UI / supported Sourcify workflow. Solidity is 0.8.28 with Cancun EVM settings and optimizer enabled (200 runs). Constructor arguments are:

- `TestUSDC(owner)`; `MockERC20(name, symbol, 18, owner)` for tMON / tNVDA.
- `SpotPool(baseToken, tUSDC, owner)`; `OracleHub(owner)`.
- `TwapThresholdResolver(oracleHub, owner)`; `TimelockOpResolver(owner)`.
- `MontionsBook(tUSDC, owner)`; `Quoter(book, twapResolver)`.
- Optional `MakerVault(book, quoter, owner)`.

Check the explorer and deployment manifest after deployment; no external verification service is called by these scripts.

## Bots

Install dependencies with pnpm. Bots read `DEPLOYMENT` (default `deployments/31337.json`) and use `RPC_URL` when set, otherwise the manifest RPC. Write operations require `BOT_PRIVATE_KEY`, or `BOT_ADDRESS` for an account unlocked by the RPC node (or run in `--dry-run` mode). Keep keys in the environment or a Foundry keystore; **never print, log, or pass private keys on the command line**.

```sh
pnpm --dir bots install
export DEPLOYMENT="$PWD/deployments/31337.json"
export RPC_URL=http://127.0.0.1:8545
read -rsp 'Bot private key: ' BOT_PRIVATE_KEY; echo
export BOT_PRIVATE_KEY
# Alternatively, use BOT_ADDRESS only with a trusted local RPC that unlocks that account.

# DEMO price walks swap both pools; default interval is 4 seconds.
pnpm --dir bots exec tsx src/price-bot.ts
pnpm --dir bots exec tsx src/price-bot.ts --once
pnpm --dir bots exec tsx src/price-bot.ts --dry-run --once

# Canonical ladder (shared planner with the keeper). Chunks of 20 via Book.multicall.
pnpm --dir bots exec tsx src/seed-ladder.ts
pnpm --dir bots exec tsx src/seed-ladder.ts --dry-run

# Checkpoints each asset (pool mode), maintains the rolling ladder, settles/resolves
# expired series, and refreshes the closest-to-the-money vault series.
pnpm --dir bots exec tsx src/keeper.ts
pnpm --dir bots exec tsx src/keeper.ts --once
pnpm --dir bots exec tsx src/keeper.ts --dry-run --once

unset BOT_PRIVATE_KEY
```

Set `PRICE_BOT_INTERVAL_MS` (default 4000), `PRICE_VOL` (default annualized 0.55), and `PRICE_SWAP_BPS` (default 3 bps of the input-side reserve; capped at 100 bps) to tune the clearly labelled DEMO price bot. For controlled local-only tests, `PRICE_BOT_BIAS=up|down` forces swap direction; normal operation defaults to the mean-reverting random walk.

Keeper flags (structured one-line `component=keeper ...` logs; exit 0 on success, 1 on failure; at most one in-flight signer tx):

| Env / flag | Default | Meaning |
|---|---|---|
| `KEEPER_MODE` | `pool` | `pool` = OracleHub.checkpoint + Book.resolve. `pyth` = Hermes update + `PythSettlementResolver.settle` then `Book.resolve`. |
| `KEEPER_CREATE` | `1` | Create missing canonical series. `0` skips creation. |
| `KEEPER_REFRESH_LIMIT` | `40` | Max vault `refresh` calls per tick, closest to the money first (`\|fairTick-50\|` from `Quoter.snapshots`). `0` skips. |
| `KEEPER_INTERVAL_MS` | `15000` | Loop delay (no tight retry loop). |
| `--once` | | Single tick, then exit. |
| `--dry-run` | | Log intended writes; no transactions. |
| `HERMES_URL` | `https://hermes.pyth.network` | Pyth Hermes REST (`/v2/updates/price/{unixTime}?ids[]={feedId}&encoding=hex&parsed=true`). |
| `PYTH_ADDRESS` | Monad Pyth core | Used for `getUpdateFee` when the manifest has no `contracts.pyth`. |
| `PYTH_FEED_<SYMBOL>` | table in `bots/src/pyth.ts` | Override a Pyth price-feed id. |

`KEEPER_MODE=pyth` needs `contracts.pythSettlementResolver` (and ideally `pythOracle`) in the deployment manifest. Settlement looks up `settlements(assetId, expiry)` / `isSettled` (field names live in `PYTH_SETTLEMENT_FIELDS` in `bots/src/pyth.ts`). On `PriceFeedNotFoundWithinRange` the keeper retries publish times `expiry .. expiry+300` with exponential backoff and a hard cap; it never issues a second signer transaction until the previous receipt is in. Hermes HTTP is not exercised in offline tests — wire it against mainnet/Hermes before production.

The price bot signer needs tUSDC and tMON/tNVDA to swap. Deploy mints a demo buffer to the account named by `BOT_PRIVATE_KEY` or `BOT_ADDRESS` when supplied during deployment; the mock tokens also expose public faucets. Keep swap sizes small relative to reserves.

## Point the UI at a deployment

The Foundry script writes only under `deployments/` (the configured Foundry filesystem permission). To copy the selected manifest into the static UI, set the output path and run the helper:

```sh
DEPLOYMENT="$PWD/deployments/10143.json" \
  UI_DEPLOYMENT_OUT="$PWD/app/public/deployment.json" \
  node scripts/copy-deployment.mjs
```

For local Anvil, substitute `deployments/31337.json`. The helper creates the output directory if needed. Do not publish local private keys or point a public UI at an unreviewed local/demo manifest.

## Testnet: demo stocks and ETFs

`scripts/testnet-add-assets.sh stocks [count] [--dry]` adds demo stock/ETF assets (list in `config/stocks-demo.json`, 30 symbols) to the Monad **testnet** deployment: a mintable token and TWAP pool per symbol, hub and resolver registration (`script/AddStocks.s.sol`), then a light ladder of 10 markets per stock (`tier: "stock"`: 2 expiries × 5 strikes). Prices and volatilities are **approximate demo levels, not live quotes**: Pyth does list real equity feeds, but they are not pushed on Monad, so a real stock market would need a Hermes key and a push bot. The script refuses mainnet.

Cost on testnet (gas is billed on the gas limit, about 102 gwei): roughly 0.31 MON per stock for the pool, about 0.3 MON for its markets, and about 0.11 MON for the vault to quote them. Twelve stocks need about 9 MON. The script prints the estimate, checks the balance and resumes if rerun. Afterwards run `scripts/testnet-bots.sh start`, commit `app/public/deployment.testnet.json` and redeploy the site.

### Measured testnet gas (Monad testnet, ~102 gwei, billed on the gas limit)

| Action | Cost |
|---|---|
| Add one asset (token + pool + registration) and its 10 markets | ~0.62 MON |
| `MakerVault.refresh` (cancel + up to 6 orders + onchain fair value) | ~0.62 MON per market |
| Price-sync step (mint + approve first time, then one swap) | ~0.01–0.03 MON |
| `Book.resolve` of an expired market | ~0.1 MON (the keeper now skips markets with no collateral) |

Vault refreshes dominate. For testnet liquidity, prefer a few refreshed near-the-money markets, or plain maker orders from a wallet, over refreshing every market.

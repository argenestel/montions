# Mainnet runbook (Monad, chain 143)

> **Status: NOT launched.** Everything here has been rehearsed on a *local fork* of mainnet only. No transaction has been sent to a live chain.
> Read `docs/LAUNCH_CHECKLIST.md` first: a professional audit, legal review and a testnet soak are still open gates.

## Verified facts (read-only `eth_call`, 2026-10-07 — re-verify before launch)
| Item | Value |
|---|---|
| Chain | Monad mainnet, id **143**, RPCs `rpc.monad.xyz` (25 rps), `rpc1/2/3.monad.xyz`, `rpc-mainnet.monadinfra.com` |
| USDC (Circle) | `0x754704Bc059F8C67012fEd69BC8A327a5aafb603` — 6 decimals, FiatToken v2 (EIP-2612 permit), upgradeable proxy, **has `isBlacklisted`: Circle can freeze an address, including the Book** |
| Pyth core | `0x2880aB155794e7179c9eE2e38200202908C17B43` — upgradable proxy; implementation has `parsePriceFeedUpdatesUnique`; `getValidTimePeriod()` = 60 |
| Feeds | MON/USD `0x3149…6cd1`, BTC/USD `0xe62d…5b43`, ETH/USD `0xff61…0ace` — all exist and are live |
| Multicall3 | `0xcA11bde05977b3631167028862bE2a173976CA11` (predeployed) |
| Contract size | Monad allows 128 KB; the Book is ~29 KB (above Ethereum's 24 KB limit — this protocol does not deploy on chains with the 24 KB limit) |

## Findings from the mainnet-fork rehearsal (`scripts/fork-rehearsal.sh`)
1. **Hermes needs an API key.** Pyth's Core upgrade (completed 2026-08-26) made Hermes require `Authorization: Bearer <key>`; the public endpoint returns 401. Settlement keepers need `HERMES_API_KEY` (free trial, then paid). Settlement stays **permissionless** — anyone with a key can settle — and if nobody does, markets **void 50/50** after 2 days (verified on the fork).
2. **Pyth feed freshness.** Pushed feeds refresh every ~30–70 s on Monad (BTC/ETH ≈ 65 s). The oracle `maxAge` is therefore **180 s** (not 60) to avoid false "unhealthy". It only affects quoting/display; settlement uses fresh signed data.
3. **Always broadcast with `--slow`.** Without it forge fires all transactions at once and they can queue out of order (observed on a fork). All deploy/handover commands below use `--slow`.
4. **`cast call` multi-value returns** print only the first value in cast 1.5; tooling decodes raw data (see `scripts/verify-deployment.sh`).
5. Verified on the fork with **real USDC and the real Pyth contract**: guard refuses without the acknowledgement; deploys paused; caps finite; oracle healthy for MON/BTC/ETH; two-step ownership handover; old owner locked out; deposit → match → void → 50/50 redeem → withdraw; Book USDC balance == tracked collateral at every checkpoint.
6. **NOT yet verified:** live Pyth settlement end to end (needs a Hermes key). Run `HERMES_API_KEY=… REQUIRE_PYTH=1 scripts/fork-rehearsal.sh` — it must print `FORK REHEARSAL PASSED` before any launch.

## Steps (dry-run each first: omit `--broadcast`)
```bash
export RPC=https://rpc.monad.xyz
export OWNER_SAFE=0x<safe-multisig>                       # final owner (>= 2-of-3)
export COLLATERAL_CAP_USDC=5000 SERIES_POOL_CAP_USDC=250   # start tiny; raise in stages
export CONFIRM_MAINNET=I_UNDERSTAND_THIS_IS_UNAUDITED_AND_USES_REAL_FUNDS
# 1. deploy (Book is deployed PAUSED). Use a Foundry keystore, never a key on the command line:
forge script script/DeployProd.s.sol:DeployProd --rpc-url $RPC --account <keystore> --sender <addr> --broadcast --slow --verify
CHAIN_ID=143 RPCS=https://rpc1.monad.xyz,https://rpc2.monad.xyz node scripts/finish-manifest.mjs     # writes deployments/143.json
# 2. verify against the live chain (must pass, Book must be paused)
scripts/verify-deployment.sh deployments/143.json --expect-paused
# 3. Safe executes requestOwnershipHandover() on Book, PythOracle, PythResolver, TimelockResolver, Quoter (and Vault)
# 4. complete the handover from the deployer
CONTRACTS=<book>,<oracle>,<resolver>,<timelock>,<quoter> NEW_OWNER=$OWNER_SAFE forge script script/HandoverOwnership.s.sol --rpc-url $RPC --account <keystore> --broadcast --slow
# 5. Safe: setPaused(false) only after verify passes with --expect-paused AND the owner is the Safe
scripts/verify-deployment.sh deployments/143.json --expect-unpaused
# 6. seed the series ladder and run the settlement keeper (KEEPER_MODE=pyth, HERMES_API_KEY set)
```

## What the owner can and cannot do
Can: allow resolvers for NEW series, set fee (<= 1%), pause NEW risk, set caps, sweep stray native currency.
Cannot: move user funds, change an outcome, block cancel/merge/resolve/redeem/withdraw.
Residual trust: Pyth (publishers + its upgrade key), Circle (USDC freeze/upgrade), the Safe signers.

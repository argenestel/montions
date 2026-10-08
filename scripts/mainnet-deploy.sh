#!/usr/bin/env bash
# MONAD MAINNET deployment (real money gas). Deploys the Pyth-priced stack with EVERY enabled asset from config/pyth-feeds.json.
# The Book is deployed PAUSED with finite caps; this script never unpauses. Ownership stays with the deployer key until you hand it over.
# Prereqs: fund the mainnet deployer (printed below) with MON for gas; export the acknowledgement; run scripts/fork-rehearsal.sh first.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
RPC="${RPC_URL:-https://rpc.monad.xyz}"; KS="${KEYSTORE:-$ROOT/.dev/keystore/montions-mainnet}"; PASS="${PASSFILE:-$ROOT/.dev/mainnet.pass}"
[ -f "$KS" ] && [ -f "$PASS" ] || { echo "missing mainnet keystore/password (.dev/keystore/montions-mainnet, .dev/mainnet.pass)"; exit 1; }
ADDR="$(cast wallet address --keystore "$KS" --password-file "$PASS")"
[ "$(cast chain-id --rpc-url "$RPC")" = "143" ] || { echo "RPC is not Monad mainnet (143)"; exit 1; }
[ "${CONFIRM_MAINNET:-}" = "I_UNDERSTAND_THIS_IS_UNAUDITED_AND_USES_REAL_FUNDS" ] || { echo "Set CONFIRM_MAINNET=I_UNDERSTAND_THIS_IS_UNAUDITED_AND_USES_REAL_FUNDS to proceed."; exit 3; }
BAL="$(cast balance "$ADDR" --rpc-url "$RPC" --ether | awk '{print $1}')"; NEED="${MIN_MON:-60}"
echo "mainnet deployer $ADDR  balance $BAL MON  (needs >= $NEED MON for ~34 assets; gas is charged on the gas limit)"
python3 -c "import sys; sys.exit(0 if float('$BAL') >= float('$NEED') else 1)" || { echo "Not enough MON. Fund: $ADDR"; exit 2; }
python3 scripts/feeds.py >/dev/null || true     # refresh + re-verify the live feed catalogue just before deploying
echo "enabled feeds: $(jq '[.feeds[]|select(.enabled)]|length' config/pyth-feeds.json)"
export OWNER_SAFE="${OWNER_SAFE:-$ADDR}"        # no Safe yet: deployer remains owner. Hand over later with script/HandoverOwnership.s.sol
export COLLATERAL_CAP_USDC="${COLLATERAL_CAP_USDC:-5000}" SERIES_POOL_CAP_USDC="${SERIES_POOL_CAP_USDC:-250}" DEPLOY_VAULT="${DEPLOY_VAULT:-0}" VAULT_CAP_USDC="${VAULT_CAP_USDC:-2000}"
echo "caps: total ${COLLATERAL_CAP_USDC} USDC, per-series ${SERIES_POOL_CAP_USDC} USDC, vault=${DEPLOY_VAULT}"
SIGN=(--keystore "$KS" --password-file "$PASS")
forge script script/DeployProd.s.sol:DeployProd --rpc-url "$RPC" "${SIGN[@]}" --sender "$ADDR" --broadcast --slow --disable-code-size-limit --verify --verifier sourcify --verifier-url "${SOURCIFY_URL:-https://sourcify-api-monad.blockscout.com/}" 2>&1 | tee .dev/mainnet-deploy.log | tail -25 || true
CHAIN_ID=143 RPCS="https://rpc1.monad.xyz,https://rpc2.monad.xyz,https://rpc-mainnet.monadinfra.com" node scripts/finish-manifest.mjs
scripts/verify-deployment.sh deployments/143.json --expect-paused
echo; echo "✔ deployed PAUSED. Next: (1) scripts/mainnet-seed.sh  (2) review, then the OWNER unpauses deliberately: cast send <book> 'setPaused(bool)' false"

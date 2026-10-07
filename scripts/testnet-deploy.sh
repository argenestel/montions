#!/usr/bin/env bash
# One-command Monad TESTNET deployment (demo pool oracle + test USDC; clearly labelled MOCK in the UI).
# Needs only a funded throwaway deployer keystore (created by: cast wallet new .dev/keystore montions-testnet --unsafe-password "$(cat .dev/testnet.pass)").
# Fund the printed address at https://faucet.monad.xyz, then run:   scripts/testnet-deploy.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
RPC="${RPC_URL:-https://testnet-rpc.monad.xyz}"; KS="${KEYSTORE:-$ROOT/.dev/keystore/montions-testnet}"; PASS="${PASSFILE:-$ROOT/.dev/testnet.pass}"
[ -f "$KS" ] && [ -f "$PASS" ] || { echo "missing keystore/password file (see header of this script)"; exit 1; }
ADDR="$(cast wallet address --keystore "$KS" --password-file "$PASS")"
[ "$(cast chain-id --rpc-url "$RPC")" = "10143" ] || { echo "RPC is not Monad testnet (10143)"; exit 1; }
BAL="$(cast balance "$ADDR" --rpc-url "$RPC" --ether | awk '{print $1}')"
echo "deployer $ADDR  balance ${BAL} MON"
python3 -c "import sys; sys.exit(0 if float('$BAL') >= 1.0 else 1)" || { echo; echo "Not enough MON. Fund this address with >= 1 testnet MON:"; echo "  $ADDR"; echo "  faucet: https://faucet.monad.xyz"; exit 2; }
SIGN=(--keystore "$KS" --password-file "$PASS")
send() { cast send "$@" "${SIGN[@]}" --rpc-url "$RPC" >/dev/null; }
export DEPLOY_VAULT=1 DEPLOYER_ADDRESS="$ADDR" BOT_ADDRESS="$ADDR" RPC_URL="$RPC"

echo "▶ deploy (contracts + seeded demo pools + vault)"
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC" "${SIGN[@]}" --sender "$ADDR" --broadcast --slow --disable-code-size-limit > .dev/testnet-deploy.log 2>&1 || { tail -25 .dev/testnet-deploy.log; exit 1; }
M=deployments/10143.json; J() { jq -r ".contracts.$1" "$M"; }
BOOK=$(J book); VAULT=$(J vault); USDC=$(J collateral)

echo "▶ configure: vault trusts the TWAP resolver; launch caps (generous but finite on testnet)"
send "$VAULT" "setTrustedResolver(address)" "$(J twapResolver)"; send "$VAULT" "setKeeper(address)" "$ADDR"; send "$VAULT" "setCaps(uint16,uint16,uint16)" 80 3000 2000
send "$BOOK" "setCollateralCap(uint256)" 5000000000000; send "$BOOK" "setSeriesPoolCap(uint256)" 200000000000; send "$VAULT" "setMaxTotalAssets(uint256)" 2000000000000

echo "▶ seed maker markets, then the canonical series ladder"
forge script script/Seed.s.sol:Seed --rpc-url "$RPC" "${SIGN[@]}" --sender "$ADDR" --broadcast --slow --disable-code-size-limit >> .dev/testnet-deploy.log 2>&1
( cd bots && [ -d node_modules ] || pnpm install >/dev/null; cd ../sdk && [ -d node_modules ] || pnpm install >/dev/null )
KEY="$(cast wallet private-key --keystore "$KS" --password-file "$PASS")"
( cd bots && DEPLOYMENT="$ROOT/$M" BOT_PRIVATE_KEY="$KEY" pnpm exec tsx src/seed-ladder.ts )

echo "▶ fund the maker vault with 200k test USDC"
send "$USDC" "mint(address,uint256)" "$ADDR" 250000000000; send "$USDC" "approve(address,uint256)" "$VAULT" 200000000000; send "$VAULT" "deposit(uint256,address)" 200000000000 "$ADDR"

echo "▶ manifest for the app"
jq '.network="testnet" | .explorer="https://testnet.monadvision.com" | .rpcs=["https://rpc-testnet.monadinfra.com","https://rpc.ankr.com/monad_testnet"] | .assets |= map(.mock=true)' "$M" > .dev/m.tmp && mv .dev/m.tmp "$M"
[ "${UI_COPY:-1}" = "1" ] && { mkdir -p app/public && cp "$M" app/public/deployment.json; }
echo; echo "✔ deployed to Monad testnet"
echo "  Book      https://testnet.monadvision.com/address/$BOOK"
echo "  manifest  $M  (copied to app/public/deployment.json; commit it for hosting)"
echo "  next: scripts/testnet-bots.sh start   # keeps prices moving, refreshes vault quotes, resolves markets"

#!/usr/bin/env bash
# CLICKABLE MAINNET-FORK DEMO: a persistent local fork of Monad mainnet with the full Pyth-priced deployment, every enabled asset,
# seeded markets and a funded maker vault. Prices are REAL (live Pyth feeds); money is FAKE (local fork; USDC balances are set in fork storage).
# Usage: scripts/fork-demo.sh up | down | status       then:  cd app && pnpm dev   (http://127.0.0.1:5175, dev wallet auto-connects)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"; S=.dev/fork-demo; mkdir -p "$S"
PORT="${FORK_PORT:-8552}"; RPC="http://127.0.0.1:$PORT"; SRC="${MAINNET_RPC:-https://rpc.monad.xyz}"
USDC=0x754704Bc059F8C67012fEd69BC8A327a5aafb603
stop() { for f in anvil keeper; do { [ -f "$S/$f.pid" ] && kill "$(cat "$S/$f.pid")" 2>/dev/null || true; }; rm -f "$S/$f.pid"; done; }
case "${1:-status}" in
down) stop; echo "fork demo stopped"; exit 0;;
status) for f in anvil keeper; do [ -f "$S/$f.pid" ] && kill -0 "$(cat "$S/$f.pid")" 2>/dev/null && echo "$f running" || echo "$f stopped"; done; exit 0;;
up) ;;
*) echo "usage: $0 up|down|status"; exit 1;;
esac
stop
echo "▶ forking Monad mainnet on :$PORT"
nohup anvil --fork-url "$SRC" --chain-id 143 --host 127.0.0.1 --port "$PORT" --code-size-limit 60000 --block-base-fee-per-gas 0 --silent > "$S/anvil.log" 2>&1 & echo $! > "$S/anvil.pid"
for _ in $(seq 1 100); do cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.3; done
ACC=($(cast rpc eth_accounts --rpc-url "$RPC" | jq -r '.[]')); DEP=${ACC[0]}; USER=${ACC[5]}
send() { cast send "$@" --unlocked --rpc-url "$RPC" >/dev/null; }
setusdc() { cast rpc anvil_setStorageAt "$USDC" "$(cast index address "$1" 9)" "$(cast to-uint256 "$2")" --rpc-url "$RPC" >/dev/null; }

echo "▶ deploy the production stack (all enabled assets, with vault)"
export OWNER_SAFE="$DEP" COLLATERAL_CAP_USDC=50000000 SERIES_POOL_CAP_USDC=2000000 DEPLOY_VAULT=1 VAULT_CAP_USDC=5000000 CONFIRM_MAINNET=I_UNDERSTAND_THIS_IS_UNAUDITED_AND_USES_REAL_FUNDS
timeout 1800 forge script script/DeployProd.s.sol:DeployProd --rpc-url "$RPC" --broadcast --slow --unlocked --sender "$DEP" --disable-code-size-limit > "$S/deploy.log" 2>&1 || { tail -25 "$S/deploy.log"; exit 1; }
CHAIN_ID=143 PRIMARY_RPC="$RPC" node scripts/finish-manifest.mjs "$S/manifest.json" >/dev/null
jq --arg r "$RPC" '.rpc=$r | .network="local" | .rpcs=[] | .explorer=""' "$S/manifest.json" > "$S/m.tmp" && mv "$S/m.tmp" "$S/manifest.json"
J() { jq -r ".contracts.$1" "$S/manifest.json"; }; BOOK=$(J book); VAULT=$(J vault); RES=$(J pythResolver)

echo "▶ open for business (deployer unpauses; caps are demo-sized; vault deposits on)"
send "$BOOK" "setPaused(bool)" false --from "$DEP"
send "$VAULT" "setDepositsPaused(bool)" false --from "$DEP"; send "$VAULT" "setKeeper(address)" "$DEP" --from "$DEP"; send "$VAULT" "setCaps(uint16,uint16,uint16)" 60 3000 2000 --from "$DEP"
echo "▶ fund: dev wallet 1,000,000 USDC; vault 2,000,000 USDC (fake, fork storage only)"
setusdc "$USER" 1000000000000; setusdc "$DEP" 2000000000000
send "$USDC" "approve(address,uint256)" "$VAULT" 2000000000000 --from "$DEP"; send "$VAULT" "deposit(uint256,address)" 2000000000000 "$DEP" --from "$DEP"

echo "▶ seed tiered market ladder across every asset"
export DEPLOYMENT="$ROOT/$S/manifest.json" RPC_URL="$RPC" BOT_ADDRESS="$DEP" KEEPER_MODE=pyth
( cd bots && [ -d node_modules ] || pnpm install >/dev/null; cd ../sdk && [ -d node_modules ] || pnpm install >/dev/null )
( cd bots && pnpm exec tsx src/seed-ladder.ts 2>&1 | tail -3 )
mkdir -p app/public && cp "$S/manifest.json" app/public/deployment.json

echo "▶ keeper: refresh vault quotes on every market (900 per tick) (settlement needs a Hermes key; not required for trading)"
( cd bots && KEEPER_MODE=pyth KEEPER_CREATE=0 KEEPER_REFRESH_LIMIT=900 KEEPER_INTERVAL_MS=30000 nohup pnpm exec tsx src/keeper.ts > "$ROOT/$S/keeper.log" 2>&1 & echo $! > "$ROOT/$S/keeper.pid" )
echo; echo "✔ fork demo is up on $RPC — $(jq '.assets|length' "$S/manifest.json") assets. UI: cd app && pnpm dev  → http://127.0.0.1:5175"
echo "  logs: $S/   stop: scripts/fork-demo.sh down"

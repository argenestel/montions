#!/usr/bin/env bash
# One-command LOCAL dev environment: anvil + Multicall3 + contracts + maker seed + canonical ladder + vault quotes + price bot.
# Safe to re-run: it restarts only the anvil it started (pid in .dev/anvil.pid). Uses anvil's unlocked accounts; no private keys.
# Usage: scripts/dev-up.sh            # then open the UI (cd app && pnpm dev) -> http://127.0.0.1:5175
#        ANVIL_PORT=<free> UI_COPY=0 scripts/dev-up.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
PORT="${ANVIL_PORT:-8547}"; RPC="http://127.0.0.1:${PORT}"; STATE="$ROOT/.dev"; mkdir -p "$STATE" deployments
export RPC_URL="$RPC" DEPLOY_VAULT=1 DEPLOYMENT="$ROOT/deployments/31337.json"

stop_pid() { [ -f "$1" ] && kill "$(cat "$1")" 2>/dev/null || true; rm -f "$1"; }
stop_pid "$STATE/anvil.pid"; stop_pid "$STATE/refresh.pid"; stop_pid "$STATE/keeper.pid"; stop_pid "$STATE/pricebot.pid"; sleep 1

echo "▶ anvil on :$PORT (chain 31337, 1s blocks, 30KB code limit)"
nohup anvil --host 127.0.0.1 --port "$PORT" --chain-id 31337 --block-time 1 --code-size-limit 30000 --silent > "$STATE/anvil.log" 2>&1 & echo $! > "$STATE/anvil.pid"
for _ in $(seq 1 60); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.2; done

echo "▶ Multicall3 (canonical code, as predeployed on Monad)"
MC=0xcA11bde05977b3631167028862bE2a173976CA11
MC_CODE="$(timeout 8 cast code "$MC" --rpc-url "${MONAD_RPC:-https://testnet-rpc.monad.xyz}" 2>/dev/null || true)"
if [[ -n "${MC_CODE:-}" && "$MC_CODE" != "0x" ]]; then
  cast rpc anvil_setCode "$MC" "$MC_CODE" --rpc-url "$RPC" >/dev/null
else
  echo "▶ Multicall3 skipped (offline / unreachable Monad RPC)"
fi

ACCTS="$(cast rpc eth_accounts --rpc-url "$RPC")"
export DEPLOYER_ADDRESS="$(echo "$ACCTS" | jq -r '.[0]')" BOT_ADDRESS="$(echo "$ACCTS" | jq -r '.[1]')"

echo "▶ install bot deps if needed"
( cd "$ROOT/bots" && [ -d node_modules ] || pnpm install >/dev/null )
( cd "$ROOT/sdk" && [ -d node_modules ] || pnpm install >/dev/null )

echo "▶ deploy"; rm -f deployments/31337.json
forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC" --broadcast --slow --unlocked --sender "$DEPLOYER_ADDRESS" --disable-code-size-limit >/dev/null
J() { jq -r ".contracts.$1" deployments/31337.json; }
BOOK="$(J book)"; VAULT="$(J vault)"; USDC="$(J collateral)"
send() { cast send "$@" --from "$DEPLOYER_ADDRESS" --unlocked --rpc-url "$RPC" >/dev/null; }
send "$VAULT" "setTrustedResolver(address)" "$(J twapResolver)"
send "$VAULT" "setKeeper(address)" "$DEPLOYER_ADDRESS"
send "$VAULT" "setCaps(uint16,uint16,uint16)" 80 3000 2000     # 0.8% per series so liquidity spreads across ~32 markets

echo "▶ seed maker cash (ladder is created next, not in forge Seed)"
forge script script/Seed.s.sol:Seed --rpc-url "$RPC" --broadcast --slow --unlocked --sender "$DEPLOYER_ADDRESS" --disable-code-size-limit >/dev/null

echo "▶ canonical UTC ladder (idempotent seed-ladder.ts)"
BOT_ADDRESS="$DEPLOYER_ADDRESS" pnpm --dir bots exec tsx src/seed-ladder.ts

echo "▶ fund maker vault with 500k test USDC"
send "$USDC" "mint(address,uint256)" "$DEPLOYER_ADDRESS" 600000000000
send "$USDC" "approve(address,uint256)" "$VAULT" 500000000000
send "$VAULT" "deposit(uint256,address)" 500000000000 "$DEPLOYER_ADDRESS"

echo "▶ initial vault quotes (closest-to-the-money, KEEPER_REFRESH_LIMIT=${KEEPER_REFRESH_LIMIT:-40})"
BOT_ADDRESS="$DEPLOYER_ADDRESS" KEEPER_MODE=pool KEEPER_CREATE=0 KEEPER_REFRESH_LIMIT="${KEEPER_REFRESH_LIMIT:-40}" \
  pnpm --dir bots exec tsx src/keeper.ts --once

[ "${UI_COPY:-1}" = "1" ] && { mkdir -p app/public && cp deployments/31337.json app/public/deployment.json && echo "▶ UI manifest -> app/public/deployment.json"; }

echo "▶ background loops: keeper (60s) + demo price bot"
(
  cd "$ROOT"
  BOT_ADDRESS="$DEPLOYER_ADDRESS" KEEPER_MODE=pool KEEPER_CREATE=1 KEEPER_REFRESH_LIMIT="${KEEPER_REFRESH_LIMIT:-40}" KEEPER_INTERVAL_MS=60000 \
    nohup pnpm --dir bots exec tsx src/keeper.ts > "$STATE/keeper.log" 2>&1 & echo $! > "$STATE/keeper.pid"
)
(
  cd "$ROOT/bots"
  PRICE_BOT_INTERVAL_MS=2500 PRICE_VOL=1.1 PRICE_SWAP_BPS=22 BOT_ADDRESS="$BOT_ADDRESS" \
    nohup pnpm exec tsx src/price-bot.ts > "$STATE/pricebot.log" 2>&1 & echo $! > "$STATE/pricebot.pid"
)
echo "✔ ready. RPC $RPC · book $BOOK · logs in .dev/ · stop with scripts/dev-down.sh"

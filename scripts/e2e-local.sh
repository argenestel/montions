#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
RPC_URL="http://127.0.0.1:${PORT}"
ANVIL_LOG="$(mktemp)"

# Use Anvil-managed unlocked accounts; no private key is read or printed by this script.
export RPC_URL
export DEPLOYMENT="$ROOT/deployments/31337.json"

anvil --host 127.0.0.1 --port "$PORT" --chain-id 31337 --block-time 1 --code-size-limit 30000 --silent >"$ANVIL_LOG" 2>&1 &
ANVIL_PID=$!
cleanup() {
  kill "$ANVIL_PID" 2>/dev/null || true
  wait "$ANVIL_PID" 2>/dev/null || true
  if [[ "${KEEP_ANVIL_LOG:-0}" == "1" ]]; then
    echo "Anvil log: $ANVIL_LOG"
  else
    rm -f "$ANVIL_LOG"
  fi
}
trap cleanup EXIT

ready=0
for _ in $(seq 1 60); do
  if cast chain-id --rpc-url "$RPC_URL" >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 0.2
done
if [[ "$ready" != "1" ]]; then
  echo "Anvil did not start" >&2
  cat "$ANVIL_LOG" >&2
  exit 1
fi

forge build
ANVIL_ACCOUNTS="$(cast rpc eth_accounts --rpc-url "$RPC_URL")"
DEPLOYER_ADDRESS="$(node -e 'process.stdout.write(JSON.parse(process.argv[1])[0])' "$ANVIL_ACCOUNTS")"
BOT_ADDRESS="$(node -e 'process.stdout.write(JSON.parse(process.argv[1])[1])' "$ANVIL_ACCOUNTS")"
export DEPLOYER_ADDRESS BOT_ADDRESS

forge script script/Deploy.s.sol:Deploy --rpc-url "$RPC_URL" --broadcast --slow --unlocked --sender "$DEPLOYER_ADDRESS" --disable-code-size-limit
if [[ -n "${UI_DEPLOYMENT_OUT:-}" ]]; then
  CHAIN_ID=31337 node scripts/copy-deployment.mjs
fi
forge script script/Seed.s.sol:Seed --rpc-url "$RPC_URL" --broadcast --slow --unlocked --sender "$DEPLOYER_ADDRESS" --disable-code-size-limit

for _ in 1 2 3; do
  pnpm --dir bots exec tsx src/price-bot.ts --once
done

pnpm --dir bots exec tsx ../scripts/e2e.ts

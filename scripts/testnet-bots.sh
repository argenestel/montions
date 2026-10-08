#!/usr/bin/env bash
# Start/stop the demo price bot + keeper against the Monad testnet deployment (they must keep running for markets to stay live).
# Usage: scripts/testnet-bots.sh start|stop|status|logs   (gas: ~0.014 MON per tx on testnet — price bot every 45s and a 20-market keeper refresh per minute cost roughly 1.5 MON per hour)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"; S=.dev/testnet-bots; mkdir -p "$S"
KS="${KEYSTORE:-$ROOT/.dev/keystore/montions-testnet}"; PASS="${PASSFILE:-$ROOT/.dev/testnet.pass}"
case "${1:-status}" in
  start)
    KEY="$(cast wallet private-key --keystore "$KS" --password-file "$PASS")"
    export DEPLOYMENT="$ROOT/deployments/10143.json" RPC_URL="${RPC_URL:-https://testnet-rpc.monad.xyz}" BOT_PRIVATE_KEY="$KEY"
    ( cd bots && PRICE_BOT_INTERVAL_MS=${PRICE_BOT_INTERVAL_MS:-45000} PRICE_VOL=1.1 PRICE_SWAP_BPS=22 nohup pnpm exec tsx src/price-bot.ts > "$ROOT/$S/price.log" 2>&1 & echo $! > "$ROOT/$S/price.pid" )
    ( cd bots && KEEPER_MODE=pool KEEPER_INTERVAL_MS=${KEEPER_INTERVAL_MS:-60000} KEEPER_REFRESH_LIMIT=${KEEPER_REFRESH_LIMIT:-20} nohup pnpm exec tsx src/keeper.ts > "$ROOT/$S/keeper.log" 2>&1 & echo $! > "$ROOT/$S/keeper.pid" )
    echo "started (logs: $S/)";;
  stop) for f in price keeper; do [ -f "$S/$f.pid" ] && kill "$(cat "$S/$f.pid")" 2>/dev/null; rm -f "$S/$f.pid"; done; echo stopped;;
  logs) tail -n 20 "$S"/*.log;;
  *) for f in price keeper; do [ -f "$S/$f.pid" ] && kill -0 "$(cat "$S/$f.pid")" 2>/dev/null && echo "$f running" || echo "$f stopped"; done;;
esac

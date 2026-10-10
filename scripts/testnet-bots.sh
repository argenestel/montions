#!/usr/bin/env bash
# Start/stop the price sync, keeper and maker against the Monad testnet deployment (they must keep running for markets to stay live).
# Usage: scripts/testnet-bots.sh start|stop|status|logs
# Gas (Monad bills the gas limit, ~102 gwei): price sync swaps only when a pool drifts >1% from Pyth; the keeper creates the weekly/monthly
# ladder and resolves markets with positions; the maker re-quotes up to QUOTE_BUDGET markets every 30 min (~0.05 MON per market).
# The keeper's vault refresh is OFF by default (KEEPER_REFRESH_LIMIT=0): it measured ~0.62 MON per market and at 20/min drained the wallet.
# Oracle checkpoints are written only for assets with a market expiring within KEEPER_CHECKPOINT_WINDOW_SEC (180) of now: at ~0.01 MON each,
# checkpointing 16 pools every minute cost ~10 MON/hour and drained the wallet once; the pool holds its last observation forward anyway.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"; S=.dev/testnet-bots; mkdir -p "$S"
KS="${KEYSTORE:-$ROOT/.dev/keystore/montions-testnet}"; PASS="${PASSFILE:-$ROOT/.dev/testnet.pass}"
case "${1:-status}" in
  start)
    KEY="$(cast wallet private-key --keystore "$KS" --password-file "$PASS")"
    export DEPLOYMENT="$ROOT/deployments/10143.json" RPC_URL="${RPC_URL:-https://testnet-rpc.monad.xyz}" BOT_PRIVATE_KEY="$KEY"
    # prices: keep every pool on the real Pyth price published on Monad mainnet (assets whose source is stale hold their last price)
    ( cd bots && PRICE_SYNC_INTERVAL_MS=${PRICE_SYNC_INTERVAL_MS:-300000} SYNC_BPS=${SYNC_BPS:-100} nohup pnpm exec tsx src/price-sync.ts > "$ROOT/$S/price.log" 2>&1 & echo $! > "$ROOT/$S/price.pid" )
    ( cd bots && KEEPER_MODE=pool KEEPER_INTERVAL_MS=${KEEPER_INTERVAL_MS:-60000} KEEPER_REFRESH_LIMIT=${KEEPER_REFRESH_LIMIT:-0} nohup pnpm exec tsx src/keeper.ts > "$ROOT/$S/keeper.log" 2>&1 & echo $! > "$ROOT/$S/keeper.pid" )
    # quotes: two-sided resting orders straight on the Book (see bots/src/quote.ts), stale or unquoted markets first
    ( cd bots && nohup bash -c 'while true; do QUOTE_BUDGET=${QUOTE_BUDGET:-8} pnpm exec tsx src/quote.ts; sleep ${QUOTE_INTERVAL_SEC:-1800}; done' > "$ROOT/$S/quote.log" 2>&1 & echo $! > "$ROOT/$S/quote.pid" )
    echo "started (logs: $S/)";;
  stop) for f in price keeper quote; do [ -f "$S/$f.pid" ] && kill "$(cat "$S/$f.pid")" 2>/dev/null; rm -f "$S/$f.pid"; done; echo stopped;;
  logs) tail -n 20 "$S"/*.log;;
  *) for f in price keeper quote; do [ -f "$S/$f.pid" ] && kill -0 "$(cat "$S/$f.pid")" 2>/dev/null && echo "$f running" || echo "$f stopped"; done;;
esac

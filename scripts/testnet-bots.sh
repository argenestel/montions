#!/usr/bin/env bash
# Start/stop the price sync, keeper and maker against the Monad testnet deployment (they must keep running for markets to stay live).
# Usage: scripts/testnet-bots.sh start|stop|status|logs
# Gas (Monad bills the gas limit, ~102 gwei): price sync swaps only when a pool drifts >1% from Pyth; the keeper creates the weekly/monthly
# ladder and resolves markets with positions; the maker re-quotes up to QUOTE_BUDGET markets every 30 min (~0.05 MON per market).
# The keeper's vault refresh is OFF by default (KEEPER_REFRESH_LIMIT=0): it measured ~0.62 MON per market and at 20/min drained the wallet.
# Oracle checkpoints are written only for assets with a market expiring within KEEPER_CHECKPOINT_WINDOW_SEC (180) of now: at ~0.01 MON each,
# checkpointing 16 pools every minute cost ~10 MON/hour and drained the wallet once; the pool holds its last observation forward anyway.
# Each bot runs in its own process group (setsid) and `stop` kills the group: `pnpm exec` forks the real bot as a child, so killing only
# the recorded pid used to leave orphan keepers behind (four of them once ran side by side, quadrupling the gas burn). `start` refuses to
# run while any bot process is still alive.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"; S=.dev/testnet-bots; mkdir -p "$S"
KS="${KEYSTORE:-$ROOT/.dev/keystore/montions-testnet}"; PASS="${PASSFILE:-$ROOT/.dev/testnet.pass}"
BOTS="price keeper quote"
# bracketed letters keep the pattern from matching a shell whose command line merely quotes it (including this script and its parent)
PATTERNS='tsx src/price-syn[c]\.ts|tsx src/keepe[r]\.ts|tsx src/quot[e]\.ts|while true; do QUOTE_BUDGE[T]'

alive() { pgrep -f "$PATTERNS" 2>/dev/null | grep -v -e "^$$\$" -e "^$PPID\$" || true; }
launch() { # launch <name> <command...>: own session/process group; the pid file holds the group leader (written by the leader itself,
  # because setsid may fork and then $! is the parent that already exited)
  local name=$1; shift
  ( cd bots && setsid nohup bash -c 'echo $$ > "$0"; exec "$@"' "$ROOT/$S/$name.pid" "$@" > "$ROOT/$S/$name.log" 2>&1 & )
}
case "${1:-status}" in
  start)
    if [ -n "$(alive)" ]; then echo "bots already running (pids: $(alive | tr '\n' ' ')); run '$0 stop' first" >&2; exit 1; fi
    KEY="$(cast wallet private-key --keystore "$KS" --password-file "$PASS")"
    export DEPLOYMENT="$ROOT/deployments/10143.json" RPC_URL="${RPC_URL:-https://testnet-rpc.monad.xyz}" BOT_PRIVATE_KEY="$KEY"
    # prices: keep every pool on the real Pyth price published on Monad mainnet (assets whose source is stale hold their last price)
    PRICE_SYNC_INTERVAL_MS=${PRICE_SYNC_INTERVAL_MS:-300000} SYNC_BPS=${SYNC_BPS:-100} launch price pnpm exec tsx src/price-sync.ts
    KEEPER_MODE=pool KEEPER_INTERVAL_MS=${KEEPER_INTERVAL_MS:-60000} KEEPER_REFRESH_LIMIT=${KEEPER_REFRESH_LIMIT:-0} launch keeper pnpm exec tsx src/keeper.ts
    # quotes: two-sided resting orders straight on the Book (see bots/src/quote.ts), stale or unquoted markets first
    launch quote bash -c 'while true; do QUOTE_BUDGET=${QUOTE_BUDGET:-8} pnpm exec tsx src/quote.ts; sleep ${QUOTE_INTERVAL_SEC:-1800}; done'
    echo "started (logs: $S/)";;
  stop)
    for f in $BOTS; do [ -f "$S/$f.pid" ] && kill -- -"$(cat "$S/$f.pid")" 2>/dev/null || true; rm -f "$S/$f.pid"; done
    sleep 1
    # sweep anything the pid files missed (older starts, orphaned children)
    for p in $(alive); do kill "$p" 2>/dev/null || true; done
    sleep 1
    for p in $(alive); do kill -9 "$p" 2>/dev/null || true; done
    echo stopped;;
  logs) tail -n 20 "$S"/*.log;;
  *)
    for f in $BOTS; do
      if [ -f "$S/$f.pid" ] && [ -n "$(pgrep -g "$(cat "$S/$f.pid")" 2>/dev/null)" ]; then echo "$f running"; else echo "$f stopped"; fi
    done
    extra=$(alive | wc -l); known=0
    for f in $BOTS; do [ -f "$S/$f.pid" ] && known=$((known + $(pgrep -g "$(cat "$S/$f.pid")" 2>/dev/null | wc -l))); done
    [ "$extra" -gt "$known" ] && echo "warning: $((extra - known)) bot process(es) outside the pid files; run '$0 stop' to sweep them";;
esac

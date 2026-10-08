#!/usr/bin/env bash
# Seeds the tiered series ladder (majors/alts/wrapped) on MAINNET and starts/stops the settlement keeper.
# Usage: scripts/mainnet-seed.sh seed | keeper-start | keeper-stop | keeper-status
# The keeper needs a Pyth Hermes API key in HERMES_API_KEY or .dev/hermes.key (see docs/MAINNET.md); without it markets simply void 50/50 after 2 days.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"; S=.dev/mainnet-keeper; mkdir -p "$S"
KS="${KEYSTORE:-$ROOT/.dev/keystore/montions-mainnet}"; PASS="${PASSFILE:-$ROOT/.dev/mainnet.pass}"
export DEPLOYMENT="$ROOT/deployments/143.json" RPC_URL="${RPC_URL:-https://rpc.monad.xyz}"
case "${1:-}" in
  seed)
    export BOT_PRIVATE_KEY="$(cast wallet private-key --keystore "$KS" --password-file "$PASS")" KEEPER_MODE=pyth
    ( cd bots && pnpm exec tsx src/seed-ladder.ts );;
  keeper-start)
    [ -n "${HERMES_API_KEY:-}" ] || [ -f .dev/hermes.key ] || { echo "No Hermes key: expected HERMES_API_KEY or .dev/hermes.key. Settlement would not work."; exit 2; }
    export BOT_PRIVATE_KEY="$(cast wallet private-key --keystore "$KS" --password-file "$PASS")"
    ( cd bots && KEEPER_MODE=pyth KEEPER_INTERVAL_MS=15000 nohup pnpm exec tsx src/keeper.ts > "$ROOT/$S/keeper.log" 2>&1 & echo $! > "$ROOT/$S/keeper.pid" ); echo "keeper started (log $S/keeper.log)";;
  keeper-stop) [ -f "$S/keeper.pid" ] && kill "$(cat "$S/keeper.pid")" 2>/dev/null; rm -f "$S/keeper.pid"; echo stopped;;
  *) [ -f "$S/keeper.pid" ] && kill -0 "$(cat "$S/keeper.pid")" 2>/dev/null && echo "keeper running" || echo "keeper stopped";;
esac

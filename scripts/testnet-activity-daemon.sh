#!/usr/bin/env bash
# Continuous, paced trading activity on Monad TESTNET (runs in the background).
#   scripts/testnet-activity-daemon.sh start|stop|status|logs
# Every 2-5 minutes one throwaway wallet trades against the live book (buy YES/NO, rest a limit order, or cancel one).
# Wallets are topped up with MON from the deployer keystore. When gas runs out it waits and resumes on its own after a top-up.
# Cost: ~0.067 MON per trade (660k gas at ~102 gwei; Monad bills the gas limit), so 1 MON is about 15 trades.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"; S=.dev/activity; mkdir -p "$S"
KS="${KEYSTORE:-$ROOT/.dev/keystore/montions-testnet}"; PASS="${PASSFILE:-$ROOT/.dev/testnet.pass}"
loop() {
  export FUNDER_KEY="$(cast wallet private-key --keystore "$KS" --password-file "$PASS")"
  export DEPLOYMENT="$ROOT/app/public/deployment.testnet.json" RPC_URL="${RPC_URL:-https://testnet-rpc.monad.xyz}" WALLETS_FILE="$ROOT/.dev/activity-wallets.json"
  export WALLET_COUNT="${WALLET_COUNT:-4}" MIN_MON="${MIN_MON:-0.08}" TOPUP_MON="${TOPUP_MON:-0.2}" PAUSE_MS=1000
  while true; do
    out="$(cd bots && pnpm exec tsx src/activity.ts --rounds 1 2>&1 || true)"
    echo "$out" | grep -E '"event":"(buy|rest|cancel|error|funded|needs_mon|no_funded_wallets)"' >> "$ROOT/$S/activity.log" || true
    if echo "$out" | grep -qE 'no_funded_wallets|out_of_gas|insufficient balance'; then
      echo "{\"t\":\"$(date -u +%FT%TZ)\",\"event\":\"waiting_for_mon\",\"retry_in_s\":600}" >> "$ROOT/$S/activity.log"; sleep 600
    else
      sleep $((120 + RANDOM % 180))
    fi
  done
}
case "${1:-status}" in
  start) [ -f "$S/pid" ] && kill -0 "$(cat "$S/pid")" 2>/dev/null && { echo "already running"; exit 0; }
         setsid nohup "$0" _loop > "$S/daemon.out" 2>&1 < /dev/null & echo $! > "$S/pid"; echo "started (log: $S/activity.log)";;
  _loop) loop;;
  stop)  [ -f "$S/pid" ] && { kill -- -"$(cat "$S/pid")" 2>/dev/null || kill "$(cat "$S/pid")" 2>/dev/null || true; rm -f "$S/pid"; }; echo stopped;;
  logs)  tail -n 30 "$S/activity.log";;
  *)     [ -f "$S/pid" ] && kill -0 "$(cat "$S/pid")" 2>/dev/null && echo running || echo stopped;;
esac

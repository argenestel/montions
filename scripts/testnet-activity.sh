#!/usr/bin/env bash
# Generate test activity on Monad TESTNET: a few throwaway wallets buy YES/NO, rest limit orders and cancel them against the live book.
# Usage: scripts/testnet-activity.sh [rounds]      (default 20)
# The deployer keystore tops up the wallets with MON (gas) — fund the deployer first (faucet.monad.xyz). Wallets are kept in .dev/activity-wallets.json (gitignored).
# Cost: Monad charges gas on the gas LIMIT; ~0.014 MON per transaction. 4 wallets x 20 rounds is roughly 1.5 MON in total.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
RPC="${RPC_URL:-https://testnet-rpc.monad.xyz}"; KS="${KEYSTORE:-$ROOT/.dev/keystore/montions-testnet}"; PASS="${PASSFILE:-$ROOT/.dev/testnet.pass}"
ADDR="$(cast wallet address --keystore "$KS" --password-file "$PASS")"
BAL="$(cast balance "$ADDR" --rpc-url "$RPC" --ether | awk '{print $1}')"
echo "funder $ADDR has $BAL MON"
python3 -c "import sys; sys.exit(0 if float('$BAL') >= 1.0 else 1)" || { echo "Fund the deployer with >= 2 testnet MON first: $ADDR  (https://faucet.monad.xyz)"; exit 2; }
export FUNDER_KEY="$(cast wallet private-key --keystore "$KS" --password-file "$PASS")"
export DEPLOYMENT="$ROOT/app/public/deployment.testnet.json" RPC_URL="$RPC" WALLETS_FILE="$ROOT/.dev/activity-wallets.json"
cd bots && [ -d node_modules ] || pnpm install >/dev/null
exec pnpm exec tsx src/activity.ts --rounds "${1:-20}"

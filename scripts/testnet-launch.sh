#!/usr/bin/env bash
# One-shot testnet launch: real-price pools, all assets, markets, quotes and trading activity.
# Usage: scripts/testnet-launch.sh [--dry]          Needs ~20 testnet MON on the deployer (prints the exact address/balance).
# Order: 1) sync MON/NVDA pools onto Pyth  2) add crypto (14)  3) add stocks (12)  4) keeper quotes markets  5) wallet activity  6) start bots
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
DRY="${1:-}"
KS="${KEYSTORE:-$ROOT/.dev/keystore/montions-testnet}"; PASS="${PASSFILE:-$ROOT/.dev/testnet.pass}"
ADDR="$(cast wallet address --keystore "$KS" --password-file "$PASS")"
# Prefer the Alchemy endpoint for bots when a key is configured (higher rate limits than the public RPC).
AK="$( { grep -hE '^VITE_ALCHEMY_KEY=' app/.env app/.env.local 2>/dev/null || true; } | head -1 | cut -d= -f2- | tr -d ' "\r')"; AK="${AK##*/}"
export RPC_URL="${RPC_URL:-$([ -n "$AK" ] && echo "https://monad-testnet.g.alchemy.com/v2/$AK" || echo https://testnet-rpc.monad.xyz)}"
BAL="$(cast balance "$ADDR" --rpc-url "$RPC_URL" --ether | awk '{print $1}')"
echo "deployer $ADDR  balance $BAL MON  (rpc: ${RPC_URL%%/v2/*})"
scripts/testnet-add-assets.sh crypto 14 --dry; scripts/testnet-add-assets.sh stocks 12 --dry
[ "$DRY" = "--dry" ] && exit 0
python3 -c "import sys; sys.exit(0 if float('$BAL') >= 18 else 1)" || { echo "Need about 20 MON. Fund $ADDR and rerun (every step resumes)."; exit 2; }
KEY="$(cast wallet private-key --keystore "$KS" --password-file "$PASS")"; M="$ROOT/deployments/10143.json"
echo "▶ 1/6 pools onto live Pyth prices";   ( cd bots && for i in $(seq 1 10); do DEPLOYMENT="$M" BOT_PRIVATE_KEY="$KEY" pnpm exec tsx src/price-sync.ts --once | grep -E "synced|hold|error" || true; done )
echo "▶ 2/6 crypto";                         scripts/testnet-add-assets.sh crypto 14
echo "▶ 3/6 stocks";                         scripts/testnet-add-assets.sh stocks 12
echo "▶ 4/6 sync new pools";                 ( cd bots && DEPLOYMENT="$M" BOT_PRIVATE_KEY="$KEY" pnpm exec tsx src/price-sync.ts --once | grep -cE "synced" || true )
echo "▶ 5/6 maker quotes the markets";       ( cd bots && DEPLOYMENT="$M" BOT_PRIVATE_KEY="$KEY" QUOTE_BUDGET=40 pnpm exec tsx src/quote.ts | grep -E "plan|done" || true )
echo "▶ 6/6 trading activity + bots";        scripts/testnet-activity.sh 30 || true; scripts/testnet-bots.sh start
git -C "$ROOT" status --short app/public/deployment.testnet.json
echo "✔ launched. Commit app/public/deployment.testnet.json and redeploy the site (vercel deploy --prod)."

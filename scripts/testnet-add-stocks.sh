#!/usr/bin/env bash
# Add demo STOCK assets (+ light ladder) to the Monad TESTNET deployment.  Usage: scripts/testnet-add-stocks.sh [count=12] [--dry]
# Each stock: token + TWAP pool + oracle/resolver registration (~3M gas, ~0.31 MON) and 10 markets (2 expiries x 5 strikes, batched).
# Budget for 12 stocks: roughly 4 MON for pools + 2-4 MON for markets + ~1.3 MON for the vault to quote them. Prices are DEMO levels, not live quotes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
N="${1:-12}"; DRY="${2:-}"
RPC="${RPC_URL:-https://testnet-rpc.monad.xyz}"; KS="${KEYSTORE:-$ROOT/.dev/keystore/montions-testnet}"; PASS="${PASSFILE:-$ROOT/.dev/testnet.pass}"
M=deployments/10143.json; ADDR="$(cast wallet address --keystore "$KS" --password-file "$PASS")"
SYMS="$(jq -r --argjson n "$N" '.assets[:$n]|map(.symbol)|join(",")' config/stocks-demo.json)"; PRICES="$(jq -r --argjson n "$N" '.assets[:$n]|map(.cents|tostring)|join(",")' config/stocks-demo.json)"
# skip stocks that are already registered
HUB=$(jq -r .contracts.oracleHub $M); NEWS=(); NEWP=()
IFS=, read -ra SA <<<"$SYMS"; IFS=, read -ra PA <<<"$PRICES"
for i in "${!SA[@]}"; do ID=$(cast keccak "${SA[$i]}"); [ "$(cast call "$HUB" 'assetExists(bytes32)(bool)' "$ID" --rpc-url "$RPC")" = "true" ] || { NEWS+=("${SA[$i]}"); NEWP+=("${PA[$i]}"); }; done
[ ${#NEWS[@]} -gt 0 ] || { echo "all $N stocks already registered"; exit 0; }
SYMS="$(IFS=,; echo "${NEWS[*]}")"; PRICES="$(IFS=,; echo "${NEWP[*]}")"
BAL="$(cast balance "$ADDR" --rpc-url "$RPC" --ether | awk '{print $1}')"; NEED=$(python3 -c "print(round(${#NEWS[@]}*0.31+${#NEWS[@]}*0.3+${#NEWS[@]}*0.11,1))")
echo "adding ${#NEWS[@]} stocks: $SYMS   deployer $ADDR has $BAL MON, needs about $NEED MON in total"
[ "$DRY" = "--dry" ] && { echo "(dry run: nothing sent)"; exit 0; }
python3 -c "import sys; sys.exit(0 if float('$BAL') >= float('$NEED') else 1)" || { echo "Not enough MON. Fund $ADDR (https://faucet.monad.xyz) and rerun; it resumes where it stopped."; exit 2; }
export HUB RESOLVER=$(jq -r .contracts.twapResolver $M) COLLATERAL=$(jq -r .contracts.collateral $M) SYMBOLS="$SYMS" PRICES_CENTS="$PRICES" OUT=deployments/new-assets.json DEPLOYER_ADDRESS="$ADDR"
forge script script/AddStocks.s.sol --rpc-url "$RPC" --keystore "$KS" --password-file "$PASS" --sender "$ADDR" --broadcast --slow --disable-code-size-limit > .dev/add-stocks.log 2>&1 || { tail -20 .dev/add-stocks.log; exit 1; }
# merge into both manifests (names from config)
for F in "$M" app/public/deployment.testnet.json; do
  jq --slurpfile new deployments/new-assets.json --slurpfile cfg config/stocks-demo.json \
     '.assets += ($new[0] | map(. as $a | $a + {name: (($cfg[0].assets[]|select(.symbol==$a.symbol)|.name) // $a.symbol)}))' "$F" > "$F.tmp" && mv "$F.tmp" "$F"
done
echo "▶ seeding the light ladder for the new stocks"
KEY="$(cast wallet private-key --keystore "$KS" --password-file "$PASS")"
( cd bots && ONLY_SYMBOLS="$SYMS" DEPLOYMENT="$ROOT/$M" RPC_URL="$RPC" BOT_PRIVATE_KEY="$KEY" pnpm exec tsx src/seed-ladder.ts )
echo "✔ done. Next: scripts/testnet-bots.sh start (keeper quotes them), then commit app/public/deployment.testnet.json and redeploy."

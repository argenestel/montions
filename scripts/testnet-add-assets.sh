#!/usr/bin/env bash
# Add demo assets (+ a light market ladder) to the Monad TESTNET deployment.
# Usage: scripts/testnet-add-assets.sh <stocks|crypto> [count=12] [--dry]
#   stocks: config/stocks-demo.json  approximate levels, NOT live quotes
#   crypto: config/crypto-demo.json  prices read from Pyth on Monad mainnet when the file was generated (real values; the pools are demo TWAP pools)
# Each asset: token + TWAP pool + oracle/resolver registration (~3M gas, ~0.31 MON), then 10 markets (2 expiries x 5 strikes, batched),
# then ~0.11 MON for the vault to quote them. Rerunning skips assets that are already registered, so it resumes after a top-up.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"
SET="${1:?usage: $0 <stocks|crypto> [count] [--dry]}"; N="${2:-12}"; DRY="${3:-}"
CFG="config/${SET}-demo.json"; [ -f "$CFG" ] || { echo "no $CFG (use stocks or crypto)"; exit 1; }
RPC="${RPC_URL:-https://testnet-rpc.monad.xyz}"; KS="${KEYSTORE:-$ROOT/.dev/keystore/montions-testnet}"; PASS="${PASSFILE:-$ROOT/.dev/testnet.pass}"
M=deployments/10143.json; ADDR="$(cast wallet address --keystore "$KS" --password-file "$PASS")"; HUB=$(jq -r .contracts.oracleHub "$M")

# keep only assets that are not registered yet
NEWS=(); NEWP=(); NEWT=()
while IFS=$'\t' read -r sym e6 tier; do
  ID=$(cast keccak "$sym")
  if [ "$(cast call "$HUB" 'assetExists(bytes32)(bool)' "$ID" --rpc-url "$RPC")" != "true" ]; then NEWS+=("$sym"); NEWP+=("$e6"); NEWT+=("$tier"); fi
done < <(jq -r --argjson n "$N" '.assets[:$n][]|[.symbol,(.e6|tostring),.tier]|@tsv' "$CFG")
[ ${#NEWS[@]} -gt 0 ] || { echo "all $N $SET already registered"; exit 0; }
SYMS="$(IFS=,; echo "${NEWS[*]}")"; PRICES="$(IFS=,; echo "${NEWP[*]}")"; TIERS="$(IFS=,; echo "${NEWT[*]}")"

BAL="$(cast balance "$ADDR" --rpc-url "$RPC" --ether | awk '{print $1}')"
NEED=$(python3 -c "print(round(${#NEWS[@]}*0.72,1))")
echo "adding ${#NEWS[@]} $SET: $SYMS"
echo "deployer $ADDR has $BAL MON, needs about $NEED MON in total (pool 0.31 + markets 0.3 + vault quotes 0.11, per asset)"
[ "$DRY" = "--dry" ] && { echo "(dry run: nothing sent)"; exit 0; }
python3 -c "import sys; sys.exit(0 if float('$BAL') >= float('$NEED') else 1)" || { echo "Not enough MON. Fund $ADDR (https://faucet.monad.xyz) and rerun; it resumes where it stopped."; exit 2; }

export HUB RESOLVER=$(jq -r .contracts.twapResolver "$M") COLLATERAL=$(jq -r .contracts.collateral "$M") SYMBOLS="$SYMS" PRICES_E6="$PRICES" TIERS OUT=deployments/new-assets.json DEPLOYER_ADDRESS="$ADDR"
forge script script/AddStocks.s.sol --rpc-url "$RPC" --keystore "$KS" --password-file "$PASS" --sender "$ADDR" --broadcast --slow --disable-code-size-limit > .dev/add-assets.log 2>&1 || { tail -20 .dev/add-assets.log; exit 1; }

# merge into both manifests (display names from the config)
for F in "$M" app/public/deployment.testnet.json; do
  jq --slurpfile new deployments/new-assets.json --slurpfile cfg "$CFG" \
     '.assets += ($new[0] | map(. as $a | ($cfg[0].assets[]|select(.symbol==$a.symbol)) as $c | $a + {name: ($c.name // $a.symbol), feedId: $c.feedId}))' "$F" > "$F.tmp" && mv "$F.tmp" "$F"
done
rm -f deployments/new-assets.json

echo "▶ creating the markets for the new assets"
KEY="$(cast wallet private-key --keystore "$KS" --password-file "$PASS")"
( cd bots && ONLY_SYMBOLS="$SYMS" DEPLOYMENT="$ROOT/$M" RPC_URL="$RPC" BOT_PRIVATE_KEY="$KEY" pnpm exec tsx src/seed-ladder.ts )
echo "✔ done. Next: scripts/testnet-bots.sh start (the keeper quotes them), commit app/public/deployment.testnet.json and redeploy the site."

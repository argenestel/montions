#!/usr/bin/env bash
# Post-deployment verification: reads the live chain and checks the manifest against what is actually deployed.
# Usage: scripts/verify-deployment.sh deployments/143.json [--expect-paused|--expect-unpaused]
# Exits non-zero on ANY failed check. Read-only (eth_call only).
set -uo pipefail
M="${1:?manifest path}"; EXPECT="${2:---expect-paused}"
RPC="${RPC_URL:-$(jq -r .rpc "$M")}"; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=1; }
chk()  { if [ "$2" = "$3" ]; then ok "$1 ($2)"; else bad "$1: expected $3, got $2"; fi; }
J() { jq -r ".contracts.$1 // empty" "$M"; }
BOOK=$(J book); QUOTER=$(J quoter); USDC=$(J collateral); ORACLE=$(J pythOracle); RES=$(J pythResolver); VAULT=$(J vault); SAFE=$(jq -r '.ownerSafe // empty' "$M")
echo "verifying $(jq -r .network "$M") chain $(jq -r .chainId "$M") via $RPC"
chk "rpc chain id" "$(cast chain-id --rpc-url "$RPC")" "$(jq -r .chainId "$M")"
for n in BOOK QUOTER USDC ORACLE RES; do a="${!n}"; [ -n "$a" ] && [ "$(cast code "$a" --rpc-url "$RPC" | wc -c)" -gt 4 ] && ok "$n has code" || bad "$n has no code"; done
chk "collateral decimals" "$(cast call "$USDC" 'decimals()(uint8)' --rpc-url "$RPC")" "6"
chk "book collateral == manifest" "$(cast call "$BOOK" 'collateral()(address)' --rpc-url "$RPC" | tr 'A-F' 'a-f')" "$(echo "$USDC" | tr 'A-F' 'a-f')"
PAUSED=$(cast call "$BOOK" 'paused()(bool)' --rpc-url "$RPC"); [ "$EXPECT" = "--expect-unpaused" ] && chk "book paused" "$PAUSED" "false" || chk "book paused (must start paused)" "$PAUSED" "true"
# Read each cap through its own single-value getter (multi-value `cast call` decoding is unreliable across cast versions).
CAP=$(cast call "$BOOK" 'collateralCap()(uint256)' --rpc-url "$RPC" | awk '{print $1}')
SCAP=$(cast call "$BOOK" 'seriesPoolCap()(uint256)' --rpc-url "$RPC" | awk '{print $1}')
[ -n "$CAP" ] && [ -n "$SCAP" ] || bad "could not read the caps — refusing to pass"
echo "  info collateralCap=$CAP seriesPoolCap=$SCAP"
MAX=115792089237316195423570985008687907853269984665640564039457584007913129639935
[ -n "$CAP" ] && [ "$CAP" != "$MAX" ] && ok "collateral cap is finite" || bad "collateral cap is UNLIMITED — set a launch cap"
[ -n "$SCAP" ] && [ "$SCAP" != "$MAX" ] && ok "series cap is finite" || bad "series cap is UNLIMITED — set a launch cap"
chk "pyth resolver allowed in book" "$(cast call "$BOOK" 'resolverAllowed(address)(bool)' "$RES" --rpc-url "$RPC")" "true"
for sym in $(jq -r '.assets[].symbol' "$M"); do id=$(cast keccak "$sym"); h=$(cast call "$ORACLE" 'isHealthy(bytes32)(bool)' "$id" --rpc-url "$RPC" 2>&1 | head -1); chk "oracle healthy: $sym" "$h" "true"; done
OWNER=$(cast call "$BOOK" 'owner()(address)' --rpc-url "$RPC"); echo "  info book owner=$OWNER"
if [ -n "$SAFE" ] && [ "$(echo "$OWNER" | tr 'A-F' 'a-f')" = "$(echo "$SAFE" | tr 'A-F' 'a-f')" ]; then ok "book owned by Safe"; else echo "  WARN book owner is not the Safe yet (expected until the handover step)"; fi
if [ -n "$VAULT" ]; then chk "vault trusted resolver" "$(cast call "$VAULT" 'trustedResolver()(address)' --rpc-url "$RPC" | tr 'A-F' 'a-f')" "$(echo "$RES" | tr 'A-F' 'a-f')"; fi
TOT=$(cast call "$BOOK" 'totalCollateral()(uint256)' --rpc-url "$RPC" | awk '{print $1}'); BAL=$(cast call "$USDC" 'balanceOf(address)(uint256)' "$BOOK" --rpc-url "$RPC" | awk '{print $1}')
[ "$BAL" -ge "$TOT" ] && ok "Book USDC balance ($BAL) >= tracked collateral ($TOT)" || bad "SOLVENCY: Book USDC balance $BAL < tracked collateral $TOT"
[ $FAIL -eq 0 ] && { echo "ALL CHECKS PASSED"; exit 0; } || { echo "CHECKS FAILED"; exit 1; }

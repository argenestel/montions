#!/usr/bin/env bash
# MAINNET-FORK REHEARSAL — no real transactions. Forks Monad mainnet into a local anvil and runs the production path end to end:
#  guarded deploy (paused) -> verify -> two-step ownership handover -> unpause -> create Pyth-priced series -> REAL USDC trading ->
#  wait for real expiry -> fetch REAL signed Pyth data from Hermes -> settle through the REAL Pyth contract -> resolve -> redeem -> solvency check.
# Usage: scripts/fork-rehearsal.sh        (needs internet: Monad RPC + Pyth Hermes; takes ~4 minutes)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"; cd "$ROOT"; mkdir -p .dev
PORT="${FORK_PORT:-8549}"; SRC="${MAINNET_RPC:-https://rpc.monad.xyz}"; RPC="http://127.0.0.1:$PORT"; HERMES="${HERMES_URL:-https://hermes.pyth.network}"
USDC=0x754704Bc059F8C67012fEd69BC8A327a5aafb603; PYTH=0x2880aB155794e7179c9eE2e38200202908C17B43
FEED=0x31491744e2dbf6df7fcf4ac0820d18a609b49076d45066d3568424e62f686cd1; MONID=$(cast keccak MON)
step() { printf '\n\033[1m▶ %s\033[0m\n' "$*"; }; die() { printf '\033[31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }
pass() { printf '  \033[32mPASS\033[0m %s\n' "$*"; }
cleanup() { [ "${FORK_KEEP:-0}" = 1 ] && { echo "(FORK_KEEP=1: fork left running on :$PORT, pid $(cat .dev/fork.pid))"; return; }; [ -f .dev/fork.pid ] && kill "$(cat .dev/fork.pid)" 2>/dev/null || true; rm -f .dev/fork.pid; }; trap cleanup EXIT

step "forking Monad mainnet ($SRC) on :$PORT"
nohup anvil --fork-url "$SRC" --chain-id 143 --host 127.0.0.1 --port "$PORT" --code-size-limit 60000 --block-base-fee-per-gas 0 --silent > .dev/fork.log 2>&1 & echo $! > .dev/fork.pid
for _ in $(seq 1 100); do cast block-number --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.3; done
[ "$(cast chain-id --rpc-url "$RPC")" = "143" ] || die "fork did not start (see .dev/fork.log)"
pass "forked at block $(cast block-number --rpc-url "$RPC")"
ACC=($(cast rpc eth_accounts --rpc-url "$RPC" | jq -r '.[]')); DEP=${ACC[0]}; SAFE=${ACC[1]}; U1=${ACC[2]}; U2=${ACC[3]}
# Decode word N of a raw eth_call result (cast 1.5 prints only the first value of multi-value returns).
word() { cast to-dec "0x${1:$((2 + 64 * $2)):64}"; }
send() { cast send "$@" --unlocked --rpc-url "$RPC" >/dev/null; }

step "guarded deploy (refuses without the acknowledgement; deploys PAUSED with caps)"
export OWNER_SAFE="$SAFE" COLLATERAL_CAP_USDC=10000 SERIES_POOL_CAP_USDC=500 DEPLOY_VAULT=0
if forge script script/DeployProd.s.sol:DeployProd --rpc-url "$RPC" --unlocked --sender "$DEP" >/dev/null 2>&1; then die "deploy ran WITHOUT the mainnet acknowledgement"; else pass "refused without CONFIRM_MAINNET"; fi
export CONFIRM_MAINNET=I_UNDERSTAND_THIS_IS_UNAUDITED_AND_USES_REAL_FUNDS
timeout 600 forge script script/DeployProd.s.sol:DeployProd --rpc-url "$RPC" --broadcast --slow --unlocked --sender "$DEP" --disable-code-size-limit > .dev/deploy.log 2>&1 || { tail -30 .dev/deploy.log; die "deploy failed"; }
CHAIN_ID=143 PRIMARY_RPC="$RPC" node scripts/finish-manifest.mjs .dev/fork-143.json >/dev/null
jq --arg r "$RPC" '.rpc=$r' .dev/fork-143.json > .dev/fork-143.tmp && mv .dev/fork-143.tmp .dev/fork-143.json
J() { jq -r ".contracts.$1" .dev/fork-143.json; }; BOOK=$(J book); RES=$(J pythResolver); ORACLE=$(J pythOracle); QUOTER=$(J quoter)
pass "Book $BOOK"

step "post-deploy verification (must be PAUSED)"
scripts/verify-deployment.sh .dev/fork-143.json --expect-paused || die "verification failed"

step "two-step ownership handover to the 'Safe' (EOA stand-in on the fork)"
for c in "$BOOK" "$ORACLE" "$RES" "$(J timelockResolver)" "$QUOTER"; do send "$c" "requestOwnershipHandover()" --from "$SAFE"; done
CONTRACTS="$BOOK,$ORACLE,$RES,$(J timelockResolver),$QUOTER" NEW_OWNER="$SAFE" ALLOW_EOA_OWNER=1 timeout 300 forge script script/HandoverOwnership.s.sol:HandoverOwnership --rpc-url "$RPC" --broadcast --slow --unlocked --sender "$DEP" --disable-code-size-limit >/dev/null 2>&1 || die "handover failed"
lc() { echo "$1" | tr "A-F" "a-f"; }
[ "$(lc "$(cast call "$BOOK" 'owner()(address)' --rpc-url "$RPC")")" = "$(lc "$SAFE")" ] && pass "Book now owned by $SAFE" || die "handover did not take effect"
send "$BOOK" "setPaused(bool)" false --from "$DEP" 2>/dev/null && die "deployer could still unpause after handover" || pass "old owner can no longer act"
send "$BOOK" "setPaused(bool)" false --from "$SAFE"
scripts/verify-deployment.sh .dev/fork-143.json --expect-unpaused || die "verification (unpaused) failed"

step "give two users REAL USDC (set balances in the fork's USDC storage) and check the real token works with the Book"
for u in "$U1" "$U2"; do slot=$(cast index address "$u" 9); cast rpc anvil_setStorageAt "$USDC" "$slot" "$(cast to-uint256 1000000000)" --rpc-url "$RPC" >/dev/null; done
[ "$(cast call "$USDC" 'balanceOf(address)(uint256)' "$U1" --rpc-url "$RPC" | awk '{print $1}')" = "1000000000" ] || die "could not fund test users (USDC storage layout changed?)"
pass "users funded with 1,000 USDC each"

step "create Pyth-priced series (expiry in ~150s): strike=0.5x spot (YES), 1.0x spot, 1.5x spot (NO)"
NOW=$(date +%s); EXP=$(( (NOW + 160 + 4) / 5 * 5 )); SPOT=$(word "$(cast call "$ORACLE" 'latestPrice(bytes32)' "$MONID" --rpc-url "$RPC")" 0)
echo "  spot (WAD) = $SPOT  expiry = $EXP"
mk() { cast abi-encode "f(address,bytes32,uint256,bool,uint32)" "$ORACLE" "$MONID" "$1" true 300; }
declare -A SID
for m in 50 100 150; do K=$(( SPOT * m / 100 )); D=$(mk "$K"); send "$BOOK" "createSeries(address,bytes,uint64)" "$RES" "$D" "$EXP" --from "$U1"; SID[$m]=$(cast call "$BOOK" "seriesIdOf(address,bytes,uint64)(bytes32)" "$RES" "$D" "$EXP" --rpc-url "$RPC"); done
pass "3 series created"; Y=${SID[50]}

step "trade on the YES-expected series with REAL USDC: U2 bids YES@40 x100, U1 writes (sells YES) @40 x100"
send "$USDC" "approve(address,uint256)" "$BOOK" 1000000000 --from "$U1"; send "$USDC" "approve(address,uint256)" "$BOOK" 1000000000 --from "$U2"
send "$BOOK" "deposit(uint256)" 100000000 --from "$U1"; send "$BOOK" "deposit(uint256)" 100000000 --from "$U2"
send "$BOOK" "placeOrder((bytes32,uint8,uint8,uint64,bool,uint8,uint16))" "($Y,0,40,100,false,0,0)" --from "$U2"
send "$BOOK" "placeOrder((bytes32,uint8,uint8,uint64,bool,uint8,uint16))" "($Y,1,40,100,false,1,0)" --from "$U1"
YES_ID=$(cast call "$BOOK" 'seriesInfo(bytes32)((address,bytes,uint64,uint8,bool,uint256,uint256,uint64))' "$Y" --rpc-url "$RPC" --json | jq -r '.[0][5]' | python3 -c "import sys; v=sys.stdin.read().strip(); print(int(v,16) if v.startswith('0x') else int(v))")
U2YES=$(cast call "$BOOK" 'balanceOf(address,uint256)(uint256)' "$U2" "$YES_ID" --rpc-url "$RPC" | awk '{print $1}')
if [ "$U2YES" = "100" ]; then pass "U2 holds 100 YES after the fill"; else
  echo "  DEBUG yesId=$YES_ID U2 YES=$U2YES orders=$(cast call "$BOOK" 'orderCount()(uint64)' --rpc-url "$RPC") U1 cash=$(cast call "$BOOK" 'cash(address)(uint256)' "$U1" --rpc-url "$RPC" | awk '{print $1}') U2 cash=$(cast call "$BOOK" 'cash(address)(uint256)' "$U2" --rpc-url "$RPC" | awk '{print $1}') U2 locked=$(cast call "$BOOK" 'lockedCash(address)(uint256)' "$U2" --rpc-url "$RPC" | awk '{print $1}')"
  die "fill did not happen"; fi
TOT=$(cast call "$BOOK" 'totalCollateral()(uint256)' --rpc-url "$RPC" | awk '{print $1}'); BAL=$(cast call "$USDC" 'balanceOf(address)(uint256)' "$BOOK" --rpc-url "$RPC" | awk '{print $1}')
[ "$BAL" -ge "$TOT" ] && pass "solvency: Book USDC $BAL >= tracked $TOT" || die "INSOLVENT mid-trade"

step "is Pyth Hermes reachable? (it requires an API key: export HERMES_API_KEY=...)"
AUTH=(); [ -n "${HERMES_API_KEY:-}" ] && AUTH=(-H "Authorization: Bearer $HERMES_API_KEY")
CODE=$(curl -s -m 20 -o /dev/null -w '%{http_code}' "${AUTH[@]}" "$HERMES/v2/updates/price/$(( $(date +%s) - 120 ))?ids%5B%5D=$FEED&encoding=hex&parsed=true" || echo 000)
if [ "$CODE" = "200" ]; then PYTH_LIVE=1; pass "Hermes reachable (HTTP 200)"; else
  [ "${REQUIRE_PYTH:-0}" = 1 ] && die "Hermes returned HTTP $CODE (set HERMES_API_KEY)"
  PYTH_LIVE=0; printf '  \033[33mSKIP\033[0m live Pyth settlement NOT TESTED (Hermes HTTP %s). Running the VOID safety path instead.\n' "$CODE"
fi

if [ "$PYTH_LIVE" = 1 ]; then
step "wait for the real expiry ($EXP), then fetch REAL signed Pyth data from Hermes"
while [ "$(date +%s)" -lt $((EXP + 6)) ]; do sleep 2; done
SETTLED=0
for t in $(seq "$EXP" $((EXP + 12))); do
  R=$(curl -s -m 20 "${AUTH[@]}" "$HERMES/v2/updates/price/$t?ids%5B%5D=$FEED&encoding=hex&parsed=true") || continue
  DATA=$(echo "$R" | jq -r '.binary.data[0] // empty' 2>/dev/null); [ -z "$DATA" ] && continue
  PT=$(echo "$R" | jq -r '.parsed[0].price.publish_time'); PR=$(echo "$R" | jq -r '.parsed[0].price.price'); CF=$(echo "$R" | jq -r '.parsed[0].price.conf')
  FEE=$(cast call "$PYTH" 'getUpdateFee(bytes[])(uint256)' "[0x$DATA]" --rpc-url "$RPC" | awk '{print $1}')
  echo "  hermes t=$t -> publish_time=$PT price=$PR conf=$CF fee=$FEE wei"
  if cast send "$RES" "settle(bytes32,uint64,bytes[])" "$MONID" "$EXP" "[0x$DATA]" --value "$FEE" --from "$U1" --unlocked --rpc-url "$RPC" >/dev/null 2>.dev/settle.err; then SETTLED=1; break; else echo "  settle reverted ($(tr -d '\n' < .dev/settle.err | cut -c1-120)) — trying next timestamp"; fi
done
[ "$SETTLED" = 1 ] || die "could not settle with real Hermes data"
RAWS=$(cast call "$RES" 'settlements(bytes32,uint64)' "$MONID" "$EXP" --rpc-url "$RPC")
SP=$(word "$RAWS" 0); SPT=$(word "$RAWS" 1); SCF=$(word "$RAWS" 2); [ "$(word "$RAWS" 3)" = "1" ] && SVALID=true || SVALID=false
echo "  stored settlement: priceWad=$SP publishTime=$SPT conf=$SCF valid=$SVALID"
[ "$SVALID" = "true" ] || die "settlement stored as invalid (wide confidence?)"
[ "$SP" = "$(python3 -c "print(int('$PR')*10**10)")" ] && pass "stored price == Pyth's signed price ($PR e-8)" || die "stored price differs from Hermes price"
[ "$SPT" -ge "$EXP" ] && [ "$SPT" -le $((EXP + 300)) ] && pass "publish time $SPT is inside [expiry, expiry+300]" || die "publish time outside window"
if cast send "$RES" "settle(bytes32,uint64,bytes[])" "$MONID" "$EXP" "[0x$DATA]" --value "$FEE" --from "$U2" --unlocked --rpc-url "$RPC" >/dev/null 2>&1; then die "second settle was accepted"; else pass "second settle rejected (first writer wins, price is deterministic)"; fi

step "resolve all three series and check outcomes"
for m in 50 100 150; do send "$BOOK" "resolve(bytes32)" "${SID[$m]}" --from "$U2"; done
st() { cast call "$BOOK" 'seriesInfo(bytes32)((address,bytes,uint64,uint8,bool,uint256,uint256,uint64))' "$1" --rpc-url "$RPC" | tr '\n' ' '; }
OUT50=$(st "${SID[50]}"); OUT150=$(st "${SID[150]}")
echo "$OUT50"  | grep -q ", 2, true," && pass "0.5x-spot series resolved YES" || die "0.5x series wrong: $OUT50"
echo "$OUT150" | grep -q ", 2, false," && pass "1.5x-spot series resolved NO" || die "1.5x series wrong: $OUT150"

step "winner redeems with REAL USDC; Book stays solvent"
BEFORE=$(cast call "$BOOK" 'cash(address)(uint256)' "$U2" --rpc-url "$RPC" | awk '{print $1}')
send "$BOOK" "redeem(bytes32,uint256,uint256)" "$Y" 100 0 --from "$U2"
AFTER=$(cast call "$BOOK" 'cash(address)(uint256)' "$U2" --rpc-url "$RPC" | awk '{print $1}')
[ $((AFTER - BEFORE)) -eq 100000000 ] && pass "U2 redeemed 100 winning contracts = 100.000000 USDC" || die "payout wrong: $((AFTER-BEFORE))"
else
step "VOID safety path: nobody posts a settlement -> cannot resolve early; after VOID_GRACE anyone voids; everyone is paid 50/50"
GRACE=$(cast call "$BOOK" 'VOID_GRACE()(uint64)' --rpc-url "$RPC" | awk '{print $1}')
cast rpc evm_setNextBlockTimestamp "$((EXP + 20))" --rpc-url "$RPC" >/dev/null; cast rpc evm_mine --rpc-url "$RPC" >/dev/null
if cast send "$BOOK" "resolve(bytes32)" "$Y" --from "$U2" --unlocked --rpc-url "$RPC" >/dev/null 2>&1; then die "resolve succeeded with no settlement posted"; else pass "cannot resolve after expiry without a settlement (not ready)"; fi
cast rpc evm_setNextBlockTimestamp "$((EXP + GRACE + 20))" --rpc-url "$RPC" >/dev/null; cast rpc evm_mine --rpc-url "$RPC" >/dev/null
send "$BOOK" "resolve(bytes32)" "$Y" --from "$U2"
st() { cast call "$BOOK" 'seriesInfo(bytes32)((address,bytes,uint64,uint8,bool,uint256,uint256,uint64))' "$1" --rpc-url "$RPC" --json | jq -r '.[0][3]'; }
[ "$(st "$Y")" = "3" ] && pass "series voided after the grace period (status 3)" || die "series not voided: status $(st "$Y")"
NO_ID=$(cast call "$BOOK" 'seriesInfo(bytes32)((address,bytes,uint64,uint8,bool,uint256,uint256,uint64))' "$Y" --rpc-url "$RPC" --json | jq -r '.[0][6]' | python3 -c "import sys; v=sys.stdin.read().strip(); print(int(v,16) if v.startswith('0x') else int(v))")
c2() { cast call "$BOOK" 'cash(address)(uint256)' "$1" --rpc-url "$RPC" | awk '{print $1}'; }
B2=$(c2 "$U2"); B1=$(c2 "$U1")
send "$BOOK" "redeem(bytes32,uint256,uint256)" "$Y" 100 0 --from "$U2"; send "$BOOK" "redeem(bytes32,uint256,uint256)" "$Y" 0 100 --from "$U1"
[ $(( $(c2 "$U2") - B2 )) -eq 50000000 ] && [ $(( $(c2 "$U1") - B1 )) -eq 50000000 ] && pass "void payout: YES holder and NO holder each got 50.000000 USDC for 100 contracts" || die "void payout wrong"
fi

AFTER=$(cast call "$BOOK" 'cash(address)(uint256)' "$U2" --rpc-url "$RPC" | awk '{print $1}')
send "$BOOK" "withdraw(uint256)" "$AFTER" --from "$U2"
[ "$(cast call "$USDC" 'balanceOf(address)(uint256)' "$U2" --rpc-url "$RPC" | awk '{print $1}')" -ge 900000000 ] && pass "U2 withdrew real USDC to the wallet" || die "withdraw failed"
TOT=$(cast call "$BOOK" 'totalCollateral()(uint256)' --rpc-url "$RPC" | awk '{print $1}'); BAL=$(cast call "$USDC" 'balanceOf(address)(uint256)' "$BOOK" --rpc-url "$RPC" | awk '{print $1}')
[ "$BAL" -ge "$TOT" ] && pass "final solvency: Book USDC $BAL >= tracked $TOT" || die "INSOLVENT at end"
if [ "$PYTH_LIVE" = 1 ]; then
  printf '\n\033[1;32mFORK REHEARSAL PASSED\033[0m — full production path incl. LIVE Pyth settlement on a Monad mainnet fork with real USDC.\n'
else
  printf '\n\033[1;33mFORK REHEARSAL PARTIAL PASS\033[0m — deploy/guards/handover/real-USDC trading/void fallback verified.\n\033[1;33mNOT TESTED: live Pyth settlement (Hermes needs HERMES_API_KEY). Re-run with the key before any mainnet launch.\033[0m\n'
fi

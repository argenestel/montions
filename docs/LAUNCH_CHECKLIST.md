# Launch checklist

A box is checked only when it is *true and evidenced*. Mainnet with real funds requires every Gate-1..4 box.

## Gate 0 — Legal (not engineering; get counsel)
- [ ] Jurisdiction review: binary options / event contracts can be regulated (gambling, derivatives, securities).
- [ ] Terms of Service, privacy statement, geo-restriction policy decided and implemented in the frontend host.
- [ ] Decide who the operator is and who holds the owner multisig.

## Gate 1 — Security
- [ ] Professional audit by a reputable firm covering Book, Vault, Quoter, Pyth adapter/resolver; all High/Medium fixed and re-reviewed.
- [ ] Long fuzz/invariant campaigns (≥ 10M runs) and a fork test against live Pyth data pass.
- [ ] Static analysis (Slither) triaged; compiler warnings zero or justified.
- [ ] Bug bounty live (Cantina or Immunefi) with a funded pool.
- [ ] `SECURITY.md` contact is real and monitored.

## Gate 2 — Oracle correctness on mainnet
- [ ] Mainnet-fork test: `PythSettlementResolver.settle` with real Hermes update data succeeds and matches the Pyth price.
- [ ] Feed IDs reviewed (MON/USD, BTC/USD, ETH/USD) and vol parameters set by a named owner with a review cadence.
- [ ] **Pyth Hermes API key** obtained (Pyth Core now requires one), stored as a secret, and the paid plan sized for the settlement volume; a second operator holds a separate key.
- [ ] `HERMES_API_KEY=… REQUIRE_PYTH=1 scripts/fork-rehearsal.sh` prints `FORK REHEARSAL PASSED` (live Pyth settlement verified on a mainnet fork).
- [ ] Keeper that submits settlement is deployed redundantly (≥ 2 independent operators/regions) and alerts on lateness.

## Gate 3 — Operations
- [ ] Owner = Safe multisig (≥ 2-of-3), two-step ownership handover completed and verified onchain.
- [ ] Launch caps set and **verified onchain** after deployment (`collateralCap`, `seriesPoolCap`, vault `maxTotalAssets`); raise policy written.
- [ ] Pause drill rehearsed on testnet: paused ⇒ new risk blocked, `cancel/merge/resolve/redeem/withdraw` still work.
- [ ] Monitoring/alerts: Book collateral vs USDC balance, pause state, keeper lag, Pyth freshness, RPC health.
- [ ] Paid RPC plan or multiple fallbacks configured in `deployment.json` (`rpcs`).
- [ ] Incident runbook (below) assigned to named people.

## Gate 4 — Testnet soak
- [ ] ≥ 7 days on Monad testnet with keepers and external testers; every series resolved correctly; no invariant alerts.
- [ ] Chaos: keeper down for > 1 expiry ⇒ markets void correctly; RPC outage ⇒ UI banners, no wrong state.

## Gate 5 — Frontend
- [ ] Static hosting with CSP, HTTPS, pinned build; no analytics/trackers; domain + status page.
- [ ] Mobile and keyboard/screen-reader pass; risk gate verified on mainnet manifest.

## Incident runbook (summary)
1. Suspected exploit or bad oracle → **pause** (owner Safe). New risk stops; users can still exit.
2. Publish status; keep users informed of what is and is not affected.
3. Reproduce on a fork; prepare fix; do NOT unpause until fix is deployed and reviewed.
4. If a series' settlement is wrong, it cannot be edited: affected series settle as determined by the contracts; communicate clearly and use caps to bound exposure in future.

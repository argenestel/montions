/**
 * Targeted vault refresh with a transaction budget.
 *   1. Markets whose resting quotes are far from the model's fair value (stale after a price move): re-quote or cancel them first.
 *   2. Then unquoted open markets closest to 50/50 (the ones traders are most likely to want).
 *
 *   DEPLOYMENT=../deployments/10143.json BOT_PRIVATE_KEY=0x… REFRESH_BUDGET=60 pnpm exec tsx src/refresh.ts
 */
import { makerVaultAbi } from "../../sdk/src/abi/index.js";
import { MontionsClient } from "../../sdk/src/client.js";
import type { Hex } from "viem";
import { isDryRun, loadBotContext, logLine, makeChain, sendAndWait } from "./runtime.js";

async function main() {
  const dryRun = isDryRun();
  const context = loadBotContext(!dryRun);
  const { deployment, publicClient, walletClient, account } = context;
  const vault = (deployment.contracts.vault ?? deployment.contracts.makerVault) as Hex;
  const budget = Number(process.env.REFRESH_BUDGET ?? 60);
  const staleTicks = Number(process.env.STALE_TICKS ?? 8);
  const minLife = Number(process.env.MIN_LIFE_SEC ?? 1_200);   // the vault stops quoting near expiry anyway
  const client = new MontionsClient({ deployment, chain: makeChain(deployment.chainId, context.rpcUrl), publicClient } as never);
  const snaps = [] as Awaited<ReturnType<MontionsClient["snapshots"]>>;
  for (let o = 0; ; o += 50) { const page = await client.snapshots(o, 50); snaps.push(...page); if (page.length < 50) break; }
  const now = Math.floor(Date.now() / 1000);
  const open = snaps.filter((s) => Number(s.info.status) === 1 && Number(s.info.expiry) > now + minLife);
  const quoted = open.filter((s) => s.askQty > 0n || s.bidQty > 0n);
  const mid = (s: (typeof open)[number]) => (s.askQty > 0n && s.bidQty > 0n ? (s.askTick + s.bidTick) / 2 : s.askQty > 0n ? s.askTick - 2 : s.bidTick + 2);
  const stale = quoted.filter((s) => Math.abs(mid(s) - s.fairTick) >= staleTicks).sort((a, b) => Math.abs(mid(b) - b.fairTick) - Math.abs(mid(a) - a.fairTick));
  const fresh = open.filter((s) => !(s.askQty > 0n || s.bidQty > 0n) && s.fairTick >= 5 && s.fairTick <= 95).sort((a, b) => Math.abs(a.fairTick - 50) - Math.abs(b.fairTick - 50));
  const targets = [...stale, ...fresh].slice(0, budget);
  logLine("refresh", { event: "plan", open: open.length, quoted: quoted.length, stale: stale.length, unquoted_candidates: fresh.length, budget, dry_run: dryRun });
  let ok = 0;
  for (const s of targets) {
    if (dryRun) { logLine("refresh", { event: "would_refresh", title: s.title, fair: s.fairTick, kind: stale.includes(s) ? "stale" : "new" }); continue; }
    try {
      await sendAndWait(context, await walletClient!.writeContract({ address: vault, abi: makerVaultAbi, functionName: "refresh", args: [s.seriesId as Hex], account: account!, chain: undefined }), "vault refresh");
      ok++;
    } catch (e) {
      const msg = String((e as Error).message).split("\n")[0]!.slice(0, 160);
      logLine("refresh", { event: "skip", title: s.title, error: msg });
      if (/insufficient balance|Signer had insufficient/i.test(msg)) break;
    }
  }
  logLine("refresh", { event: "done", refreshed: ok });
}

main().catch((e) => { console.error(e); process.exit(1); });

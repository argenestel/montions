/**
 * Cheap market maker for testnet: posts a two-sided quote (YES bid + YES ask around the onchain fair value) straight on the
 * Book from the bot wallet's cash, several markets per Book.multicall transaction.
 *
 * Why not MakerVault.refresh: on Monad a refresh measured ~6M gas (~0.62 MON) per market because it cancels, merges, prices
 * and posts a 6-order ladder. A resting GTC order measured ~0.37M gas, so a two-sided quote is roughly 10x cheaper.
 *
 *   DEPLOYMENT=../deployments/10143.json BOT_PRIVATE_KEY=0x… QUOTE_BUDGET=40 pnpm exec tsx src/quote.ts [--dry-run]
 *
 * Env: QUOTE_BUDGET (markets per run, 40), QUOTES_PER_TX (4), SPREAD_TICKS (3 each side), QUOTE_QTY (contracts per side, 300),
 *      STALE_TICKS (re-quote when the book mid is this far from fair, 8), MIN_LIFE_SEC (skip markets expiring sooner, 1800).
 */
import { encodeFunctionData, parseAbi, type Address, type Hex } from "viem";
import { montionsBookAbi } from "../../sdk/src/abi/index.js";
import { MontionsClient, encodePlaceOrder } from "../../sdk/src/client.js";
import { envInt, isDryRun, loadBotContext, logLine, makeChain, sendAndWait } from "./runtime.js";

const erc20 = parseAbi(["function allowance(address,address) view returns (uint256)", "function approve(address,uint256) returns (bool)"]);
const TICK = 10_000n;

async function main() {
  const dryRun = isDryRun();
  const context = loadBotContext(!dryRun);
  const { deployment, publicClient, walletClient, account } = context;
  const book = deployment.contracts.book as Address;
  const collateral = deployment.contracts.collateral as Address;
  const budget = envInt("QUOTE_BUDGET", 40, 1);
  const perTx = envInt("QUOTES_PER_TX", 4, 1);
  const spread = envInt("SPREAD_TICKS", 3, 1);
  const qty = BigInt(envInt("QUOTE_QTY", 300, 1));
  const staleTicks = envInt("STALE_TICKS", 8, 1);
  const minLife = envInt("MIN_LIFE_SEC", 1_800, 0);
  const client = new MontionsClient({ deployment, chain: makeChain(deployment.chainId, context.rpcUrl), publicClient } as never);

  const snaps = [] as Awaited<ReturnType<MontionsClient["snapshots"]>>;
  for (let o = 0; ; o += 50) { const page = await client.snapshots(o, 50); snaps.push(...page); if (page.length < 50) break; }
  const now = Math.floor(Date.now() / 1000);
  const open = snaps.filter((s) => Number(s.info.status) === 1 && Number(s.info.expiry) > now + minLife && s.fairTick >= 5 && s.fairTick <= 95);
  const quoted = (s: (typeof open)[number]) => s.askQty > 0n || s.bidQty > 0n;
  const mid = (s: (typeof open)[number]) => (s.askQty > 0n && s.bidQty > 0n ? (s.askTick + s.bidTick) / 2 : s.askQty > 0n ? s.askTick - spread : s.bidTick + spread);
  const stale = open.filter((s) => quoted(s) && Math.abs(mid(s) - s.fairTick) >= staleTicks);
  const fresh = open.filter((s) => !quoted(s)).sort((a, b) => Math.abs(a.fairTick - 50) - Math.abs(b.fairTick - 50));
  const targets = [...stale, ...fresh].slice(0, budget);

  const me = account ? (typeof account === "string" ? account : account.address) as Address : undefined;
  const mine = me ? (await client.orders(me, 0, 500)).filter((o) => o.open) : [];
  logLine("quote", { event: "plan", open: open.length, stale: stale.length, unquoted: fresh.length, targets: targets.length, per_tx: perTx, dry_run: dryRun });
  if (dryRun || !walletClient || !account || targets.length === 0) {
    for (const s of targets) logLine("quote", { event: "would_quote", title: s.title, fair: s.fairTick, bid: Math.max(1, s.fairTick - spread), ask: Math.min(99, s.fairTick + spread) });
    return;
  }

  // Escrow per market: bid locks qty*bid ticks; an ask written from cash locks qty*(100-ask) ticks.
  const escrowOf = (fair: number) => qty * TICK * (BigInt(Math.max(1, fair - spread)) + BigInt(100 - Math.min(99, fair + spread)));
  const allowance = (await publicClient.readContract({ address: collateral, abi: erc20, functionName: "allowance", args: [me!, book] })) as bigint;
  if (allowance < 10n ** 30n) {
    await sendAndWait(context, await walletClient.writeContract({ address: collateral, abi: erc20, functionName: "approve", args: [book, 2n ** 256n - 1n], account, chain: undefined }), "approve");
  }

  let done = 0;
  for (let i = 0; i < targets.length; i += perTx) {
    const group = targets.slice(i, i + perTx);
    const calls: Hex[] = [];
    const cancel = mine.filter((o) => group.some((s) => s.seriesId === o.seriesId)).map((o) => o.id);
    if (cancel.length) calls.push(encodeFunctionData({ abi: montionsBookAbi, functionName: "cancelOrders", args: [cancel] }));
    const need = group.reduce((a, s) => a + escrowOf(s.fairTick), 0n);
    const free = (await client.cashBalances(me!)).free;
    if (need > free) calls.push(encodeFunctionData({ abi: montionsBookAbi, functionName: "deposit", args: [need - free + need / 10n] }));
    for (const s of group) {
      const seriesId = s.seriesId as Hex;
      calls.push(encodePlaceOrder({ seriesId, side: "bid", tick: Math.max(1, s.fairTick - spread), qty, tif: "gtc" }));
      calls.push(encodePlaceOrder({ seriesId, side: "ask", tick: Math.min(99, s.fairTick + spread), qty, tif: "gtc" }));
    }
    try {
      const hash = await walletClient.writeContract({ address: book, abi: montionsBookAbi, functionName: "multicall", args: [calls], account, chain: undefined });
      await sendAndWait(context, hash, "quote multicall");
      const rc = await publicClient.getTransactionReceipt({ hash });
      done += group.length;
      logLine("quote", { event: "quoted", markets: group.map((s) => `${s.title} @${s.fairTick}`), cancelled: cancel.length, gas: rc.gasUsed, hash });
    } catch (e) {
      const msg = String((e as Error).message).split("\n")[0]!.slice(0, 180);
      logLine("quote", { event: "skip", markets: group.map((s) => s.title), error: msg });
      if (/insufficient balance|Signer had insufficient/i.test(msg)) break;
    }
  }
  logLine("quote", { event: "done", quoted: done });
}

main().catch((e) => { console.error(e); process.exit(1); });

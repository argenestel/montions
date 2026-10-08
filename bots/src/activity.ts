/**
 * Test-activity bot: a handful of throwaway wallets that trade against the live book so a testnet (or a local fork) shows real fills,
 * resting orders and positions instead of zeros.
 *
 *   DEPLOYMENT=../app/public/deployment.testnet.json RPC_URL=https://testnet-rpc.monad.xyz \
 *   FUNDER_KEY=0x…   pnpm exec tsx src/activity.ts --rounds 20
 *
 * - Wallets are generated once into WALLETS_FILE (default .dev/activity-wallets.json, gitignored) and reused.
 * - If FUNDER_KEY is set, wallets below MIN_MON are topped up to TOPUP_MON from it. Otherwise the bot prints the addresses that need MON.
 * - Test collateral comes from the token's public faucet() (testnet) — or is expected to be present already (fork).
 * - Each round a random wallet buys YES/NO against the best resting orders, posts a resting limit order, or cancels one.
 * - Gas on Monad is charged on the gas limit; one transaction costs about 0.01 MON at current prices, so budget accordingly.
 */
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { createPublicClient, createWalletClient, defineChain, formatEther, http, parseAbi, parseEther, type Address, type Hex } from "viem";
import { generatePrivateKey, privateKeyToAccount } from "viem/accounts";
import { MontionsClient } from "../../sdk/src/client.js";
import { parseDeployment } from "../../sdk/src/deployments.js";
import { sleep } from "./runtime.js";

const arg = (name: string, fallback: string) => { const i = process.argv.indexOf(name); return i >= 0 && process.argv[i + 1] ? process.argv[i + 1]! : fallback; };
const env = (name: string, fallback: string) => process.env[name] || fallback;

const deploymentFile = resolve(process.cwd(), env("DEPLOYMENT", "../app/public/deployment.testnet.json"));
const deployment = parseDeployment(JSON.parse(readFileSync(deploymentFile, "utf8")) as unknown);
const rpc = env("RPC_URL", deployment.rpc);
const chain = defineChain({
  id: deployment.chainId, name: `chain ${deployment.chainId}`, nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
  rpcUrls: { default: { http: [rpc] } }, contracts: { multicall3: { address: "0xcA11bde05977b3631167028862bE2a173976CA11" } },
});
const publicClient = createPublicClient({ chain, transport: http(rpc, { retryCount: 3 }) });

const WALLETS = Number(env("WALLET_COUNT", "4"));
const ROUNDS = Number(arg("--rounds", env("ROUNDS", "20")));
const MIN_MON = parseEther(env("MIN_MON", "0.15"));
const TOPUP_MON = parseEther(env("TOPUP_MON", "0.4"));
const PAUSE_MS = Number(env("PAUSE_MS", "4000"));
const walletsFile = resolve(process.cwd(), env("WALLETS_FILE", "../.dev/activity-wallets.json"));
const USDC = 1_000_000n;

const erc20 = parseAbi(["function balanceOf(address) view returns (uint256)", "function faucet()"]);
const collateral = deployment.contracts.collateral as Address;

function loadWallets(): Hex[] {
  let keys: Hex[] = [];
  if (existsSync(walletsFile)) keys = JSON.parse(readFileSync(walletsFile, "utf8")) as Hex[];
  while (keys.length < WALLETS) keys.push(generatePrivateKey());
  mkdirSync(dirname(walletsFile), { recursive: true });
  writeFileSync(walletsFile, JSON.stringify(keys, null, 2), { mode: 0o600 });
  return keys.slice(0, WALLETS);
}

const log = (o: Record<string, unknown>) => console.log(JSON.stringify({ t: new Date().toISOString(), ...o }, (_, v) => (typeof v === "bigint" ? v.toString() : v)));
const pick = <T,>(xs: T[]): T => xs[Math.floor(Math.random() * xs.length)]!;
const between = (lo: number, hi: number) => lo + Math.floor(Math.random() * (hi - lo + 1));

async function main() {
  const funder = process.env.FUNDER_KEY ? privateKeyToAccount(process.env.FUNDER_KEY as Hex) : undefined;
  const funderWallet = funder ? createWalletClient({ account: funder, chain, transport: http(rpc) }) : undefined;
  const keys = loadWallets();
  const traders = keys.map((k) => {
    const account = privateKeyToAccount(k);
    const walletClient = createWalletClient({ account, chain, transport: http(rpc, { retryCount: 3 }) });
    return { account, walletClient, client: new MontionsClient({ deployment, chain, rpcUrl: rpc, publicClient, walletClient, account } as never) };
  });
  log({ event: "start", chain: deployment.chainId, wallets: traders.map((t) => t.account.address), rounds: ROUNDS });

  // 1) gas + collateral
  const ready: typeof traders = [];
  for (const t of traders) {
    let native = await publicClient.getBalance({ address: t.account.address });
    if (native < MIN_MON && funderWallet) {
      try {
        const h = await funderWallet.sendTransaction({ to: t.account.address, value: TOPUP_MON - native });
        await publicClient.waitForTransactionReceipt({ hash: h });
        native = await publicClient.getBalance({ address: t.account.address });
        log({ event: "funded", wallet: t.account.address, mon: formatEther(native) });
      } catch (e) { log({ event: "fund_failed", wallet: t.account.address, error: String((e as Error).message).split("\n")[0] }); }
    }
    if (native < MIN_MON / 3n) { log({ event: "needs_mon", wallet: t.account.address, have: formatEther(native) }); continue; }
    const usdc = (await publicClient.readContract({ address: collateral, abi: erc20, functionName: "balanceOf", args: [t.account.address] })) as bigint;
    if (usdc < 500n * USDC) {
      try { const h = await t.walletClient.writeContract({ address: collateral, abi: erc20, functionName: "faucet", account: t.account, chain }); await publicClient.waitForTransactionReceipt({ hash: h }); log({ event: "faucet", wallet: t.account.address }); }
      catch (e) { log({ event: "faucet_failed", wallet: t.account.address, error: String((e as Error).message).split("\n")[0] }); }
    }
    ready.push(t);
  }
  if (ready.length === 0) { log({ event: "no_funded_wallets", hint: "send testnet MON to the addresses above (faucet.monad.xyz) or set FUNDER_KEY" }); process.exitCode = 2; return; }

  // 2) trade
  const stats = { buys: 0, rests: 0, cancels: 0, skipped: 0, failed: 0, spent: 0 };
  for (let round = 1; round <= ROUNDS; round++) {
    const t = pick(ready);
    try {
      const now = Math.floor(Date.now() / 1000);
      const snaps: Awaited<ReturnType<MontionsClient["snapshots"]>> = [];
      for (let o = 0; ; o += 50) { const page = await t.client.snapshots(o, 50); snaps.push(...page); if (page.length < 50) break; }
      const open = snaps.filter((s) => Number(s.info.status) === 1 && Number(s.info.expiry) > now + 900 && (s.askQty > 0n || s.bidQty > 0n));
      if (open.length === 0) { stats.skipped++; log({ event: "skip", round, why: "no liquid open markets" }); await sleep(PAUSE_MS); continue; }
      const roll = Math.random();
      const mine = (await t.client.orders(t.account.address, 0, 50)).filter((o) => o.open);

      if (roll > 0.85 && mine.length > 0) {
        const o = pick(mine); const h = await t.client.cancelOrder(o.id); await publicClient.waitForTransactionReceipt({ hash: h });
        stats.cancels++; log({ event: "cancel", round, wallet: t.account.address, order: o.id, hash: h });
      } else if (roll > 0.65) {
        // resting bid a couple of ticks under the best ask (adds depth the other wallets can hit)
        const s = pick(open.filter((x) => x.askQty > 0n && x.askTick > 6)); if (!s) { stats.skipped++; continue; }
        const tick = Math.max(1, s.askTick - 3), qty = BigInt(between(40, 150));
        const escrow = qty * BigInt(tick) * 10_000n; const cash = (await t.client.cashBalances(t.account.address)).free;
        const need = (escrow * 102n) / 100n + 1n;
        const params = { seriesId: s.seriesId as Hex, side: "bid", tick, qty, tif: "gtc", fromHeld: false } as const;
        const h = need > cash ? await t.client.depositWithPermitAndPlaceOrder(need - cash, params, { permit: await t.client.signPermit({ amount: need - cash, owner: t.account.address }) }) : await t.client.placeOrder(params);
        await publicClient.waitForTransactionReceipt({ hash: h });
        stats.rests++; log({ event: "rest", round, wallet: t.account.address, tick, qty, hash: h });
      } else {
        const s = pick(open); const yes = Math.random() < 0.55; const contracts = BigInt(between(20, 200));
        const q = await t.client.quoteBuy(s.seriesId as Hex, yes, contracts, 99);
        if (q.filled === 0n) { stats.skipped++; log({ event: "skip", round, why: "no fill at any price" }); await sleep(PAUSE_MS); continue; }
        const worst = Math.min(99, q.worstTick + 1), tick = yes ? worst : Math.max(1, 100 - worst);
        const escrow = yes ? contracts * BigInt(tick) * 10_000n : contracts * BigInt(100 - tick) * 10_000n;
        const need = (escrow * 102n) / 100n + 1n; const cash = (await t.client.cashBalances(t.account.address)).free;
        const params = { seriesId: s.seriesId as Hex, side: yes ? "bid" : "ask", tick, qty: contracts, tif: "ioc", fromHeld: false } as const;
        const h = need > cash ? await t.client.depositWithPermitAndPlaceOrder(need - cash, params, { permit: await t.client.signPermit({ amount: need - cash, owner: t.account.address }) }) : await t.client.placeOrder(params);
        const rc = await publicClient.waitForTransactionReceipt({ hash: h });
        if (rc.status !== "success") throw new Error("reverted");
        stats.buys++; stats.spent += Number(q.cost) / 1e6;
        log({ event: "buy", round, wallet: t.account.address, side: yes ? "YES" : "NO", contracts, costUsd: Number(q.cost) / 1e6, avgTick: q.avgTick, hash: h });
      }
    } catch (e) {
      stats.failed++; const msg = String((e as Error).message).split("\n")[0]!.slice(0, 160);
      log({ event: "error", round, error: msg });
      if (/insufficient|Signer had insufficient balance/i.test(msg)) { log({ event: "out_of_gas", hint: "top up the wallets with testnet MON" }); break; }
    }
    await sleep(PAUSE_MS + between(0, 2000));
  }
  log({ event: "done", ...stats });
}

main().catch((e) => { console.error(e); process.exit(1); });

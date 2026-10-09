/**
 * Price sync: keeps each testnet pool's price on the REAL Pyth price published on Monad mainnet.
 *
 * For every manifest asset with a `feedId`, it reads Pyth's latest price on mainnet (PRICE_SOURCE_RPC, default https://rpc.monad.xyz)
 * and, if the testnet pool is more than SYNC_BPS away, swaps the exact amount that moves the constant-product pool onto that price
 * (capped at MAX_MOVE_BPS of reserves per step, so large gaps close over a few steps). Mainnet prices older than MAX_AGE_SEC are not
 * followed (e.g. equity feeds outside market hours or not pushed recently): the pool then keeps its last real price instead of
 * inventing movement.
 *
 *   DEPLOYMENT=../deployments/10143.json BOT_PRIVATE_KEY=0x… pnpm exec tsx src/price-sync.ts [--once]
 *
 * Gas: one swap per asset that drifted. Monad charges the gas limit, so SYNC_BPS (default 30 = 0.3%) and the interval set the cost.
 */
import { createPublicClient, http, type Address, type Hex } from "viem";
import { erc20Abi } from "../../sdk/src/abi/erc20.js";
import { hasFlag, isDryRun, loadBotContext, logLine, requirePool, requireToken, sendAndWait } from "./runtime.js";

const PYTH = "0x2880aB155794e7179c9eE2e38200202908C17B43" as const;
const pythAbi = [{
  type: "function", name: "getPriceUnsafe", stateMutability: "view", inputs: [{ name: "id", type: "bytes32" }],
  outputs: [{ type: "tuple", components: [{ name: "price", type: "int64" }, { name: "conf", type: "uint64" }, { name: "expo", type: "int32" }, { name: "publishTime", type: "uint256" }] }],
}] as const;
const poolAbi = [
  { type: "function", name: "baseReserve", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "quoteReserve", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "priceWad", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
  { type: "function", name: "swapExactIn", stateMutability: "nonpayable", inputs: [{ name: "tokenIn", type: "address" }, { name: "amountIn", type: "uint256" }, { name: "minOut", type: "uint256" }, { name: "to", type: "address" }], outputs: [{ type: "uint256" }] },
] as const;
const mintAbi = [{ type: "function", name: "mint", stateMutability: "nonpayable", inputs: [{ name: "to", type: "address" }, { name: "amount", type: "uint256" }], outputs: [] }] as const;

const WAD = 10n ** 18n;
const PRICE_SCALE = 10n ** 30n;            // SpotPool.priceWad = quote(6 dp) * 1e30 / base(18 dp)
const num = (name: string, fallback: number) => { const v = Number(process.env[name] ?? fallback); if (!Number.isFinite(v) || v <= 0) throw new Error(`${name} must be positive`); return v; };

export function isqrt(n: bigint): bigint {
  if (n < 0n) throw new RangeError("negative");
  if (n < 2n) return n;
  let x = BigInt(Math.floor(Math.sqrt(Number(n))));
  while (x * x > n) x = (x + n / x) >> 1n;
  while ((x + 1n) * (x + 1n) <= n) x += 1n;
  return x;
}

/** Pyth price → 1e18-scaled USD. */
export function pythToWad(price: bigint, expo: number): bigint {
  if (price <= 0n) return 0n;
  return expo >= 0 ? price * 10n ** BigInt(expo) * WAD : (price * WAD) / 10n ** BigInt(-expo);
}

/**
 * Swap that moves an x*y=k pool (0.3% input fee) from its price to `targetWad`, capped at `maxMoveBps` of the input reserve.
 * Returns which side to sell and how much (0 when already within tolerance).
 */
export function planSync(base: bigint, quote: bigint, targetWad: bigint, maxMoveBps: bigint): { sellBase: boolean; amountIn: bigint } {
  const k = base * quote;
  // target reserves on the curve: quote' = sqrt(k * P / 1e30), base' = sqrt(k * 1e30 / P)
  const quoteTarget = isqrt((k * targetWad) / PRICE_SCALE);
  const baseTarget = isqrt((k * PRICE_SCALE) / targetWad);
  if (quoteTarget > quote) {                                // price must go UP: buy base with quote
    let amountIn = ((quoteTarget - quote) * 1000n) / 997n;
    const cap = (quote * maxMoveBps) / 10_000n; if (amountIn > cap) amountIn = cap;
    return { sellBase: false, amountIn };
  }
  let amountIn = ((baseTarget > base ? baseTarget - base : 0n) * 1000n) / 997n;   // price must go DOWN: sell base
  const cap = (base * maxMoveBps) / 10_000n; if (amountIn > cap) amountIn = cap;
  return { sellBase: true, amountIn };
}

async function main() {
  const dryRun = isDryRun();
  const once = hasFlag("--once");
  const context = loadBotContext(!dryRun);
  const { deployment, publicClient, walletClient, account } = context;
  const source = createPublicClient({ transport: http(process.env.PRICE_SOURCE_RPC ?? "https://rpc.monad.xyz", { retryCount: 3 }) });
  const syncBps = BigInt(Math.round(num("SYNC_BPS", 30)));
  const maxMoveBps = BigInt(Math.round(num("MAX_MOVE_BPS", 2_500)));
  const maxAge = num("MAX_AGE_SEC", 7_200);
  const intervalMs = num("PRICE_SYNC_INTERVAL_MS", 60_000);
  const collateral = deployment.contracts.collateral as Address;
  const assets = deployment.assets.filter((a) => a.feedId && a.pool && a.token);
  const me = account ? (typeof account === "string" ? account : account.address) : undefined;
  logLine("price-sync", { event: "start", assets: assets.map((a) => a.symbol), sync_bps: Number(syncBps), max_age_sec: maxAge, dry_run: dryRun });

  do {
    const now = Math.floor(Date.now() / 1000);
    for (const asset of assets) {
      try {
        const p = await source.readContract({ address: PYTH, abi: pythAbi, functionName: "getPriceUnsafe", args: [asset.feedId as Hex] });
        const age = now - Number(p.publishTime);
        if (age > maxAge) { logLine("price-sync", { event: "hold", asset: asset.symbol, reason: "source price stale", age_sec: age }); continue; }
        const target = pythToWad(p.price, p.expo);
        if (target === 0n) continue;
        const pool = requirePool(asset), token = requireToken(asset);
        const [base, quote, cur] = await Promise.all([
          publicClient.readContract({ address: pool, abi: poolAbi, functionName: "baseReserve" }),
          publicClient.readContract({ address: pool, abi: poolAbi, functionName: "quoteReserve" }),
          publicClient.readContract({ address: pool, abi: poolAbi, functionName: "priceWad" }),
        ]);
        const devBps = ((cur > target ? cur - target : target - cur) * 10_000n) / target;
        if (devBps < syncBps) continue;
        const plan = planSync(base, quote, target, maxMoveBps);
        if (plan.amountIn === 0n) continue;
        const tokenIn = plan.sellBase ? token : collateral;
        logLine("price-sync", { event: "sync", asset: asset.symbol, pool_usd: Number(cur) / 1e18, pyth_usd: Number(target) / 1e18, dev_bps: Number(devBps), sell: plan.sellBase ? asset.symbol : "USDC", amount_in: plan.amountIn.toString(), dry_run: dryRun });
        if (dryRun) continue;
        if (!walletClient || !account || !me) throw new Error("price-sync needs BOT_PRIVATE_KEY");
        // the deployer owns the test tokens, so it mints what it sells instead of holding inventory
        const bal = await publicClient.readContract({ address: tokenIn, abi: erc20Abi, functionName: "balanceOf", args: [me] });
        if (bal < plan.amountIn) await sendAndWait(context, await walletClient.writeContract({ address: tokenIn, abi: mintAbi, functionName: "mint", args: [me, plan.amountIn - bal], account, chain: undefined }), `${asset.symbol} mint`);
        const allowance = await publicClient.readContract({ address: tokenIn, abi: erc20Abi, functionName: "allowance", args: [me, pool] });
        if (allowance < plan.amountIn) await sendAndWait(context, await walletClient.writeContract({ address: tokenIn, abi: erc20Abi, functionName: "approve", args: [pool, 2n ** 255n], account, chain: undefined }), `${asset.symbol} approve`);
        await sendAndWait(context, await walletClient.writeContract({ address: pool, abi: poolAbi, functionName: "swapExactIn", args: [tokenIn, plan.amountIn, 0n, me], account, chain: undefined }), `${asset.symbol} sync swap`);
        const after = await publicClient.readContract({ address: pool, abi: poolAbi, functionName: "priceWad" });
        logLine("price-sync", { event: "synced", asset: asset.symbol, pool_usd: Number(after) / 1e18, pyth_usd: Number(target) / 1e18 });
      } catch (e) {
        logLine("price-sync", { event: "error", asset: asset.symbol, error: String((e as Error).message).split("\n")[0]!.slice(0, 200) });
        if (/insufficient balance|Signer had insufficient/i.test(String((e as Error).message))) { logLine("price-sync", { event: "out_of_gas" }); process.exitCode = 2; return; }
      }
    }
    if (!once) await new Promise((r) => setTimeout(r, intervalMs));
  } while (!once);
}

if (process.argv[1]?.endsWith("price-sync.ts")) main().catch((e) => { console.error(e); process.exit(1); });

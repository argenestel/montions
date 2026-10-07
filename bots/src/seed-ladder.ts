import type { Address, Hex } from "viem";
import { montionsBookAbi } from "../../sdk/src/abi/index.js";
import {
  addressAt,
  isDryRun,
  loadBotContext,
  logLine,
  sendAndWait,
  SerialTx,
  requirePool,
  withRpcRetry,
} from "./runtime.js";
import {
  CREATE_BATCH_SIZE,
  chunk,
  createSeriesCalldata,
  encodePlannedSeries,
  selectMissingSeries,
} from "./seriesOps.js";
import {
  POOL_SERIES_WINDOW_SECONDS,
  PYTH_SERIES_MAX_DELAY_SECONDS,
  planSeriesLadder,
  type LadderAsset,
} from "./seriesLadder.js";

const poolAbi = [
  { type: "function", name: "priceWad", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
] as const;

const pythOracleAbi = [
  {
    type: "function",
    name: "latestPrice",
    stateMutability: "view",
    inputs: [{ name: "assetId", type: "bytes32" }],
    outputs: [
      { name: "priceWad", type: "uint256" },
      { name: "updatedAt", type: "uint64" },
    ],
  },
] as const;

function keeperMode(): "pool" | "pyth" {
  const raw = (process.env.KEEPER_MODE ?? "pool").toLowerCase();
  if (raw !== "pool" && raw !== "pyth") throw new Error("KEEPER_MODE must be pool or pyth");
  return raw;
}

async function readSpot(
  context: ReturnType<typeof loadBotContext>,
  asset: { symbol: string; assetId: Hex; pool?: Address },
  mode: "pool" | "pyth",
): Promise<bigint> {
  if (mode === "pyth") {
    const oracle = context.deployment.contracts.pythOracle;
    if (oracle) {
      try {
        const latest = await context.publicClient.readContract({
          address: oracle,
          abi: pythOracleAbi,
          functionName: "latestPrice",
          args: [asset.assetId],
        });
        const price = latest[0];
        if (price > 0n) return price;
      } catch {
        // Fall through to the demo pool if the Pyth adapter is not ready.
      }
    }
  }
  return context.publicClient.readContract({ address: requirePool(asset), abi: poolAbi, functionName: "priceWad" });
}

async function main(): Promise<void> {
  const dryRun = isDryRun();
  const mode = keeperMode();
  const context = loadBotContext(!dryRun);
  const book = addressAt(context.deployment, "book");
  const resolverName = mode === "pyth" ? ["pythSettlementResolver", "pythResolver"] : ["twapResolver"];
  const oracleName = mode === "pyth" ? ["pythOracle"] : ["oracleHub"];
  const resolver = addressAt(context.deployment, ...resolverName);
  const oracle = addressAt(context.deployment, ...oracleName);
  const window = mode === "pyth" ? PYTH_SERIES_MAX_DELAY_SECONDS : POOL_SERIES_WINDOW_SECONDS;
  const block = await context.publicClient.getBlock();
  const now = block.timestamp;

  const assets: LadderAsset[] = [];
  for (const asset of context.deployment.assets) {
    assets.push({
      symbol: asset.symbol,
      assetId: asset.assetId,
      spotWad: await readSpot(context, asset, mode),
    });
  }

  const plan = planSeriesLadder(now, assets, { window });
  const encoded = plan.map((item) => encodePlannedSeries(item, oracle, resolver));
  const missing = await selectMissingSeries(context, book, encoded);
  logLine("seed-ladder", {
    event: "plan",
    mode,
    now: now.toString(),
    planned: plan.length,
    missing: missing.length,
    dry_run: dryRun,
  });

  if (missing.length === 0) {
    logLine("seed-ladder", { event: "done", created: 0 });
    return;
  }
  if (dryRun) {
    logLine("seed-ladder", { event: "dry_run", would_create: missing.length });
    return;
  }
  if (!context.walletClient || !context.account) throw new Error("seed-ladder needs BOT_PRIVATE_KEY or BOT_ADDRESS");

  const tx = new SerialTx();
  const batches = chunk(missing, CREATE_BATCH_SIZE);
  let created = 0;
  for (const [index, batch] of batches.entries()) {
    const calls = batch.map((item) => createSeriesCalldata(resolver, item.data, item.expiry));
    await tx.run(async () => {
      let hash: Hex | undefined;
      await withRpcRetry(
        async () => {
          if (!hash) {
            hash = await context.walletClient!.writeContract({
              address: book,
              abi: montionsBookAbi,
              functionName: "multicall",
              args: [calls],
              account: context.account!,
              chain: undefined,
            });
          }
          await sendAndWait(context, hash, "seed-ladder createSeries batch");
        },
        { label: "createSeries multicall" },
      );
    });
    created += batch.length;
    logLine("seed-ladder", { event: "batch", index: index + 1, batches: batches.length, created });
  }
  logLine("seed-ladder", { event: "done", created });
}

main().catch((error: unknown) => {
  console.error(`SEED-LADDER failed: ${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 1;
});

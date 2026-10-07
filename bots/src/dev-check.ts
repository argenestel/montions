import { quoterAbi } from "../../sdk/src/abi/index.js";
import { addressAt, loadBotContext, logLine, requirePool } from "./runtime.js";
import { encodePlannedSeries, logDuplicates, readAllSeries, SERIES_STATUS } from "./seriesOps.js";
import { planSeriesLadder, POOL_SERIES_WINDOW_SECONDS, type LadderAsset } from "./seriesLadder.js";

const poolAbi = [
  { type: "function", name: "priceWad", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
] as const;

async function main(): Promise<void> {
  const context = loadBotContext(false);
  const book = addressAt(context.deployment, "book");
  const quoter = context.deployment.contracts.quoter;
  const vault = context.deployment.contracts.vault;
  const resolver = addressAt(context.deployment, "twapResolver");
  const oracle = addressAt(context.deployment, "oracleHub");
  const block = await context.publicClient.getBlock();
  const now = block.timestamp;

  const assets: LadderAsset[] = [];
  for (const asset of context.deployment.assets) {
    const spotWad = await context.publicClient.readContract({
      address: requirePool(asset),
      abi: poolAbi,
      functionName: "priceWad",
    });
    assets.push({ symbol: asset.symbol, assetId: asset.assetId, spotWad });
  }

  const plan = planSeriesLadder(now, assets, { window: POOL_SERIES_WINDOW_SECONDS });
  const expectedIds = new Set(plan.map((item) => encodePlannedSeries(item, oracle, resolver).id.toLowerCase()));
  const expected = expectedIds.size;
  const onchain = await readAllSeries(context, book);
  const dupes = logDuplicates(onchain);
  const missing = [...expectedIds].filter((id) => !onchain.some((row) => row.id.toLowerCase() === id));

  let quoted = 0;
  if (quoter) {
    const pageSize = 50n;
    for (let offset = 0n; ; offset += pageSize) {
      const page = await context.publicClient.readContract({
        address: quoter,
        abi: quoterAbi,
        functionName: "snapshots",
        args: [offset, pageSize],
      });
      for (const snap of page) {
        if (Number(snap.info?.status) !== SERIES_STATUS.Open) continue;
        if ((snap.bidQty ?? 0n) > 0n || (snap.askQty ?? 0n) > 0n) quoted++;
      }
      if (page.length < Number(pageSize)) break;
    }
  }

  logLine("dev-check", {
    event: "result",
    series: onchain.length,
    expected,
    duplicates: dupes.length,
    missing: missing.length,
    quoted,
    vault: vault ?? "",
    assets: assets.length,
  });

  const failures: string[] = [];
  if (onchain.length !== expected) failures.push(`seriesCount ${onchain.length} != expected ${expected}`);
  if (dupes.length !== 0) failures.push(`duplicate resolver+data+expiry: ${dupes.join(",")}`);
  if (missing.length !== 0) failures.push(`missing ${missing.length} planned series`);
  if (quoted < 20) failures.push(`vault quotes on ${quoted} series (need >= 20)`);
  if (failures.length > 0) throw new Error(failures.join("; "));
  console.log(`dev-check PASS series=${onchain.length} unique=${onchain.length} quoted=${quoted} expected=${expected}`);
}

main().catch((error: unknown) => {
  console.error(`dev-check FAIL: ${error instanceof Error ? error.message : String(error)}`);
  process.exit(1);
});

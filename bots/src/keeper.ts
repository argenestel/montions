import {
  encodeAbiParameters,
  encodeFunctionData,
  keccak256,
  parseAbiParameters,
  type Address,
  type Hex,
} from "viem";
import { makerVaultAbi, montionsBookAbi } from "../../sdk/src/abi/index.js";
import { addressAt, hasFlag, isDryRun, loadBotContext, sendAndWait } from "./runtime.js";
import { planSeriesLadder } from "./seriesLadder.js";

const hubAbi = [
  {
    type: "function",
    name: "checkpoint",
    stateMutability: "nonpayable",
    inputs: [{ name: "assetId", type: "bytes32" }],
    outputs: [],
  },
] as const;
const poolAbi = [
  { type: "function", name: "priceWad", stateMutability: "view", inputs: [], outputs: [{ type: "uint256" }] },
] as const;
const seriesInfoArgs = parseAbiParameters("address, bytes32, uint256, bool, uint32");
const seriesIdArgs = parseAbiParameters("address, bytes, uint64");
const ladderWindow = 60;
const CREATE_BATCH_SIZE = 20;

interface SeriesInfoLike {
  resolver: Address;
  data: Hex;
  expiry: bigint;
  status: number;
}

function tupleField(value: unknown, index: number, key: string): unknown {
  if (Array.isArray(value)) return value[index];
  return (value as Record<string, unknown>)[key];
}

async function main(): Promise<void> {
  const dryRun = isDryRun();
  const context = loadBotContext(!dryRun);
  const { deployment, publicClient, walletClient } = context;
  const book = addressAt(deployment, "book");
  const hub = addressAt(deployment, "oracleHub");
  const resolver = addressAt(deployment, "twapResolver");
  const vault = deployment.contracts.vault;
  const intervalMs = Number(process.env.KEEPER_INTERVAL_MS ?? 15_000);
  if (!Number.isFinite(intervalMs) || intervalMs < 250) throw new Error("KEEPER_INTERVAL_MS must be at least 250ms");
  const oneShot = hasFlag("--once");

  console.log(`KEEPER ${dryRun ? "dry-run" : "live"} on chain ${deployment.chainId}`);
  do {
    for (const asset of deployment.assets) {
      if (dryRun) {
        console.log(`KEEPER checkpoint ${asset.symbol} (${asset.assetId})`);
      } else {
        const hash = await walletClient!.writeContract({
          address: hub,
          abi: hubAbi,
          functionName: "checkpoint",
          args: [asset.assetId],
          account: context.account!,
          chain: undefined,
        });
        await sendAndWait(context, hash, `${asset.symbol} oracle checkpoint`);
      }
    }

    const block = await publicClient.getBlock();
    const now = block.timestamp;
    const assets = await Promise.all(
      deployment.assets.map(async (asset) => ({
        symbol: asset.symbol,
        assetId: asset.assetId,
        spotWad: await publicClient.readContract({ address: asset.pool, abi: poolAbi, functionName: "priceWad" }),
        strikeGridWad: asset.symbol.toUpperCase() === "NVDA" ? 2_500_000_000_000_000_000n : 50_000_000_000_000_000n,
      })),
    );
    const plan = planSeriesLadder(now, assets);
    const existingIds = await readAllSeriesIds(context, book);
    const missing: { data: Hex; expiry: bigint; id: Hex }[] = [];
    for (const candidate of plan) {
      const data = encodeAbiParameters(seriesInfoArgs, [hub, candidate.assetId, candidate.strikeWad, true, ladderWindow]);
      const id = keccak256(encodeAbiParameters(seriesIdArgs, [resolver, data, candidate.expiry]));
      if (!existingIds.has(id.toLowerCase())) missing.push({ data, expiry: candidate.expiry, id });
    }

    if (missing.length !== 0) {
      console.log(`KEEPER creating ${missing.length} missing rolling series`);
      if (!dryRun) {
        for (let i = 0; i < missing.length; i += CREATE_BATCH_SIZE) {
          const batch = missing.slice(i, i + CREATE_BATCH_SIZE).map(({ data, expiry }) =>
            encodeFunctionData({ abi: montionsBookAbi, functionName: "createSeries", args: [resolver, data, expiry] }),
          );
          const hash = await walletClient!.writeContract({
            address: book,
            abi: montionsBookAbi,
            functionName: "multicall",
            args: [batch],
            account: context.account!,
            chain: undefined,
          });
          await sendAndWait(context, hash, "rolling series creation batch");
        }
      }
    }

    const allIds = await readAllSeriesIds(context, book);
    let resolved = 0;
    for (const id of allIds) {
      const raw = await publicClient.readContract({ address: book, abi: montionsBookAbi, functionName: "seriesInfo", args: [id as Hex] });
      const info: SeriesInfoLike = {
        resolver: tupleField(raw, 0, "resolver") as Address,
        data: tupleField(raw, 1, "data") as Hex,
        expiry: tupleField(raw, 2, "expiry") as bigint,
        status: Number(tupleField(raw, 3, "status")),
      };
      if (info.status !== 1 || now <= info.expiry) continue;
      if (dryRun) {
        console.log(`KEEPER resolve ${id} (expired ${info.expiry})`);
        resolved++;
      } else {
        try {
          const hash = await walletClient!.writeContract({ address: book, abi: montionsBookAbi, functionName: "resolve", args: [id as Hex], account: context.account!, chain: undefined });
          await sendAndWait(context, hash, "series resolution");
          resolved++;
          console.log(`KEEPER resolved ${id}`);
        } catch (error) {
          console.log(`KEEPER resolution pending ${id}: ${error instanceof Error ? error.message : String(error)}`);
        }
      }
    }

    if (vault) {
      let refreshed = 0;
      for (const id of allIds) {
        const raw = await publicClient.readContract({ address: book, abi: montionsBookAbi, functionName: "seriesInfo", args: [id as Hex] });
        if (Number(tupleField(raw, 3, "status")) !== 1) continue;
        if (dryRun) {
          refreshed++;
          continue;
        }
        try {
          const hash = await walletClient!.writeContract({ address: vault, abi: makerVaultAbi, functionName: "refresh", args: [id as Hex], account: context.account!, chain: undefined });
          await sendAndWait(context, hash, "vault refresh");
          refreshed++;
        } catch (error) {
          console.log(`KEEPER vault refresh skipped ${id}: ${error instanceof Error ? error.message : String(error)}`);
        }
      }
      console.log(`KEEPER refreshed ${refreshed} open vault series`);
    }
    console.log(`KEEPER checkpointed ${assets.length} assets; ${missing.length} series created; ${resolved} expired series resolved`);
    if (!oneShot) await new Promise((resolve) => setTimeout(resolve, intervalMs));
  } while (!oneShot);
}

async function readAllSeriesIds(context: ReturnType<typeof loadBotContext>, book: Address): Promise<Set<string>> {
  const count = await context.publicClient.readContract({ address: book, abi: montionsBookAbi, functionName: "seriesCount" });
  const ids = new Set<string>();
  const pageSize = 100n;
  for (let offset = 0n; offset < count; offset += pageSize) {
    const page = await context.publicClient.readContract({
      address: book,
      abi: montionsBookAbi,
      functionName: "seriesIds",
      args: [offset, pageSize],
    });
    for (const id of page) ids.add(id.toLowerCase());
  }
  return ids;
}

main().catch((error: unknown) => {
  console.error(`KEEPER failed: ${error instanceof Error ? error.message : String(error)}`);
  process.exitCode = 1;
});

import {
  decodeAbiParameters,
  encodeAbiParameters,
  encodeFunctionData,
  keccak256,
  parseAbiParameters,
  type Address,
  type Hex,
} from "viem";
import { montionsBookAbi } from "../../sdk/src/abi/index.js";
import type { BotContext } from "./runtime.js";
import { logLine, withRpcRetry } from "./runtime.js";
import type { PlannedSeries } from "./seriesLadder.js";

export const CREATE_BATCH_SIZE = 20;
export const PRICE_SERIES_DATA_PARAMS = parseAbiParameters("address oracle, bytes32 assetId, uint256 strikeWad, bool above, uint32 window");
const SERIES_ID_PARAMS = parseAbiParameters("address resolver, bytes data, uint64 expiry");

export const SERIES_STATUS = {
  None: 0,
  Open: 1,
  Resolved: 2,
  Void: 3,
} as const;

export interface EncodedSeries {
  data: Hex;
  expiry: bigint;
  id: Hex;
  symbol: string;
  assetId: Hex;
}

export interface OnchainSeries {
  id: Hex;
  resolver: Address;
  data: Hex;
  expiry: bigint;
  status: number;
  yes: boolean;
}

export interface PriceSeriesFields {
  oracle: Address;
  assetId: Hex;
  strikeWad: bigint;
  above: boolean;
  window: number;
}

export function tupleField(value: unknown, index: number, key: string): unknown {
  if (Array.isArray(value)) return value[index];
  return (value as Record<string, unknown>)[key];
}

export function encodePriceSeriesData(
  oracle: Address,
  assetId: Hex,
  strikeWad: bigint,
  above: boolean,
  window: number,
): Hex {
  return encodeAbiParameters(PRICE_SERIES_DATA_PARAMS, [oracle, assetId, strikeWad, above, window]);
}

export function computeSeriesId(resolver: Address, data: Hex, expiry: bigint): Hex {
  return keccak256(encodeAbiParameters(SERIES_ID_PARAMS, [resolver, data, expiry]));
}

export function encodePlannedSeries(
  plan: PlannedSeries,
  oracle: Address,
  resolver: Address,
): EncodedSeries {
  const data = encodePriceSeriesData(oracle, plan.assetId, plan.strikeWad, plan.above, plan.window);
  return {
    data,
    expiry: plan.expiry,
    id: computeSeriesId(resolver, data, plan.expiry),
    symbol: plan.symbol,
    assetId: plan.assetId,
  };
}

export function decodePriceSeriesData(data: Hex): PriceSeriesFields | null {
  try {
    const decoded = decodeAbiParameters(PRICE_SERIES_DATA_PARAMS, data);
    return {
      oracle: decoded[0],
      assetId: decoded[1],
      strikeWad: decoded[2],
      above: decoded[3],
      window: Number(decoded[4]),
    };
  } catch {
    return null;
  }
}

export function parseSeriesInfo(id: Hex, raw: unknown): OnchainSeries {
  return {
    id,
    resolver: tupleField(raw, 0, "resolver") as Address,
    data: tupleField(raw, 1, "data") as Hex,
    expiry: tupleField(raw, 2, "expiry") as bigint,
    status: Number(tupleField(raw, 3, "status")),
    yes: Boolean(tupleField(raw, 4, "yes")),
  };
}

export async function seriesStatus(
  context: BotContext,
  book: Address,
  id: Hex,
): Promise<number | null> {
  try {
    const raw = await withRpcRetry(
      () =>
        context.publicClient.readContract({
          address: book,
          abi: montionsBookAbi,
          functionName: "seriesInfo",
          args: [id],
        }),
      { label: "seriesInfo" },
    );
    return Number(tupleField(raw, 3, "status"));
  } catch {
    return null;
  }
}

export async function readAllSeriesIds(context: BotContext, book: Address): Promise<Hex[]> {
  const count = await withRpcRetry(
    () =>
      context.publicClient.readContract({
        address: book,
        abi: montionsBookAbi,
        functionName: "seriesCount",
      }),
    { label: "seriesCount" },
  );
  const ids: Hex[] = [];
  const pageSize = 100n;
  for (let offset = 0n; offset < count; offset += pageSize) {
    const page = await withRpcRetry(
      () =>
        context.publicClient.readContract({
          address: book,
          abi: montionsBookAbi,
          functionName: "seriesIds",
          args: [offset, pageSize],
        }),
      { label: "seriesIds" },
    );
    ids.push(...page);
  }
  return ids;
}

export async function readAllSeries(context: BotContext, book: Address): Promise<OnchainSeries[]> {
  const ids = await readAllSeriesIds(context, book);
  const out: OnchainSeries[] = [];
  for (const id of ids) {
    const raw = await withRpcRetry(
      () =>
        context.publicClient.readContract({
          address: book,
          abi: montionsBookAbi,
          functionName: "seriesInfo",
          args: [id],
        }),
      { label: "seriesInfo" },
    );
    out.push(parseSeriesInfo(id, raw));
  }
  return out;
}

export function chunk<T>(items: readonly T[], size: number): T[][] {
  if (size <= 0) throw new RangeError("chunk size must be positive");
  const batches: T[][] = [];
  for (let i = 0; i < items.length; i += size) batches.push(items.slice(i, i + size));
  return batches;
}

export async function selectMissingSeries(
  context: BotContext,
  book: Address,
  encoded: readonly EncodedSeries[],
): Promise<EncodedSeries[]> {
  const missing: EncodedSeries[] = [];
  const seen = new Set<string>();
  for (const item of encoded) {
    const key = item.id.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    const status = await seriesStatus(context, book, item.id);
    if (status === null || status === SERIES_STATUS.None) missing.push(item);
  }
  return missing;
}

export function createSeriesCalldata(resolver: Address, data: Hex, expiry: bigint): Hex {
  return encodeFunctionData({
    abi: montionsBookAbi,
    functionName: "createSeries",
    args: [resolver, data, expiry],
  });
}

export function logDuplicates(series: readonly OnchainSeries[]): string[] {
  const seen = new Map<string, Hex>();
  const dupes: string[] = [];
  for (const item of series) {
    const key = `${item.resolver.toLowerCase()}:${item.data}:${item.expiry.toString()}`;
    const prev = seen.get(key);
    if (prev) dupes.push(`${prev} == ${item.id}`);
    else seen.set(key, item.id);
  }
  return dupes;
}

export function describeMissing(missing: readonly EncodedSeries[]): void {
  logLine("ladder", { event: "missing", count: missing.length });
}

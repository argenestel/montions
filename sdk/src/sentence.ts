import { decodeAbiParameters, type Hex } from "viem";
import { MAX_TICK, MIN_TICK, TICKS, TICK_UNIT, UNIT, WAD, ceilDiv, clampTick } from "./ticks.js";

export type SentenceDirection = "above" | "below";
export type BookSide = "Bid" | "Ask";
export type TimeInForce = "GTC" | "IOC" | "POST_ONLY";

export interface DepthLevel {
  tick: number;
  qty?: bigint | number;
  quantity?: bigint | number;
}

interface NormalizedDepthLevel {
  tick: number;
  qty: bigint;
}

/** The portion of a Quoter snapshot needed by the pure planner. */
export interface PlannerSnapshot {
  seriesId?: Hex;
  expiry?: bigint;
  info?: { expiry?: bigint; data?: Hex | string; status?: number };
  bidTick?: number;
  bidQty?: bigint;
  askTick?: number;
  askQty?: bigint;
  fairTick?: number;
  probWad?: bigint;
  /** Aggregated levels, best first or in any order (the planner sorts them). */
  bids?: readonly DepthLevel[];
  asks?: readonly DepthLevel[];
  /** Alternative shape used by some RPC adapters. */
  depth?: { bids?: readonly DepthLevel[]; asks?: readonly DepthLevel[] };
  /** Optional book fee from a deployment snapshot. */
  takerFeeBps?: number;
}

export interface DecodedSeriesMetadata {
  /** Oracle asset id, generally bytes32. */
  asset: Hex;
  /** Strike in 1e18-scaled USD. */
  strikeWad: bigint;
  /** Resolver direction. Only true (above) is currently tradable by this planner. */
  above: boolean;
}

export interface SeriesCandidate {
  seriesId: Hex;
  expiry?: bigint;
  snapshot: PlannerSnapshot;
  /** Preferred explicit metadata field. */
  metadata?: DecodedSeriesMetadata;
  /** Alias accepted for decoded resolver data. */
  decoded?: DecodedSeriesMetadata;
  /** Flat decoded fields accepted from a resolver adapter. */
  asset?: Hex;
  strikeWad?: bigint;
  above?: boolean;
}

export interface SentenceInput {
  asset: Hex;
  direction: SentenceDirection;
  strike: bigint;
  expiryCandidates: readonly bigint[];
  payoffUsd: string | number;
  maxSlippageTicks: number;
  candidates?: readonly SeriesCandidate[];
  /** Alias for callers that call these series rather than candidates. */
  series?: readonly SeriesCandidate[];
  /** Alias used by discovery APIs. */
  seriesCandidates?: readonly SeriesCandidate[];
  /** Taker fee in basis points. Snapshot-level fee takes precedence. */
  feeBps?: number;
}

export interface BookOrderParams {
  seriesId: Hex;
  /** ABI enum value: Bid = 0, Ask = 1. */
  side: 0 | 1;
  tick: number;
  qty: bigint;
  fromHeld: false;
  /** ABI enum value: GTC = 0, IOC = 1, POST_ONLY = 2. */
  tif: 1;
  maxFills: number;
}

export interface SeriesOrderPlan {
  seriesId: Hex;
  expiry: bigint;
  asset: Hex;
  strikeWad: bigint;
  direction: SentenceDirection;
  side: BookSide;
  tick: number;
  /** YES or NO outcome price limit, both expressed in ticks. */
  maxTick: number;
  maxNoTick: number;
  qty: bigint;
  contracts: bigint;
  filled: bigint;
  shortfall: bigint;
  complete: boolean;
  fromHeld: false;
  tif: "IOC";
  /** Same call in the names and numeric values expected by viem. */
  order: BookOrderParams;
  params: BookOrderParams;
  premiumCost: bigint;
  fee: bigint;
  expectedCost: bigint;
  cost: bigint;
  avgTick: number;
  worstTick: number;
  modelProbabilityWad: bigint;
  modelProbWad: bigint;
  impliedProbabilityWad: bigint;
  impliedProbWad: bigint;
  targetPayoff: bigint;
  filledPayoff: bigint;
  maxLoss: bigint;
  /** Actual maximum profit on the contracts expected to fill. */
  maxProfit: bigint;
  /** Aggregated depth cannot reveal maker boundaries; this is an estimate. */
  estimated: true;
}

export interface SentencePlan {
  asset: Hex;
  direction: SentenceDirection;
  strikeWad: bigint;
  payoffUsd: string | number;
  /** Whole contracts required to meet the requested payout, rounded upward. */
  contracts: bigint;
  contractCount: bigint;
  targetPayoff: bigint;
  plans: SeriesOrderPlan[];
  /** Alias retained for callers that use “candidates” for the resulting rows. */
  candidates: SeriesOrderPlan[];
}

const MAX_UINT64 = (1n << 64n) - 1n;
const TWAP_DATA_TYPES = [
  { type: "address" },
  { type: "bytes32" },
  { type: "uint256" },
  { type: "bool" },
  { type: "uint32" },
] as const;

function asBigint(value: bigint | number | string | undefined, name: string): bigint {
  if (value === undefined) throw new TypeError(`${name} is required`);
  if (typeof value === "bigint") return value;
  if (typeof value === "number") {
    if (!Number.isSafeInteger(value)) throw new TypeError(`${name} must be an integer`);
    return BigInt(value);
  }
  if (!/^\d+$/.test(value)) throw new TypeError(`${name} must be an unsigned integer`);
  return BigInt(value);
}

function isHex(value: unknown): value is Hex {
  return typeof value === "string" && /^0x[0-9a-fA-F]*$/.test(value) && value.length % 2 === 0;
}

function isBytes32(value: unknown): value is Hex {
  return isHex(value) && value.length === 66;
}

function sameHex(a: Hex, b: Hex): boolean {
  return a.toLowerCase() === b.toLowerCase();
}

function parsePayoffUsd(value: string | number): { contracts: bigint; normalized: string } {
  let text = typeof value === "number" ? value.toString() : value.trim();
  if (typeof value === "number" && (!Number.isFinite(value) || value < 0)) {
    throw new RangeError("payoffUsd must be a finite non-negative number");
  }
  if (text.startsWith("$")) text = text.slice(1);
  text = text.replaceAll(",", "");
  // Number#toString may use exponent notation. Expand only the harmless,
  // decimal form so validation remains exact and deterministic.
  const exponent = /^([0-9]+(?:\.[0-9]+)?)[eE]([+-]?\d+)$/.exec(text);
  if (exponent) {
    const mantissa = exponent[1];
    const exponentText = exponent[2];
    if (mantissa === undefined || exponentText === undefined) throw new RangeError("invalid payoffUsd");
    const [whole = "", fraction = ""] = mantissa.split(".");
    const digits = whole + fraction;
    const decimalAt = whole.length + Number(exponentText);
    if (!Number.isSafeInteger(decimalAt)) throw new RangeError("invalid payoffUsd");
    text = decimalAt >= digits.length
      ? `${digits}${"0".repeat(decimalAt - digits.length)}`
      : decimalAt <= 0
        ? `0.${"0".repeat(-decimalAt)}${digits}`
        : `${digits.slice(0, decimalAt)}.${digits.slice(decimalAt)}`;
  }
  const match = /^(\d+)(?:\.(\d+))?$/.exec(text);
  if (!match) throw new TypeError("payoffUsd must be a decimal USD amount");
  const wholeText = match[1];
  if (wholeText === undefined) throw new TypeError("payoffUsd must be a decimal USD amount");
  const whole = BigInt(wholeText);
  const fraction = match[2] ?? "";
  if (whole === 0n && /^0*$/.test(fraction)) throw new RangeError("payoffUsd must be greater than zero");
  const contracts = whole + (/^0*$/.test(fraction) ? 0n : 1n);
  return { contracts, normalized: text };
}

function normalizeLevel(level: DepthLevel, side: string): NormalizedDepthLevel {
  if (!Number.isInteger(level.tick) || level.tick < MIN_TICK || level.tick > MAX_TICK) {
    throw new RangeError(`${side} depth contains invalid tick ${String(level.tick)}`);
  }
  const rawQuantity = level.qty ?? level.quantity;
  const qty = asBigint(rawQuantity, `${side} depth quantity`);
  if (qty < 0n) throw new RangeError(`${side} depth quantity must be non-negative`);
  return { tick: level.tick, qty };
}

function levels(snapshot: PlannerSnapshot, side: "bids" | "asks"): NormalizedDepthLevel[] {
  const supplied = snapshot[side] ?? snapshot.depth?.[side] ?? [];
  const result: NormalizedDepthLevel[] = supplied.map((level) => normalizeLevel(level, side));
  const directTick = side === "bids" ? snapshot.bidTick : snapshot.askTick;
  const directQty = side === "bids" ? snapshot.bidQty : snapshot.askQty;
  if (result.length === 0 && directTick !== undefined && directQty !== undefined && directTick !== 0) {
    result.push(normalizeLevel({ tick: directTick, qty: directQty }, side));
  }
  const byTick = new Map<number, bigint>();
  for (const level of result) byTick.set(level.tick, (byTick.get(level.tick) ?? 0n) + level.qty);
  return [...byTick.entries()]
    .map(([tick, qty]) => ({ tick, qty }))
    .filter((level) => level.qty > 0n)
    .sort((a, b) => side === "asks" ? a.tick - b.tick : b.tick - a.tick);
}

function validateFeeBps(feeBps: number): number {
  if (!Number.isInteger(feeBps) || feeBps < 0 || feeBps > 100) {
    throw new RangeError("feeBps must be an integer from 0 to 100");
  }
  return feeBps;
}

function levelFee(premium: bigint, feeBps: number): bigint {
  return feeBps === 0 ? 0n : ceilDiv(premium * BigInt(feeBps), 10_000n);
}

function snapshotProbability(snapshot: PlannerSnapshot): bigint {
  const value = snapshot.probWad ?? 0n;
  const probability = asBigint(value, "probWad");
  if (probability < 0n || probability > WAD) throw new RangeError("probWad must lie in [0, 1e18]");
  return probability;
}

function decodeMetadataValue(value: unknown): DecodedSeriesMetadata | undefined {
  if (!value || typeof value !== "object") return undefined;
  const object = value as Record<string, unknown>;
  const asset = object.asset ?? object.assetId;
  const strike = object.strikeWad ?? object.strike;
  const above = object.above;
  if (!isHex(asset) || (typeof above !== "boolean") || strike === undefined) return undefined;
  return { asset, strikeWad: asBigint(strike as bigint | number | string, "strikeWad"), above };
}

/**
 * Decode the canonical TwapThresholdResolver data tuple. This lets a client
 * pass `snapshot.info.data` directly; explicit candidate metadata still wins
 * and is recommended when a deployment uses a custom resolver.
 */
export function decodeSeriesMetadata(data: Hex | string): DecodedSeriesMetadata {
  if (!isHex(data)) throw new TypeError("resolver data must be hex");
  try {
    const decoded = decodeAbiParameters(TWAP_DATA_TYPES, data as Hex) as readonly [string, Hex, bigint, boolean, number];
    const asset = decoded[1];
    const strikeWad = decoded[2];
    const above = decoded[3];
    if (!isHex(asset) || typeof strikeWad !== "bigint" || typeof above !== "boolean") throw new TypeError("bad resolver data");
    return { asset, strikeWad, above };
  } catch (error) {
    throw new TypeError(`cannot decode TwapThresholdResolver data: ${String(error)}`);
  }
}

function candidateMetadata(candidate: SeriesCandidate): DecodedSeriesMetadata {
  const explicit = decodeMetadataValue(candidate.metadata) ?? decodeMetadataValue(candidate.decoded);
  if (explicit) return explicit;
  if (candidate.asset !== undefined && candidate.strikeWad !== undefined && candidate.above !== undefined) {
    if (!isHex(candidate.asset)) throw new TypeError("candidate asset must be hex");
    return { asset: candidate.asset, strikeWad: candidate.strikeWad, above: candidate.above };
  }
  const data = candidate.snapshot.info?.data;
  if (data !== undefined) return decodeSeriesMetadata(data);
  throw new TypeError(`candidate ${candidate.seriesId} has no decoded series metadata`);
}

function candidateExpiry(candidate: SeriesCandidate): bigint {
  const expiry = candidate.expiry ?? candidate.snapshot.expiry ?? candidate.snapshot.info?.expiry;
  const result = asBigint(expiry, "candidate expiry");
  if (result <= 0n) throw new RangeError("candidate expiry must be positive");
  return result;
}

interface WalkResult {
  filled: bigint;
  premium: bigint;
  fee: bigint;
  avgTick: number;
  worstTick: number;
}

function walkDepth(
  direction: SentenceDirection,
  asks: readonly NormalizedDepthLevel[],
  bids: readonly NormalizedDepthLevel[],
  contracts: bigint,
  maxTick: number,
  maxNoTick: number,
  feeBps: number,
): WalkResult {
  const candidates = direction === "above"
    ? asks.filter((level) => level.tick <= maxTick)
    : bids.filter((level) => 100 - level.tick <= maxNoTick);
  let remaining = contracts;
  let filled = 0n;
  let premium = 0n;
  let fee = 0n;
  let weightedTicks = 0n;
  let worstTick = 0;
  for (const level of candidates) {
    if (remaining === 0n) break;
    const quantity = remaining < level.qty ? remaining : level.qty;
    const outcomeTick = direction === "above" ? level.tick : TICKS - level.tick;
    const levelPremium = quantity * BigInt(outcomeTick) * TICK_UNIT;
    filled += quantity;
    remaining -= quantity;
    premium += levelPremium;
    // Fees use the resting maker's YES tick, including for NO writes.
    fee += levelFee(quantity * BigInt(level.tick) * TICK_UNIT, feeBps);
    weightedTicks += quantity * BigInt(outcomeTick);
    worstTick = Math.max(worstTick, outcomeTick);
  }
  return {
    filled,
    premium,
    fee,
    avgTick: filled === 0n ? 0 : Number((weightedTicks + filled / 2n) / filled),
    worstTick,
  };
}

function maxOutcomeTicks(snapshot: PlannerSnapshot, direction: SentenceDirection, maxSlippageTicks: number): { maxTick: number; maxNoTick: number } {
  const bids = levels(snapshot, "bids");
  const asks = levels(snapshot, "asks");
  const fair = snapshot.fairTick ?? 0;
  if (fair !== 0 && (!Number.isInteger(fair) || fair < MIN_TICK || fair > MAX_TICK)) {
    throw new RangeError("fairTick must be zero or an integer in [1, 99]");
  }
  const yesReference = fair || asks[0]?.tick || MAX_TICK;
  const noReference = fair ? TICKS - fair : TICKS - (bids[0]?.tick || MIN_TICK);
  const maxTick = clampTick(yesReference + maxSlippageTicks);
  const maxNoTick = clampTick(noReference + maxSlippageTicks);
  return direction === "above" ? { maxTick, maxNoTick } : { maxTick, maxNoTick };
}

function planCandidate(input: SentenceInput, candidate: SeriesCandidate, contracts: bigint, targetPayoff: bigint): SeriesOrderPlan {
  const metadata = candidateMetadata(candidate);
  const expiry = candidateExpiry(candidate);
  if (!sameHex(metadata.asset, input.asset)) throw new Error("candidate asset mismatch");
  if (metadata.strikeWad !== input.strike) throw new Error("candidate strike mismatch");
  if (!metadata.above) throw new Error("only above-series candidates are supported");

  const { maxTick, maxNoTick } = maxOutcomeTicks(candidate.snapshot, input.direction, input.maxSlippageTicks);
  const feeBps = validateFeeBps(candidate.snapshot.takerFeeBps ?? input.feeBps ?? 0);
  const asks = levels(candidate.snapshot, "asks");
  const bids = levels(candidate.snapshot, "bids");
  const walked = walkDepth(input.direction, asks, bids, contracts, maxTick, maxNoTick, feeBps);
  const orderTick = input.direction === "above" ? maxTick : TICKS - maxNoTick;
  const side: BookSide = input.direction === "above" ? "Bid" : "Ask";
  const sideCode = input.direction === "above" ? 0 : 1;
  const order: BookOrderParams = {
    seriesId: candidate.seriesId,
    side: sideCode,
    tick: orderTick,
    qty: contracts,
    fromHeld: false,
    tif: 1,
    maxFills: 0,
  };
  const filledPayoff = walked.filled * UNIT;
  const maxLoss = walked.premium + walked.fee;
  const maxProfit = filledPayoff - maxLoss;
  // Implied probability is the premium price; fees are reported separately
  // and are part of max loss/cost.
  const implied = filledPayoff === 0n ? 0n : (walked.premium * WAD) / filledPayoff;
  // Quoter uses fairTick==0/probWad==0 to signal an unsupported resolver.
  const supportedModel = candidate.snapshot.fairTick !== undefined
    && candidate.snapshot.fairTick !== 0
    && candidate.snapshot.probWad !== undefined;
  const baseModel = supportedModel ? snapshotProbability(candidate.snapshot) : 0n;
  const model = supportedModel ? (input.direction === "above" ? baseModel : WAD - baseModel) : 0n;
  return {
    seriesId: candidate.seriesId,
    expiry,
    asset: metadata.asset,
    strikeWad: metadata.strikeWad,
    direction: input.direction,
    side,
    tick: orderTick,
    maxTick,
    maxNoTick,
    qty: contracts,
    contracts,
    filled: walked.filled,
    shortfall: contracts - walked.filled,
    complete: walked.filled === contracts,
    fromHeld: false,
    tif: "IOC",
    order,
    params: order,
    premiumCost: walked.premium,
    fee: walked.fee,
    expectedCost: maxLoss,
    cost: maxLoss,
    avgTick: walked.avgTick,
    worstTick: walked.worstTick,
    modelProbabilityWad: model,
    modelProbWad: model,
    impliedProbabilityWad: implied,
    impliedProbWad: implied,
    targetPayoff,
    filledPayoff,
    maxLoss,
    maxProfit,
    estimated: true,
  };
}

/**
 * Compile the outcome-first sentence into IOC order parameters and an
 * estimated quote from aggregated depth. For `below`, the selected series is
 * still the resolver's above series; the SDK writes an Ask IOC at
 * `100 - maxNoTick`, which buys NO through the book.
 */
export function planSentence(input: SentenceInput, candidatesOverride?: readonly SeriesCandidate[]): SentencePlan {
  if (!isBytes32(input.asset)) throw new TypeError("asset must be a bytes32 hex value");
  if (input.direction !== "above" && input.direction !== "below") throw new RangeError("direction must be above or below");
  if (input.strike <= 0n) throw new RangeError("strike must be positive");
  if (!Number.isInteger(input.maxSlippageTicks) || input.maxSlippageTicks < 0 || input.maxSlippageTicks > MAX_TICK) {
    throw new RangeError("maxSlippageTicks must be an integer from 0 to 99");
  }
  const expiries = [...input.expiryCandidates];
  if (expiries.length === 0) throw new RangeError("at least one expiry candidate is required");
  const expirySet = new Set(expiries.map((expiry) => {
    if (expiry <= 0n) throw new RangeError("expiry candidates must be positive");
    return expiry.toString();
  }));
  const { contracts } = parsePayoffUsd(input.payoffUsd);
  if (contracts > MAX_UINT64) throw new RangeError("contract count exceeds uint64");
  const targetPayoff = contracts * UNIT;
  const candidates = candidatesOverride ?? input.candidates ?? input.series ?? input.seriesCandidates ?? [];
  const plans: SeriesOrderPlan[] = [];
  for (const candidate of candidates) {
    if (!isBytes32(candidate.seriesId)) throw new TypeError("candidate seriesId must be a bytes32 hex value");
    const metadata = candidateMetadata(candidate);
    const expiry = candidateExpiry(candidate);
    // Discovery can include below-series rows and unsupported statuses. They
    // are deliberately ignored: below is expressed as NO on an above series.
    if (!isBytes32(metadata.asset)) throw new TypeError("candidate asset must be a bytes32 hex value");
    if (!sameHex(metadata.asset, input.asset) || metadata.strikeWad !== input.strike || !metadata.above || !expirySet.has(expiry.toString())) continue;
    if (candidate.snapshot.info?.status !== undefined && candidate.snapshot.info.status !== 1) continue;
    plans.push(planCandidate(input, candidate, contracts, targetPayoff));
  }
  return {
    asset: input.asset,
    direction: input.direction,
    strikeWad: input.strike,
    payoffUsd: input.payoffUsd,
    contracts,
    contractCount: contracts,
    targetPayoff,
    plans,
    candidates: plans,
  };
}

export const planOutcome = planSentence;
export const sentenceToPlan = planSentence;

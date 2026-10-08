/**
 * Canonical, UTC-aligned rolling series ladder.
 *
 * Expiries are independent of "now + duration" so keeper/seed runs are idempotent
 * inside a bucket window. All math is Unix time (UTC); there is no DST.
 *
 * Buckets (next TWO upcoming expiries that satisfy Book MIN/MAX duration):
 *   15m  :00/:15/:30/:45
 *   1h   on the hour
 *   4h   00/04/08/12/16/20 UTC
 *   1d   00:00 UTC
 *   3d   00:00 UTC every third Unix epoch day (day index % 3 == 0)
 *   7d   Fridays 08:00 UTC
 *
 * Strikes: per-asset relative grid × a reference price rounded to 2 significant
 * digits, then each strike snapped to 3 significant digits. MON is 0.0005-grade
 * relative: small spot moves reuse the same strikes.
 */

export const MIN_DURATION_SECONDS = 120n;
export const MAX_DURATION_SECONDS = 90n * 24n * 60n * 60n;
export const EXPIRIES_PER_BUCKET = 2;
export const POOL_SERIES_WINDOW_SECONDS = 60;
export const PYTH_SERIES_MAX_DELAY_SECONDS = 300;

export const LADDER_BUCKETS = ["15m", "1h", "4h", "1d", "3d", "7d"] as const;
export type LadderBucketId = (typeof LADDER_BUCKETS)[number];

/** Relative moneyness vs the quantized reference, in basis points. */
export const RELATIVE_STRIKE_MULTIPLIERS_BPS = [
  8_000, 9_000, 9_500, 10_000, 10_500, 11_000, 12_000, 13_500, 15_000,
] as const;

export const STRIKES_PER_EXPIRY = RELATIVE_STRIKE_MULTIPLIERS_BPS.length;

const SECOND = 1n;
const MINUTE = 60n * SECOND;
const HOUR = 60n * MINUTE;
const DAY = 24n * HOUR;
const WEEK = 7n * DAY;

/** Unix epoch is Thursday 1970-01-01 00:00 UTC; first Friday 08:00 is 1970-01-02 08:00. */
export const UNIX_EPOCH_SECONDS = 0n;
export const THREE_DAY_PERIOD_SECONDS = 3n * DAY;
export const FIRST_FRIDAY_08_UTC_SECONDS = DAY + 8n * HOUR;

export interface AssetStrikeSpec {
  multipliersBps: readonly number[];
  referenceSignificantDigits: number;
  strikeSignificantDigits: number;
}

export const DEFAULT_STRIKE_SPEC: AssetStrikeSpec = {
  multipliersBps: RELATIVE_STRIKE_MULTIPLIERS_BPS,
  referenceSignificantDigits: 2,
  strikeSignificantDigits: 3,
};

/** Per-asset strike tables. Unknown symbols fall back to {@link DEFAULT_STRIKE_SPEC}. */
export const ASSET_STRIKE_TABLE: Readonly<Record<string, AssetStrikeSpec>> = {
  MON: DEFAULT_STRIKE_SPEC,
  NVDA: DEFAULT_STRIKE_SPEC,
};

export type AssetTier = "major" | "alt" | "wrapped";

export interface LadderAsset {
  symbol: string;
  assetId: `0x${string}`;
  spotWad: bigint;
  /** Depth profile. Untiered assets (demo pools) keep the full default ladder. */
  tier?: AssetTier;
}

/** How many markets each tier gets. Anyone can still create any other market permissionlessly for a registered asset. */
export const TIER_PROFILES: Readonly<Record<AssetTier, { buckets: readonly LadderBucketId[]; expiriesPerBucket: number; strikeMultipliersBps: readonly number[] }>> = {
  major: { buckets: ["15m", "1h", "4h", "1d", "7d"], expiriesPerBucket: 1, strikeMultipliersBps: RELATIVE_STRIKE_MULTIPLIERS_BPS },
  alt: { buckets: ["4h", "1d", "7d"], expiriesPerBucket: 1, strikeMultipliersBps: [9_000, 9_500, 10_000, 10_500, 11_000] },
  wrapped: { buckets: ["1d", "7d"], expiriesPerBucket: 1, strikeMultipliersBps: [9_000, 9_500, 10_000, 10_500, 11_000] },
};

export interface PlannedSeries {
  symbol: string;
  assetId: `0x${string}`;
  strikeWad: bigint;
  expiry: bigint;
  above: true;
  window: number;
  bucket: LadderBucketId;
}

export interface PlanOptions {
  window?: number;
  minDurationSeconds?: bigint;
  maxDurationSeconds?: bigint;
  expiriesPerBucket?: number;
}

export function strikeSpecFor(symbol: string): AssetStrikeSpec {
  return ASSET_STRIKE_TABLE[symbol.toUpperCase()] ?? DEFAULT_STRIKE_SPEC;
}

/**
 * Round a positive integer to `digits` significant digits (half-up, away from zero).
 * Used on 1e18-scaled prices so $1.04 and $1.00 share the same 2-digit reference.
 */
export function roundToSignificantDigits(value: bigint, digits: number): bigint {
  if (value <= 0n) throw new RangeError("value must be positive");
  if (!Number.isInteger(digits) || digits < 1) throw new RangeError("digits must be a positive integer");
  const text = value.toString();
  const length = text.length;
  if (length <= digits) return value;
  const factor = 10n ** BigInt(length - digits);
  return ((value + factor / 2n) / factor) * factor;
}

export function quantizeReferencePrice(spotWad: bigint, digits = 2): bigint {
  return roundToSignificantDigits(spotWad, digits);
}

export function snapStrike(strikeWad: bigint, digits = 3): bigint {
  return roundToSignificantDigits(strikeWad, digits);
}

export function canonicalStrikes(spotWad: bigint, spec: AssetStrikeSpec = DEFAULT_STRIKE_SPEC): bigint[] {
  if (spotWad <= 0n) throw new RangeError("spot must be positive");
  const reference = quantizeReferencePrice(spotWad, spec.referenceSignificantDigits);
  const strikes: bigint[] = [];
  const seen = new Set<string>();
  for (const bps of spec.multipliersBps) {
    if (!Number.isInteger(bps) || bps <= 0) throw new RangeError("strike multiplier bps must be a positive integer");
    const raw = (reference * BigInt(bps)) / 10_000n;
    if (raw <= 0n) continue;
    const strike = snapStrike(raw, spec.strikeSignificantDigits);
    const key = strike.toString();
    if (seen.has(key)) continue;
    seen.add(key);
    strikes.push(strike);
  }
  if (strikes.length === 0) throw new RangeError("strike quantiser produced no positive strikes");
  return strikes;
}

function nextStrictlyAfter(timestamp: bigint, period: bigint, offset: bigint): bigint {
  if (timestamp < 0n) throw new RangeError("timestamp must be non-negative");
  if (period <= 0n) throw new RangeError("period must be positive");
  if (offset < 0n) throw new RangeError("offset must be non-negative");
  if (timestamp < offset) return offset;
  const rem = (timestamp - offset) % period;
  if (rem === 0n) return timestamp + period;
  return timestamp + (period - rem);
}

/** First canonical expiry for `bucket` strictly after `timestampSeconds` (UTC unix). */
export function nextCanonicalExpiry(timestampSeconds: bigint, bucket: LadderBucketId): bigint {
  switch (bucket) {
    case "15m":
      return nextStrictlyAfter(timestampSeconds, 15n * MINUTE, 0n);
    case "1h":
      return nextStrictlyAfter(timestampSeconds, HOUR, 0n);
    case "4h":
      return nextStrictlyAfter(timestampSeconds, 4n * HOUR, 0n);
    case "1d":
      return nextStrictlyAfter(timestampSeconds, DAY, 0n);
    case "3d":
      return nextStrictlyAfter(timestampSeconds, THREE_DAY_PERIOD_SECONDS, UNIX_EPOCH_SECONDS);
    case "7d":
      return nextStrictlyAfter(timestampSeconds, WEEK, FIRST_FRIDAY_08_UTC_SECONDS);
    default: {
      const exhaustive: never = bucket;
      throw new RangeError(`unknown ladder bucket: ${String(exhaustive)}`);
    }
  }
}

/** Next `count` canonical expiries in `(now + minDuration, now + maxDuration]`. */
export function nextCanonicalExpiries(
  nowSeconds: bigint,
  bucket: LadderBucketId,
  count = EXPIRIES_PER_BUCKET,
  minDurationSeconds = MIN_DURATION_SECONDS,
  maxDurationSeconds = MAX_DURATION_SECONDS,
): bigint[] {
  if (nowSeconds < 0n) throw new RangeError("timestamp must be non-negative");
  if (count <= 0) return [];
  const out: bigint[] = [];
  let cursor = nowSeconds;
  for (let i = 0; i < 64 && out.length < count; i++) {
    const next = nextCanonicalExpiry(cursor, bucket);
    if (next <= cursor) throw new Error(`canonical ${bucket} expiry did not advance`);
    const dt = next - nowSeconds;
    if (dt >= minDurationSeconds && dt <= maxDurationSeconds) out.push(next);
    cursor = next;
  }
  if (out.length < count) {
    throw new RangeError(`could not find ${count} canonical ${bucket} expiries after ${nowSeconds.toString()}`);
  }
  return out;
}

export function plannedSeriesKey(item: PlannedSeries): string {
  return `${item.assetId}:${item.expiry.toString()}:${item.strikeWad.toString()}:${item.above ? "1" : "0"}:${item.window}`;
}

/**
 * Plan the open ladder: unique (asset, strike, expiry, window) series, above-only.
 * Overlapping bucket timestamps (e.g. Friday 08:00 matching 1h/4h/7d) collapse to one series.
 */
export function planSeriesLadder(
  nowSeconds: bigint,
  assets: readonly LadderAsset[],
  options: PlanOptions = {},
): PlannedSeries[] {
  const window = options.window ?? POOL_SERIES_WINDOW_SECONDS;
  const minDuration = options.minDurationSeconds ?? MIN_DURATION_SECONDS;
  const maxDuration = options.maxDurationSeconds ?? MAX_DURATION_SECONDS;
  const expiriesPerBucket = options.expiriesPerBucket ?? EXPIRIES_PER_BUCKET;
  if (!Number.isInteger(window) || window <= 0) throw new RangeError("window must be a positive integer");

  const result: PlannedSeries[] = [];
  const seen = new Set<string>();
  for (const asset of assets) {
    if (asset.spotWad <= 0n) throw new RangeError(`${asset.symbol} spot must be positive`);
    const profile = asset.tier ? TIER_PROFILES[asset.tier] : undefined;
    const spec = strikeSpecFor(asset.symbol);
    const strikes = canonicalStrikes(asset.spotWad, profile ? { ...spec, multipliersBps: profile.strikeMultipliersBps } : spec);
    for (const bucket of profile ? profile.buckets : LADDER_BUCKETS) {
      const expiries = nextCanonicalExpiries(
        nowSeconds,
        bucket,
        profile ? profile.expiriesPerBucket : expiriesPerBucket,
        minDuration,
        maxDuration,
      );
      for (const expiry of expiries) {
        for (const strikeWad of strikes) {
          const item: PlannedSeries = {
            symbol: asset.symbol,
            assetId: asset.assetId,
            strikeWad,
            expiry,
            above: true,
            window,
            bucket,
          };
          const key = plannedSeriesKey(item);
          if (seen.has(key)) continue;
          seen.add(key);
          result.push(item);
        }
      }
    }
  }
  return result;
}

export function expectedLadderSeriesCount(
  nowSeconds: bigint,
  assets: readonly LadderAsset[],
  options: PlanOptions = {},
): number {
  return planSeriesLadder(nowSeconds, assets, options).length;
}

import { describe, expect, it } from "vitest";
import {
  FIRST_FRIDAY_08_UTC_SECONDS,
  LADDER_BUCKETS,
  canonicalStrikes,
  expectedLadderSeriesCount,
  nextCanonicalExpiries,
  nextCanonicalExpiry,
  planSeriesLadder,
  plannedSeriesKey,
  quantizeReferencePrice,
  roundToSignificantDigits,
  snapStrike,
  type LadderAsset,
} from "../src/seriesLadder.js";

function unix(year: number, month: number, day: number, hour = 0, minute = 0, second = 0): bigint {
  return BigInt(Date.UTC(year, month - 1, day, hour, minute, second) / 1000);
}

const mon: LadderAsset = {
  symbol: "MON",
  assetId: `0x${"11".repeat(32)}`,
  spotWad: 1_000_000_000_000_000_000n,
};

const nvda: LadderAsset = {
  symbol: "NVDA",
  assetId: `0x${"22".repeat(32)}`,
  spotWad: 180_000_000_000_000_000_000n,
};

describe("canonical UTC expiries", () => {
  it("aligns 15m series to :00/:15/:30/:45 and skips the current slot", () => {
    expect(nextCanonicalExpiry(unix(2024, 1, 11, 12, 0, 0), "15m")).toBe(unix(2024, 1, 11, 12, 15, 0));
    expect(nextCanonicalExpiry(unix(2024, 1, 11, 12, 0, 1), "15m")).toBe(unix(2024, 1, 11, 12, 15, 0));
    expect(nextCanonicalExpiry(unix(2024, 1, 11, 12, 14, 59), "15m")).toBe(unix(2024, 1, 11, 12, 15, 0));
    expect(nextCanonicalExpiry(unix(2024, 1, 11, 12, 15, 0), "15m")).toBe(unix(2024, 1, 11, 12, 30, 0));
    expect(nextCanonicalExpiries(unix(2024, 1, 11, 12, 2, 0), "15m")).toEqual([
      unix(2024, 1, 11, 12, 15, 0),
      unix(2024, 1, 11, 12, 30, 0),
    ]);
  });

  it("skips a 15m slot that is closer than MIN_DURATION (120s)", () => {
    // 12:14:01 → 12:15 is 59s away, so the open pair is 12:30 and 12:45.
    expect(nextCanonicalExpiries(unix(2024, 1, 11, 12, 14, 1), "15m")).toEqual([
      unix(2024, 1, 11, 12, 30, 0),
      unix(2024, 1, 11, 12, 45, 0),
    ]);
  });

  it("aligns 1h to the hour and 4h to 00/04/08/12/16/20 UTC", () => {
    expect(nextCanonicalExpiry(unix(2024, 1, 11, 12, 0, 0), "1h")).toBe(unix(2024, 1, 11, 13, 0, 0));
    expect(nextCanonicalExpiries(unix(2024, 1, 11, 12, 2, 0), "1h")).toEqual([
      unix(2024, 1, 11, 13, 0, 0),
      unix(2024, 1, 11, 14, 0, 0),
    ]);
    expect(nextCanonicalExpiries(unix(2024, 1, 11, 12, 2, 0), "4h")).toEqual([
      unix(2024, 1, 11, 16, 0, 0),
      unix(2024, 1, 11, 20, 0, 0),
    ]);
    expect(nextCanonicalExpiry(unix(2024, 1, 11, 20, 0, 0), "4h")).toBe(unix(2024, 1, 12, 0, 0, 0));
  });

  it("aligns 1d to 00:00 UTC including year wrap", () => {
    expect(nextCanonicalExpiry(unix(2024, 12, 31, 23, 59, 59), "1d")).toBe(unix(2025, 1, 1, 0, 0, 0));
    // 23:59:59 is inside MIN_DURATION of midnight, so the open pair is Jan 2 and Jan 3.
    expect(nextCanonicalExpiries(unix(2024, 12, 31, 23, 59, 59), "1d")).toEqual([
      unix(2025, 1, 2, 0, 0, 0),
      unix(2025, 1, 3, 0, 0, 0),
    ]);
    expect(nextCanonicalExpiries(unix(2024, 12, 31, 12, 0, 0), "1d")).toEqual([
      unix(2025, 1, 1, 0, 0, 0),
      unix(2025, 1, 2, 0, 0, 0),
    ]);
    expect(nextCanonicalExpiry(unix(2024, 1, 1, 0, 0, 0), "1d")).toBe(unix(2024, 1, 2, 0, 0, 0));
  });

  it("counts 3d buckets from Unix epoch day 0 (1970-01-01 00:00 UTC)", () => {
    expect(nextCanonicalExpiry(0n, "3d")).toBe(3n * 86400n);
    expect(nextCanonicalExpiries(1n, "3d")).toEqual([3n * 86400n, 6n * 86400n]);
    // 2024-01-01 is epoch day 19723, 19723 % 3 == 1, so next boundaries are day 19725 and 19728.
    expect(nextCanonicalExpiries(unix(2024, 1, 1, 0, 0, 1), "3d")).toEqual([
      unix(2024, 1, 3, 0, 0, 0),
      unix(2024, 1, 6, 0, 0, 0),
    ]);
  });

  it("aligns 7d to Fridays 08:00 UTC, including the first Friday after the Unix epoch", () => {
    expect(FIRST_FRIDAY_08_UTC_SECONDS).toBe(86400n + 8n * 3600n);
    expect(nextCanonicalExpiry(0n, "7d")).toBe(FIRST_FRIDAY_08_UTC_SECONDS);
    // 2024-01-05 is a Friday.
    expect(nextCanonicalExpiry(unix(2024, 1, 5, 7, 59, 0), "7d")).toBe(unix(2024, 1, 5, 8, 0, 0));
    expect(nextCanonicalExpiry(unix(2024, 1, 5, 8, 0, 0), "7d")).toBe(unix(2024, 1, 12, 8, 0, 0));
    expect(nextCanonicalExpiries(unix(2024, 1, 3, 12, 0, 0), "7d")).toEqual([
      unix(2024, 1, 5, 8, 0, 0),
      unix(2024, 1, 12, 8, 0, 0),
    ]);
  });

  it("is DST-free: US and EU spring/fall transitions do not skip or duplicate UTC hours", () => {
    // US 2024-03-10 02:00 EST skipped locally; UTC is continuous through 06:00–08:00.
    const beforeSpring = unix(2024, 3, 10, 6, 30, 0);
    const afterSpring = unix(2024, 3, 10, 7, 30, 0);
    expect(nextCanonicalExpiry(beforeSpring, "1h")).toBe(unix(2024, 3, 10, 7, 0, 0));
    expect(nextCanonicalExpiry(afterSpring, "1h")).toBe(unix(2024, 3, 10, 8, 0, 0));
    expect(nextCanonicalExpiry(afterSpring, "1h") - nextCanonicalExpiry(beforeSpring, "1h")).toBe(3600n);

    // US 2024-11-03 fall-back repeats 01:00 local; UTC 05:30 and 06:30 are distinct hours.
    const firstOneThirty = unix(2024, 11, 3, 5, 30, 0);
    const secondOneThirty = unix(2024, 11, 3, 6, 30, 0);
    expect(nextCanonicalExpiry(firstOneThirty, "1h")).toBe(unix(2024, 11, 3, 6, 0, 0));
    expect(nextCanonicalExpiry(secondOneThirty, "1h")).toBe(unix(2024, 11, 3, 7, 0, 0));

    // EU 2024-03-31 01:00 UTC spring-forward. 15m grid stays on 900s.
    const eu = unix(2024, 3, 31, 0, 59, 0);
    expect(nextCanonicalExpiry(eu, "15m")).toBe(unix(2024, 3, 31, 1, 0, 0));
    expect(nextCanonicalExpiry(unix(2024, 3, 31, 1, 0, 0), "15m")).toBe(unix(2024, 3, 31, 1, 15, 0));
  });

  it("handles leap-day UTC midnights", () => {
    expect(nextCanonicalExpiry(unix(2024, 2, 28, 23, 59, 0), "1d")).toBe(unix(2024, 2, 29, 0, 0, 0));
    expect(nextCanonicalExpiry(unix(2024, 2, 29, 0, 0, 0), "1d")).toBe(unix(2024, 3, 1, 0, 0, 0));
  });
});

describe("strike quantiser", () => {
  it("rounds integers to N significant digits with half-up", () => {
    expect(roundToSignificantDigits(1_234n, 2)).toBe(1_200n);
    expect(roundToSignificantDigits(1_250n, 2)).toBe(1_300n);
    expect(roundToSignificantDigits(999n, 2)).toBe(1_000n);
    expect(roundToSignificantDigits(26n, 2)).toBe(26n);
  });

  it("quantises the reference to 2 sig digits so small spot moves reuse strikes", () => {
    const one = 1_000_000_000_000_000_000n;
    const oneOhFour = 1_040_000_000_000_000_000n;
    const oneOhFive = 1_050_000_000_000_000_000n;
    expect(quantizeReferencePrice(one)).toBe(one);
    expect(quantizeReferencePrice(oneOhFour)).toBe(one);
    expect(quantizeReferencePrice(oneOhFive)).toBe(1_100_000_000_000_000_000n);
    expect(canonicalStrikes(one)).toEqual(canonicalStrikes(oneOhFour));
    expect(canonicalStrikes(one)).not.toEqual(canonicalStrikes(oneOhFive));
  });

  it("snaps strikes to 3 sig digits on the relative MON 0.0005-grade grid", () => {
    const one = 1_000_000_000_000_000_000n;
    expect(canonicalStrikes(one)).toEqual([
      800_000_000_000_000_000n,
      900_000_000_000_000_000n,
      950_000_000_000_000_000n,
      1_000_000_000_000_000_000n,
      1_050_000_000_000_000_000n,
      1_100_000_000_000_000_000n,
      1_200_000_000_000_000_000n,
      1_350_000_000_000_000_000n,
      1_500_000_000_000_000_000n,
    ]);
    // Real-world MON ~ $0.0259675 → reference $0.026, 3-sig strikes.
    const pythMon = 25_967_500_000_000_000n;
    expect(quantizeReferencePrice(pythMon)).toBe(26_000_000_000_000_000n);
    const strikes = canonicalStrikes(pythMon);
    expect(strikes).toHaveLength(9);
    expect(strikes[0]).toBe(snapStrike((26_000_000_000_000_000n * 8_000n) / 10_000n));
    expect(strikes[3]).toBe(26_000_000_000_000_000n);
  });

  it("quantises NVDA ~$180 without creating a new grid on a $1 move", () => {
    const a = 180_000_000_000_000_000_000n;
    const b = 181_000_000_000_000_000_000n;
    expect(quantizeReferencePrice(a)).toBe(a);
    expect(quantizeReferencePrice(b)).toBe(a);
    expect(canonicalStrikes(a)).toEqual(canonicalStrikes(b));
    expect(canonicalStrikes(a)[3]).toBe(a);
  });
});

describe("idempotent ladder planning", () => {
  it("returns the same unique series when planned 10 minutes apart inside a stable window", () => {
    const t0 = unix(2024, 6, 15, 12, 2, 0);
    const t1 = t0 + 600n;
    const a = planSeriesLadder(t0, [mon, nvda]);
    const b = planSeriesLadder(t1, [mon, nvda]);
    expect(a.map(plannedSeriesKey)).toEqual(b.map(plannedSeriesKey));
    expect(new Set(a.map((item) => item.expiry)).size).toBeGreaterThanOrEqual(10);
    expect(a.every((item) => item.above && item.window === 60)).toBe(true);
  });

  it("does not invent a new near-dated expiry the way now+15m rounding did", () => {
    const t0 = unix(2024, 6, 15, 12, 2, 0);
    const t1 = t0 + 600n;
    const old = (now: bigint) => ((now + 15n * 60n + 299n) / 300n) * 300n;
    expect(old(t0)).not.toBe(old(t1));
    const canonical = planSeriesLadder(t0, [mon]).filter((item) => item.bucket === "15m").map((item) => item.expiry);
    const later = planSeriesLadder(t1, [mon]).filter((item) => item.bucket === "15m").map((item) => item.expiry);
    expect(canonical).toEqual(later);
  });

  it("keeps two upcoming expiries per bucket and collapses overlapping timestamps", () => {
    // Wednesday 1970-01-07 12:02 UTC: next 1d/3d/7d/4h/1h/15m slots are all distinct.
    const midday = unix(1970, 1, 7, 12, 2, 0);
    const plan = planSeriesLadder(midday, [mon]);
    expect(plan.length).toBe(expectedLadderSeriesCount(midday, [mon]));
    expect(plan.length).toBe(LADDER_BUCKETS.length * 2 * 9);
    expect(new Set(plan.map((item) => item.expiry)).size).toBe(LADDER_BUCKETS.length * 2);

    // Friday 07:50: 15m/1h/4h/7d all want 08:00 — unique count drops.
    const fridayMorning = unix(2024, 1, 5, 7, 50, 0);
    const overlapping = planSeriesLadder(fridayMorning, [mon]);
    expect(overlapping.length).toBeLessThan(LADDER_BUCKETS.length * 2 * 9);
    const keys = overlapping.map(plannedSeriesKey);
    expect(new Set(keys).size).toBe(keys.length);
  });

  it("plans both assets independently at a non-overlapping time", () => {
    const now = unix(1970, 1, 7, 12, 2, 0);
    expect(planSeriesLadder(now, [mon, nvda])).toHaveLength(2 * 6 * 2 * 9);
  });
});

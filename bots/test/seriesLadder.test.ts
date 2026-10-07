import { describe, expect, it } from "vitest";
import { planSeriesLadder, roundExpiryUp, roundToGrid } from "../src/seriesLadder.js";

const mon = {
  symbol: "MON",
  assetId: `0x${"11".repeat(32)}` as const,
  spotWad: 1_000_000_000_000_000_000n,
  strikeGridWad: 50_000_000_000_000_000n,
};

describe("series ladder planner", () => {
  it("rounds expiries upward to the next five-minute boundary", () => {
    expect(roundExpiryUp(901n)).toBe(1_200n);
    expect(roundExpiryUp(900n)).toBe(900n);
  });

  it("rounds strikes to the nearest configured grid", () => {
    expect(roundToGrid(1_024n, 100n)).toBe(1_000n);
    expect(roundToGrid(1_076n, 100n)).toBe(1_100n);
  });

  it("plans six expiries and nine above-only strikes per asset", () => {
    const plan = planSeriesLadder(1_000n, [mon]);
    expect(plan).toHaveLength(54);
    expect(new Set(plan.map((item) => item.expiry)).size).toBe(6);
    expect(plan.every((item) => item.above && item.window === 60)).toBe(true);
    expect(plan.every((item) => item.strikeWad % mon.strikeGridWad === 0n)).toBe(true);
    expect(plan[0]?.expiry).toBe(2_100n);
  });

  it("plans both assets independently", () => {
    const nvda = { ...mon, symbol: "NVDA", assetId: `0x${"22".repeat(32)}` as const, strikeGridWad: 2_500_000_000_000_000_000n };
    expect(planSeriesLadder(10_000n, [mon, nvda])).toHaveLength(108);
  });
});

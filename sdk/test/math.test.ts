import { describe, expect, it } from "vitest";
import { encodeAbiParameters } from "viem";
import { formatUsdc, parseUsdc, priceToTick, tickToUsdc } from "../src/ticks.js";
import { pnlAtExpiry, steppedPayoffCurve, settlePortfolio } from "../src/payoff.js";
import { decodeSeriesMetadata, planSentence, type SeriesCandidate } from "../src/sentence.js";

const ASSET = "0xaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" as `0x${string}`;
const SERIES = "0xbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" as `0x${string}`;
const STRIKE = 1_500_000_000_000_000_000n;
const EXPIRY = 1_800_000_000n;

const candidate: SeriesCandidate = {
  seriesId: SERIES,
  expiry: EXPIRY,
  metadata: { asset: ASSET, strikeWad: STRIKE, above: true },
  snapshot: {
    fairTick: 40,
    probWad: 400_000_000_000_000_000n,
    takerFeeBps: 100,
    asks: [
      { tick: 41, qty: 2n },
      { tick: 43, qty: 4n },
    ],
    bids: [
      { tick: 59, qty: 2n },
      { tick: 57, qty: 4n },
    ],
  },
};

describe("ticks", () => {
  it("uses bigint USDC arithmetic and formats without floating point", () => {
    expect(tickToUsdc(35, 3n)).toBe(1_050_000n);
    expect(parseUsdc("1.05")).toBe(1_050_000n);
    expect(priceToTick("0.35")).toBe(35);
    expect(formatUsdc(1_234_567n)).toBe("$1.23");
    expect(formatUsdc(1_234_567n, { decimals: 6 })).toBe("$1.234567");
  });
});

describe("payoff", () => {
  it("settles YES/NO P&L with >= threshold semantics", () => {
    const yes = { side: "YES" as const, quantity: 3n, entryTick: 35 };
    expect(pnlAtExpiry(yes, true)).toBe(1_950_000n);
    expect(pnlAtExpiry(yes, false)).toBe(-1_050_000n);
    expect(pnlAtExpiry({ side: "NO", quantity: 3n, entryTick: 65 }, false)).toBe(1_050_000n);

    const points = steppedPayoffCurve({ ...yes, strikeWad: STRIKE });
    const atStrike = points.find((point) => point.x === STRIKE);
    expect(atStrike?.yes).toBe(true);
    expect(atStrike?.payout).toBe(3_000_000n);
  });
});

describe("sentence planner", () => {
  it("buys YES with Bid IOC and handles a partial fill plus fee", () => {
    const result = planSentence({
      asset: ASSET,
      direction: "above",
      strike: STRIKE,
      expiryCandidates: [EXPIRY],
      payoffUsd: "7",
      maxSlippageTicks: 4,
      candidates: [candidate],
    });
    expect(result.contracts).toBe(7n);
    const plan = result.plans[0];
    expect(plan?.side).toBe("Bid");
    expect(plan?.order.side).toBe(0);
    expect(plan?.order.tif).toBe(1);
    expect(plan?.tick).toBe(44);
    expect(plan?.filled).toBe(6n);
    expect(plan?.fee).toBe(25_400n);
    expect(plan?.expectedCost).toBe(2_565_400n);
  });

  it("writes an Ask IOC to acquire NO and charges fee on maker YES ticks", () => {
    const result = planSentence({
      asset: ASSET,
      direction: "below",
      strike: STRIKE,
      expiryCandidates: [EXPIRY],
      payoffUsd: 3,
      maxSlippageTicks: 1,
      candidates: [candidate],
    });
    const plan = result.plans[0];
    expect(plan?.side).toBe("Ask");
    expect(plan?.maxNoTick).toBe(61);
    expect(plan?.tick).toBe(39);
    expect(plan?.filled).toBe(3n);
    // NO prices are 41 and 43 ticks; fees use maker YES ticks 59 and 57.
    expect(plan?.premiumCost).toBe(1_250_000n);
    expect(plan?.fee).toBe(17_500n);
    expect(plan?.impliedProbabilityWad).toBe(416_666_666_666_666_666n);
  });

  it("filters mismatched and below-series discovery rows", () => {
    const result = planSentence({
      asset: ASSET,
      direction: "above",
      strike: STRIKE,
      expiryCandidates: [EXPIRY],
      payoffUsd: 1,
      maxSlippageTicks: 0,
      candidates: [
        { ...candidate, metadata: { ...candidate.metadata!, above: false } },
        { ...candidate, seriesId: "0xcccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" as `0x${string}`, metadata: { ...candidate.metadata!, asset: "0xdddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd" as `0x${string}` } },
      ],
    });
    expect(result.plans).toHaveLength(0);
  });

  it("decodes canonical resolver data and leaves unsupported model probability at zero", () => {
    const data = encodeAbiParameters(
      [{ type: "address" }, { type: "bytes32" }, { type: "uint256" }, { type: "bool" }, { type: "uint32" }],
      ["0x1111111111111111111111111111111111111111", ASSET, STRIKE, true, 60],
    );
    expect(decodeSeriesMetadata(data)).toEqual({ asset: ASSET, strikeWad: STRIKE, above: true });
    const result = planSentence({
      asset: ASSET,
      direction: "below",
      strike: STRIKE,
      expiryCandidates: [EXPIRY],
      payoffUsd: 0.0000001,
      maxSlippageTicks: 0,
    }, [{
      seriesId: SERIES,
      expiry: EXPIRY,
      snapshot: { info: { data, status: 1 }, bids: [], asks: [], fairTick: 0, probWad: 0n },
    }]);
    expect(result.contracts).toBe(1n);
    expect(result.plans[0]?.modelProbabilityWad).toBe(0n);
    expect(result.plans[0]?.filled).toBe(0n);
  });

  it("sorts depth, charges per aggregate level, and validates malformed depth", () => {
    const sorted = planSentence({
      asset: ASSET,
      direction: "above",
      strike: STRIKE,
      expiryCandidates: [EXPIRY],
      payoffUsd: 2,
      maxSlippageTicks: 2,
      candidates: [{
        ...candidate,
        snapshot: {
          fairTick: 38,
          probWad: 350_000_000_000_000_000n,
          asks: [{ tick: 40, quantity: 1n }, { tick: 38, qty: 1n }],
        },
      }],
    });
    expect(sorted.plans[0]?.avgTick).toBe(39);
    expect(sorted.plans[0]?.premiumCost).toBe(780_000n);
    expect(() => planSentence({
      asset: ASSET,
      direction: "above",
      strike: STRIKE,
      expiryCandidates: [EXPIRY],
      payoffUsd: 1,
      maxSlippageTicks: 0,
      candidates: [{
        ...candidate,
        snapshot: { ...candidate.snapshot, asks: [{ tick: 0, qty: 1n }] },
      }],
    })).toThrow(/invalid tick/);
  });
});


describe("planner boundaries", () => {
  const input = { asset: ASSET, direction: "above" as const, strike: STRIKE,
    expiryCandidates: [EXPIRY], payoffUsd: "1.0000001", maxSlippageTicks: 0 };

  it("ceilings fractional payout goals and rejects uint64 overflow", () => {
    expect(planSentence(input, [candidate]).contracts).toBe(2n);
    expect(planSentence({ ...input, payoffUsd: 1e-7 }).contracts).toBe(1n);
    expect(() => planSentence({ ...input, payoffUsd: "18446744073709551616" })).toThrow(/uint64/);
    expect(() => planSentence({ ...input, payoffUsd: 0 })).toThrow(/greater than zero/);
  });

  it("reports no fill and no profit when the price cap cannot cross", () => {
    const plan = planSentence(input, [candidate]).plans[0]!;
    expect(plan.filled).toBe(0n);
    expect(plan.shortfall).toBe(2n);
    expect(plan.complete).toBe(false);
    expect(plan.expectedCost).toBe(0n);
    expect(plan.maxProfit).toBe(0n);
  });

  it("ignores settled rows and bounds slippage and ticks", () => {
    expect(planSentence(input, [{ ...candidate, snapshot: { ...candidate.snapshot, info: { status: 2 } } }]).plans).toEqual([]);
    expect(() => planSentence({ ...input, maxSlippageTicks: -1 })).toThrow(/maxSlippageTicks/);
    expect(() => tickToUsdc(0)).toThrow(/tick/);
    expect(() => tickToUsdc(100)).toThrow(/tick/);
    expect(priceToTick("0.351", "up")).toBe(36);
    expect(priceToTick("0.359", "down")).toBe(35);
  });

  it("makes NO lose at equality and preserves portfolio outcome sides", () => {
    const points = steppedPayoffCurve({ side: "NO", quantity: 1n, cost: 200_000n, strikeWad: STRIKE });
    expect(points.find(point => point.x === STRIKE - 1n)?.pnl).toBe(800_000n);
    expect(points.find(point => point.x === STRIKE)?.pnl).toBe(-200_000n);
    const settled = settlePortfolio({ no: { side: "YES", quantity: 1n } }, true);
    expect(settled.no.payout).toBe(0n);
    expect(settled.no.side).toBe("NO");
  });
});

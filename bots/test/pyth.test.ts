import { describe, expect, it, vi } from "vitest";
import type { Hex } from "viem";
import {
  hermesPriceUpdateUrl,
  parseHermesUpdate,
  revertName,
  retryDelayMs,
  settlePythWindow,
  settlementPublishTimes,
  type PythSettleDeps,
} from "../src/pyth.js";

const assetId = `0x${"ab".repeat(32)}` as Hex;
const feedId = `0x${"cd".repeat(32)}` as Hex;
const update = "0x504e415501" as Hex;

function deps(overrides: Partial<PythSettleDeps> & Pick<PythSettleDeps, "settle" | "fetchUpdateData" | "isSettled">): PythSettleDeps {
  return {
    getUpdateFee: async () => 7n,
    sleep: async () => undefined,
    ...overrides,
  };
}

describe("Hermes payload parsing", () => {
  it("accepts hex with or without 0x from binary.data", () => {
    expect(
      parseHermesUpdate({
        binary: { encoding: "hex", data: ["504e4155", "0xabcd"] },
      }),
    ).toEqual(["0x504e4155", "0xabcd"]);
  });

  it("rejects empty or non-hex payloads", () => {
    expect(() => parseHermesUpdate({})).toThrow(/binary.data/);
    expect(() => parseHermesUpdate({ binary: { data: ["zz"] } })).toThrow(/hex/);
  });

  it("builds the documented /v2/updates/price/{t} URL", () => {
    expect(hermesPriceUpdateUrl("https://hermes.pyth.network/", 1_700_000_000, feedId)).toBe(
      `https://hermes.pyth.network/v2/updates/price/1700000000?ids[]=${encodeURIComponent(feedId)}&encoding=hex&parsed=true`,
    );
  });
});

describe("settlement publish-time schedule", () => {
  it("starts at expiry, is dense near zero, jumps exponentially, and includes +300", () => {
    const times = settlementPublishTimes(1_000, 300, 16);
    expect(times[0]).toBe(1_000);
    expect(times).toContain(1_001);
    expect(times).toContain(1_008);
    expect(times).toContain(1_300);
    expect(times[times.length - 1]).toBe(1_300);
    expect(times).toHaveLength(times.length);
    expect(new Set(times).size).toBe(times.length);
    expect(times.length).toBeLessThanOrEqual(16);
  });

  it("caps retry delay at 5s", () => {
    expect(retryDelayMs(0)).toBe(0);
    expect(retryDelayMs(1)).toBe(200);
    expect(retryDelayMs(2)).toBe(400);
    expect(retryDelayMs(20)).toBe(5_000);
  });
});

describe("settlePythWindow (offline fakes)", () => {
  it("returns too_early before expiry and already when isSettled is true", async () => {
    const settle = vi.fn();
    const early = await settlePythWindow({
      assetId,
      expiry: 50n,
      feedId,
      nowSeconds: 50n,
      deps: deps({
        fetchUpdateData: async () => [update],
        isSettled: async () => false,
        settle,
      }),
    });
    expect(early.status).toBe("too_early");
    expect(settle).not.toHaveBeenCalled();

    const already = await settlePythWindow({
      assetId,
      expiry: 50n,
      feedId,
      nowSeconds: 51n,
      deps: deps({
        fetchUpdateData: async () => [update],
        isSettled: async () => true,
        settle,
      }),
    });
    expect(already.status).toBe("already");
    expect(settle).not.toHaveBeenCalled();
  });

  it("retries PriceFeedNotFoundWithinRange across publish times with backoff, then settles", async () => {
    const sleeps: number[] = [];
    const tried: number[] = [];
    const settle = vi.fn(async (_a: Hex, _e: bigint, _d: Hex[], value: bigint) => {
      if (tried.length < 3) {
        throw new Error("PriceFeedNotFoundWithinRange()");
      }
      expect(value).toBe(7n);
    });
    const result = await settlePythWindow({
      assetId,
      expiry: 1_000n,
      feedId,
      nowSeconds: 1_010n,
      deps: deps({
        fetchUpdateData: async (_feed, unixTime) => {
          tried.push(unixTime);
          return [update];
        },
        isSettled: async () => false,
        settle,
        sleep: async (ms) => {
          sleeps.push(ms);
        },
      }),
    });
    expect(result.status).toBe("settled");
    expect(tried.length).toBeGreaterThanOrEqual(3);
    expect(tried[0]).toBe(1_000);
    expect(tried[1]).toBe(1_001);
    expect(sleeps[0]).toBe(200);
    expect(sleeps[1]).toBe(400);
    expect(settle).toHaveBeenCalled();
  });

  it("stops on AlreadySettled and reports not_found after the hard cap", async () => {
    const already = await settlePythWindow({
      assetId,
      expiry: 5n,
      feedId,
      nowSeconds: 10n,
      deps: deps({
        fetchUpdateData: async () => [update],
        isSettled: async () => false,
        settle: async () => {
          throw Object.assign(new Error("revert"), { shortMessage: "AlreadySettled" });
        },
      }),
    });
    expect(already.status).toBe("already");

    const missing = await settlePythWindow({
      assetId,
      expiry: 5n,
      feedId,
      nowSeconds: 10n,
      maxAttempts: 4,
      deps: deps({
        fetchUpdateData: async () => [update],
        isSettled: async () => false,
        settle: async () => {
          throw new Error("PriceFeedNotFoundWithinRange");
        },
      }),
    });
    expect(missing.status).toBe("not_found");
    expect(missing.attempts).toBe(4);
  });

  it("does not swallow unexpected errors", async () => {
    await expect(
      settlePythWindow({
        assetId,
        expiry: 1n,
        feedId,
        nowSeconds: 2n,
        deps: deps({
          fetchUpdateData: async () => [update],
          isSettled: async () => false,
          settle: async () => {
            throw new Error("out of gas");
          },
        }),
      }),
    ).rejects.toThrow(/out of gas/);
  });
});

describe("revertName", () => {
  it("walks nested viem-like errors", () => {
    expect(revertName({ shortMessage: "PriceFeedNotFoundWithinRange()" })).toBe("PriceFeedNotFoundWithinRange");
    expect(revertName(new Error("AlreadySettled(bytes32,uint64)"))).toBe("AlreadySettled");
    expect(revertName("nope")).toBeUndefined();
  });
});

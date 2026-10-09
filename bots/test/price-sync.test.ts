import { describe, expect, it } from "vitest";
import { isqrt, planSync, pythToWad } from "../src/price-sync.js";

const WAD = 10n ** 18n;
const priceOf = (base: bigint, quote: bigint) => (quote * 10n ** 30n) / base;
const swap = (base: bigint, quote: bigint, sellBase: boolean, amountIn: bigint) => {
  const inEff = (amountIn * 997n) / 1000n;
  if (sellBase) { const out = (quote * inEff) / (base + inEff); return { base: base + amountIn, quote: quote - out }; }
  const out = (base * inEff) / (quote + inEff); return { base: base - out, quote: quote + amountIn };
};

describe("price sync math", () => {
  it("isqrt is exact", () => {
    for (const n of [0n, 1n, 2n, 15n, 16n, 10n ** 40n, 10n ** 40n + 12345n]) { const r = isqrt(n); expect(r * r <= n && (r + 1n) * (r + 1n) > n).toBe(true); }
  });
  it("converts Pyth prices", () => {
    expect(pythToWad(8_205_086_743_668n, -8)).toBe(82_050_867_436_680_000_000_000n);
    expect(pythToWad(2_441_000n, -8)).toBe(24_410_000_000_000_000n);
  });
  it("moves a pool onto a higher and a lower target within 0.1%", () => {
    const base = 2_000_000n * WAD, quote = 2_000_000n * 10n ** 6n;           // $1.00 pool
    for (const target of [24_400_000_000_000_000n, 3n * WAD]) {             // MON at $0.0244, and $3
      let b = base, q = quote;
      for (let step = 0; step < 12 && (((priceOf(b, q) > target ? priceOf(b, q) - target : target - priceOf(b, q)) * 10_000n) / target) >= 10n; step++) {
        const p = planSync(b, q, target, 2_500n); ({ base: b, quote: q } = swap(b, q, p.sellBase, p.amountIn));
      }
      const dev = ((priceOf(b, q) > target ? priceOf(b, q) - target : target - priceOf(b, q)) * 10_000n) / target;
      expect(dev).toBeLessThan(10n);
    }
  });
  it("caps one step at maxMoveBps of the input reserve", () => {
    const p = planSync(1_000n * WAD, 1_000n * 10n ** 6n, 100n * WAD, 2_500n);
    expect(p.sellBase).toBe(false);
    expect(p.amountIn).toBe(250n * 10n ** 6n);
  });
});

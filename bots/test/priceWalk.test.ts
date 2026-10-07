import { describe, expect, it } from "vitest";
import { meanRevertingLogStep, standardNormal } from "../src/priceWalk.js";

describe("meanRevertingLogStep", () => {
  it("reverts a displaced log price toward its anchor without a shock", () => {
    const next = meanRevertingLogStep(Math.log(2), Math.log(1), 0.5, 10, 0);
    expect(next).toBeLessThan(Math.log(2));
    expect(next).toBeGreaterThan(Math.log(1));
  });

  it("adds annualized diffusion with the expected sign", () => {
    const start = Math.log(1.25);
    const up = meanRevertingLogStep(start, start, 0.6, 3600, 1);
    const down = meanRevertingLogStep(start, start, 0.6, 3600, -1);
    expect(up).toBeGreaterThan(start);
    expect(down).toBeLessThan(start);
    expect(up - start).toBeCloseTo(start - down, 12);
  });

  it("rejects invalid inputs and samples finite standard normals", () => {
    expect(() => meanRevertingLogStep(0, 0, -1, 1, 0)).toThrow(RangeError);
    expect(standardNormal(() => 0.75)).toBeCloseTo(0, 12);
  });
});

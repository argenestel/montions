import { describe, expect, it } from "vitest";
import { parseDeployment } from "../src/deployments.js";

const A = "0x2880aB155794e7179c9eE2e38200202908C17B43";
const ID = "0x" + "11".repeat(32);
const base = { chainId: 143, rpc: "https://rpc.monad.xyz", contracts: { book: A, quoter: A }, startBlock: 1 };

describe("deployment manifest v2", () => {
  it("accepts a Pyth-priced asset without pool/token", () => {
    const d = parseDeployment({ ...base, network: "mainnet", rpcs: ["https://rpc1.monad.xyz", "ftp://bad"], explorer: "https://monadvision.com/", assets: [{ symbol: "MON", assetId: ID, decimals: 18, oracle: "pyth", feedId: ID }] });
    expect(d.assets[0].oracle).toBe("pyth");
    expect(d.assets[0].pool).toBeUndefined();
    expect(d.rpcs).toEqual(["https://rpc1.monad.xyz"]);   // non-http(s) endpoints are dropped
    expect(d.explorer).toBe("https://monadvision.com");   // trailing slash stripped
    expect(d.network).toBe("mainnet");
  });
  it("infers oracle kind: pool when a pool is present", () => {
    const d = parseDeployment({ ...base, chainId: 31337, assets: [{ symbol: "MON", assetId: ID, decimals: 18, pool: A, token: A }] });
    expect(d.assets[0].oracle).toBe("pool");
  });
  it("rejects a pool asset without pool/token and a Pyth asset without feedId", () => {
    expect(() => parseDeployment({ ...base, assets: [{ symbol: "X", assetId: ID, decimals: 18, oracle: "pool" }] })).toThrow(/pool and token/);
    expect(() => parseDeployment({ ...base, assets: [{ symbol: "X", assetId: ID, decimals: 18, oracle: "pyth" }] })).toThrow(/feedId/);
  });
  it("ignores an unknown network tier instead of trusting it", () => {
    const d = parseDeployment({ ...base, network: "prod", assets: [] });
    expect(d.network).toBeUndefined();
  });
});

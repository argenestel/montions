// Combine the files written by script/DeployProd.s.sol into the single deployment.json the app/SDK read.
// Usage: CHAIN_ID=143 node scripts/finish-manifest.mjs [out-path]
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { dirname, resolve } from "node:path";
const chainId = process.env.CHAIN_ID ?? "143";
const dir = resolve("deployments");
const contracts = JSON.parse(readFileSync(`${dir}/${chainId}.contracts.json`, "utf8"));
const meta = JSON.parse(readFileSync(`${dir}/${chainId}.meta.json`, "utf8"));
const cfg = JSON.parse(readFileSync("config/pyth-feeds.json", "utf8"));
const keccak = async (s) => execFileSync("cast", ["keccak", s], { encoding: "utf8" }).trim(); // no npm deps needed
const assets = [];
for (const f of cfg.feeds.filter((x) => x.enabled)) assets.push({ symbol: f.symbol, name: f.symbol, assetId: await keccak(f.symbol), decimals: 18, oracle: "pyth", feedId: f.feedId, mock: false, tier: f.tier });
const rpcs = (process.env.RPCS ?? "").split(",").map((s) => s.trim()).filter(Boolean);
const manifest = {
  chainId: Number(meta.chainId), network: meta.network, rpc: meta.rpc, ...(rpcs.length ? { rpcs } : {}), explorer: meta.explorer,
  contracts: Object.fromEntries(Object.entries(contracts).filter(([, v]) => typeof v === "string" && v.startsWith("0x"))),
  assets, startBlock: Number(meta.startBlock), ownerSafe: meta.ownerSafe,
};
const out = resolve(process.argv[2] ?? `${dir}/${chainId}.json`);
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, JSON.stringify(manifest, null, 2) + "\n");
console.log(`manifest written: ${out}`);

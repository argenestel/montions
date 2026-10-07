// Combine the files written by script/DeployProd.s.sol into the single deployment.json the app/SDK read.
// Usage: CHAIN_ID=143 node scripts/finish-manifest.mjs [out-path]
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { execFileSync } from "node:child_process";
import { dirname, resolve } from "node:path";
const chainId = process.env.CHAIN_ID ?? "143";
const dir = resolve("deployments");
const contracts = JSON.parse(readFileSync(`${dir}/${chainId}.contracts.json`, "utf8"));
const meta = JSON.parse(readFileSync(`${dir}/${chainId}.meta.json`, "utf8"));
const FEEDS = {
  MON: { id: "0x31491744e2dbf6df7fcf4ac0820d18a609b49076d45066d3568424e62f686cd1", name: "Monad" },
  BTC: { id: "0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43", name: "Bitcoin" },
  ETH: { id: "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace", name: "Ether" },
};
const keccak = async (s) => execFileSync("cast", ["keccak", s], { encoding: "utf8" }).trim(); // no npm deps needed
const assets = [];
for (const [symbol, f] of Object.entries(FEEDS)) assets.push({ symbol, name: f.name, assetId: await keccak(symbol), decimals: 18, oracle: "pyth", feedId: f.id, mock: false });
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

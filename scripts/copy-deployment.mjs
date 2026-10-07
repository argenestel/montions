import { copyFileSync, existsSync, mkdirSync } from "node:fs";
import { dirname, resolve } from "node:path";

const output = process.env.UI_DEPLOYMENT_OUT;
if (!output) process.exit(0);
const chainId = process.env.CHAIN_ID ?? "31337";
const source = resolve(process.env.DEPLOYMENT ?? `deployments/${chainId}.json`);
if (!existsSync(source)) throw new Error(`Deployment manifest not found: ${source}`);
const destination = resolve(output);
mkdirSync(dirname(destination), { recursive: true });
copyFileSync(source, destination);
console.log(`UI deployment manifest copied to ${destination}`);

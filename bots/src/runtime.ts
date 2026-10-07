import { existsSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, createWalletClient, defineChain, getAddress, http, isAddress, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { parseDeployment, type Deployment } from "../../sdk/src/deployments.js";

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");

export interface BotContext {
  deployment: Deployment;
  rpcUrl: string;
  publicClient: ReturnType<typeof createPublicClient>;
  walletClient?: ReturnType<typeof createWalletClient>;
  account?: ReturnType<typeof privateKeyToAccount> | Address;
}

export function deploymentPath(): string {
  const configured = process.env.DEPLOYMENT;
  if (!configured) return resolve(REPO_ROOT, "deployments/31337.json");
  if (configured.startsWith("/")) return configured;
  const fromCwd = resolve(process.cwd(), configured);
  return existsSync(fromCwd) ? fromCwd : resolve(REPO_ROOT, configured);
}

export function readDeployment(): Deployment {
  const path = deploymentPath();
  return parseDeployment(JSON.parse(readFileSync(path, "utf8")) as unknown);
}

export function rpcUrl(deployment: Deployment): string {
  return process.env.RPC_URL || deployment.rpc;
}

export function makeChain(chainId: number, url: string) {
  return defineChain({
    id: chainId,
    name: chainId === 10143 ? "Monad Testnet" : `Montions chain ${chainId}`,
    nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 },
    rpcUrls: { default: { http: [url] } },
  });
}

export function loadBotContext(requireWallet = true): BotContext {
  const deployment = readDeployment();
  const url = rpcUrl(deployment);
  const chain = makeChain(deployment.chainId, url);
  const publicClient = createPublicClient({ chain, transport: http(url) });
  const privateKey = process.env.BOT_PRIVATE_KEY as Hex | undefined;
  const unlockedAddress = process.env.BOT_ADDRESS;
  if (requireWallet && !privateKey && !unlockedAddress) {
    throw new Error("Set BOT_PRIVATE_KEY, use an unlocked BOT_ADDRESS, or run with --dry-run");
  }
  if (privateKey) {
    if (!/^0x[0-9a-fA-F]{64}$/.test(privateKey)) throw new Error("BOT_PRIVATE_KEY must be a 32-byte hex private key");
    const account = privateKeyToAccount(privateKey);
    const walletClient = createWalletClient({ account, chain, transport: http(url) });
    return { deployment, rpcUrl: url, publicClient, walletClient, account };
  }
  if (unlockedAddress) {
    if (!isAddress(unlockedAddress)) throw new Error("BOT_ADDRESS must be an EVM address unlocked by the RPC node");
    const account = getAddress(unlockedAddress);
    const walletClient = createWalletClient({ account, chain, transport: http(url) });
    return { deployment, rpcUrl: url, publicClient, walletClient, account };
  }
  return { deployment, rpcUrl: url, publicClient };
}

export function addressAt(deployment: Deployment, ...names: string[]): Address {
  for (const name of names) {
    const value = deployment.contracts[name];
    if (value && isAddress(value)) return value;
  }
  throw new Error(`Deployment is missing contract address: ${names.join(" or ")}`);
}

export function hasFlag(name: string): boolean {
  return process.argv.includes(name);
}

export function isDryRun(): boolean {
  return hasFlag("--dry-run") || process.env.DRY_RUN === "1";
}

export function isOnce(): boolean {
  return hasFlag("--once");
}

export async function sendAndWait(
  context: BotContext,
  hash: Hex,
  label: string,
): Promise<void> {
  const receipt = await context.publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`${label} transaction failed: ${hash}`);
}

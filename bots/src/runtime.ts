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

export function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

export function envInt(name: string, fallback: number, min?: number): number {
  const raw = process.env[name];
  const value = raw === undefined || raw === "" ? fallback : Number(raw);
  if (!Number.isFinite(value) || (min !== undefined && value < min)) {
    throw new Error(`${name} must be a finite number${min !== undefined ? ` >= ${min}` : ""}`);
  }
  return value;
}

export function envFlag(name: string, defaultOn: boolean): boolean {
  const raw = process.env[name];
  if (raw === undefined || raw === "") return defaultOn;
  if (raw === "1" || raw === "true") return true;
  if (raw === "0" || raw === "false") return false;
  throw new Error(`${name} must be 0 or 1`);
}

export function logLine(component: string, fields: Record<string, unknown>): void {
  const parts = [`component=${component}`];
  for (const [key, value] of Object.entries(fields)) {
    if (key.toLowerCase().includes("key") && key.toLowerCase().includes("private")) continue;
    parts.push(`${key}=${formatLogValue(value)}`);
  }
  console.log(parts.join(" "));
}

function formatLogValue(value: unknown): string {
  if (typeof value === "string") return value.includes(" ") ? JSON.stringify(value) : value;
  if (typeof value === "bigint") return value.toString();
  if (typeof value === "boolean" || typeof value === "number") return String(value);
  if (value === null || value === undefined) return "";
  try {
    return JSON.stringify(value);
  } catch {
    return String(value);
  }
}

export function isRetryableRpcError(error: unknown): boolean {
  const message = error instanceof Error ? `${error.name} ${error.message}` : String(error);
  if (/execution reverted|AlreadySettled|PriceFeedNotFoundWithinRange|SeriesExists|NotKeeper/i.test(message)) {
    return false;
  }
  const code =
    typeof error === "object" && error !== null && "code" in error ? Number((error as { code: unknown }).code) : undefined;
  if (code === -32000 || code === -32005 || code === -32603 || code === 429) return true;
  return /timeout|timed out|network|ECONNRESET|ECONNREFUSED|ENOTFOUND|nonce too low|429|503|502|fetch failed|headers timeout|socket hang up/i.test(
    message,
  );
}

export async function withRpcRetry<T>(
  fn: () => Promise<T>,
  options: { attempts?: number; label?: string; sleepFn?: (ms: number) => Promise<void> } = {},
): Promise<T> {
  const attempts = options.attempts ?? 5;
  const sleepFn = options.sleepFn ?? sleep;
  let delay = 400;
  let lastError: unknown;
  for (let i = 0; i < attempts; i++) {
    try {
      return await fn();
    } catch (error) {
      lastError = error;
      if (!isRetryableRpcError(error) || i === attempts - 1) throw error;
      logLine("rpc", {
        event: "retry",
        label: options.label ?? "rpc",
        attempt: i + 1,
        delay_ms: delay,
      });
      await sleepFn(delay);
      delay = Math.min(delay * 2, 8_000);
    }
  }
  throw lastError;
}

/** Serialises signer transactions so at most one is in flight (nonce safety). */
export class SerialTx {
  private tail: Promise<void> = Promise.resolve();
  private inflight = 0;

  get inFlight(): number {
    return this.inflight;
  }

  async run<T>(fn: () => Promise<T>): Promise<T> {
    let release!: () => void;
    const previous = this.tail;
    this.tail = new Promise<void>((resolve) => {
      release = resolve;
    });
    await previous;
    if (this.inflight !== 0) throw new Error("nonce safety: concurrent signer transaction");
    this.inflight = 1;
    try {
      return await fn();
    } finally {
      this.inflight = 0;
      release();
    }
  }
}

/** Pool-priced (demo/testnet) assets have a pool; Pyth-priced (mainnet) assets do not. Pool-only tools call this. */
export function requirePool(asset: { symbol: string; pool?: Address; token?: Address }): Address {
  if (!asset.pool) throw new Error(`${asset.symbol} is priced by Pyth and has no demo pool; this tool only works on pool-priced assets`);
  return asset.pool;
}
export function requireToken(asset: { symbol: string; pool?: Address; token?: Address }): Address {
  if (!asset.token) throw new Error(`${asset.symbol} has no demo token`);
  return asset.token;
}

import type { Address, Hex } from "viem";

/**
 * Field names for PythSettlementResolver.settlements(...) — change here if the
 * contract ABI uses different labels. Types stay (int256, uint64, uint64, bool).
 */
export const PYTH_SETTLEMENT_FIELDS = {
  mapping: "settlements",
  isSettled: "isSettled",
  priceWad: "priceWad",
  publishTime: "publishTime",
  conf: "conf",
  valid: "valid",
} as const;

export const PYTH_SETTLE_WINDOW_SECONDS = 300;
export const PYTH_SETTLE_ATTEMPT_CAP = 16;
export const DEFAULT_HERMES_URL = "https://hermes.pyth.network";

/** Monad mainnet Pyth core (upgradable proxy). */
export const MONAD_PYTH_CORE: Address = "0x2880aB155794e7179c9eE2e38200202908C17B43";

export const DEFAULT_PYTH_FEEDS: Readonly<Record<string, Hex>> = {
  MON: "0x31491744e2dbf6df7fcf4ac0820d18a609b49076d45066d3568424e62f686cd1",
  BTC: "0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43",
  ETH: "0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace",
};

export function pythSettlementAbi() {
  return [
    {
      type: "function",
      name: "settle",
      stateMutability: "payable",
      inputs: [
        { name: "assetId", type: "bytes32" },
        { name: "expiry", type: "uint64" },
        { name: "updateData", type: "bytes[]" },
      ],
      outputs: [],
    },
    {
      type: "function",
      name: PYTH_SETTLEMENT_FIELDS.mapping,
      stateMutability: "view",
      inputs: [
        { name: "assetId", type: "bytes32" },
        { name: "expiry", type: "uint64" },
      ],
      outputs: [
        { name: PYTH_SETTLEMENT_FIELDS.priceWad, type: "int256" },
        { name: PYTH_SETTLEMENT_FIELDS.publishTime, type: "uint64" },
        { name: PYTH_SETTLEMENT_FIELDS.conf, type: "uint64" },
        { name: PYTH_SETTLEMENT_FIELDS.valid, type: "bool" },
      ],
    },
    {
      type: "function",
      name: PYTH_SETTLEMENT_FIELDS.isSettled,
      stateMutability: "view",
      inputs: [
        { name: "assetId", type: "bytes32" },
        { name: "expiry", type: "uint64" },
      ],
      outputs: [{ name: "", type: "bool" }],
    },
    {
      type: "function",
      name: "pyth",
      stateMutability: "view",
      inputs: [],
      outputs: [{ name: "", type: "address" }],
    },
    {
      type: "function",
      name: "oracle",
      stateMutability: "view",
      inputs: [],
      outputs: [{ name: "", type: "address" }],
    },
  ] as const;
}

export const pythOracleAbi = [
  {
    type: "function",
    name: "feedIdOf",
    stateMutability: "view",
    inputs: [{ name: "assetId", type: "bytes32" }],
    outputs: [{ name: "", type: "bytes32" }],
  },
  {
    type: "function",
    name: "latestPrice",
    stateMutability: "view",
    inputs: [{ name: "assetId", type: "bytes32" }],
    outputs: [
      { name: "priceWad", type: "uint256" },
      { name: "updatedAt", type: "uint64" },
    ],
  },
] as const;

export const iPythAbi = [
  {
    type: "function",
    name: "getUpdateFee",
    stateMutability: "view",
    inputs: [{ name: "updateData", type: "bytes[]" }],
    outputs: [{ name: "feeAmount", type: "uint256" }],
  },
] as const;

export interface HermesPriceUpdate {
  updateData: Hex[];
  parsed?: unknown;
}

export interface HermesTransport {
  fetchJson: (url: string) => Promise<unknown>;
}

export interface PythSettleDeps {
  fetchUpdateData: (feedId: Hex, unixTime: number) => Promise<Hex[]>;
  getUpdateFee: (updateData: Hex[]) => Promise<bigint>;
  settle: (assetId: Hex, expiry: bigint, updateData: Hex[], value: bigint) => Promise<void>;
  isSettled: (assetId: Hex, expiry: bigint) => Promise<boolean>;
  sleep: (ms: number) => Promise<void>;
}

export type PythSettleStatus = "settled" | "already" | "too_early" | "not_found";

export interface PythSettleResult {
  status: PythSettleStatus;
  publishTimeTried?: number;
  attempts: number;
}

export function hermesBaseUrl(env: NodeJS.ProcessEnv = process.env): string {
  const raw = env.HERMES_URL?.trim();
  const base = raw && raw.length > 0 ? raw : DEFAULT_HERMES_URL;
  return base.replace(/\/+$/, "");
}

export function hermesPriceUpdateUrl(baseUrl: string, unixTime: number, feedId: Hex): string {
  if (!Number.isInteger(unixTime) || unixTime < 0) throw new RangeError("unixTime must be a non-negative integer");
  const root = baseUrl.replace(/\/+$/, "");
  return `${root}/v2/updates/price/${unixTime}?ids[]=${encodeURIComponent(feedId)}&encoding=hex&parsed=true`;
}

export function parseHermesUpdate(payload: unknown): Hex[] {
  if (payload === null || typeof payload !== "object") throw new Error("Hermes: response is not an object");
  const binary = (payload as { binary?: { data?: unknown } }).binary;
  const data = binary?.data;
  if (!Array.isArray(data) || data.length === 0) throw new Error("Hermes: missing binary.data updates");
  return data.map((item, index) => {
    if (typeof item !== "string" || item.length === 0) throw new Error(`Hermes: update ${index} is not hex`);
    const hex = (item.startsWith("0x") || item.startsWith("0X") ? item : `0x${item}`) as Hex;
    if (!/^0x[0-9a-fA-F]+$/.test(hex) || (hex.length - 2) % 2 !== 0) {
      throw new Error(`Hermes: update ${index} is not even-length hex`);
    }
    return hex;
  });
}

export async function hermesFetchUpdateData(
  feedId: Hex,
  unixTime: number,
  transport: HermesTransport,
  baseUrl = hermesBaseUrl(),
): Promise<Hex[]> {
  const url = hermesPriceUpdateUrl(baseUrl, unixTime, feedId);
  const payload = await transport.fetchJson(url);
  return parseHermesUpdate(payload);
}

export function defaultHermesTransport(fetchImpl: typeof fetch = fetch): HermesTransport {
  return {
    async fetchJson(url: string): Promise<unknown> {
      const response = await fetchImpl(url);
      if (!response.ok) throw new Error(`Hermes HTTP ${response.status}`);
      return response.json();
    },
  };
}

/**
 * Publish times to try when the unique-first Pyth parser rejects an update.
 * Dense near expiry (where the first print usually is), then exponential jumps
 * out to the 300s window, hard-capped.
 */
export function settlementPublishTimes(
  expirySeconds: number,
  maxDelaySeconds = PYTH_SETTLE_WINDOW_SECONDS,
  hardCap = PYTH_SETTLE_ATTEMPT_CAP,
): number[] {
  if (!Number.isInteger(expirySeconds) || expirySeconds < 0) throw new RangeError("expiry must be a non-negative integer");
  const times = new Set<number>();
  for (let i = 0; i <= 7; i++) {
    if (i <= maxDelaySeconds) times.add(expirySeconds + i);
  }
  for (let step = 1; step <= maxDelaySeconds; step *= 2) times.add(expirySeconds + step);
  times.add(expirySeconds + maxDelaySeconds);
  return [...times].filter((t) => t >= expirySeconds && t <= expirySeconds + maxDelaySeconds).sort((a, b) => a - b).slice(0, hardCap);
}

export function retryDelayMs(attemptIndex: number): number {
  if (attemptIndex <= 0) return 0;
  return Math.min(200 * 2 ** (attemptIndex - 1), 5_000);
}

export function pythFeedIdForSymbol(symbol: string, env: NodeJS.ProcessEnv = process.env): Hex | undefined {
  const key = `PYTH_FEED_${symbol.toUpperCase()}`;
  const fromEnv = env[key]?.trim();
  if (fromEnv) {
    if (!/^0x[0-9a-fA-F]{64}$/.test(fromEnv)) throw new Error(`${key} must be a 32-byte hex feed id`);
    return fromEnv as Hex;
  }
  return DEFAULT_PYTH_FEEDS[symbol.toUpperCase()];
}

export function revertName(error: unknown): string | undefined {
  const names = ["AlreadySettled", "PriceFeedNotFoundWithinRange", "NotExpired", "InsufficientFee"];
  const blobs: string[] = [];
  let current: unknown = error;
  for (let i = 0; i < 6 && current; i++) {
    if (current instanceof Error) blobs.push(current.name, current.message);
    if (typeof current === "object" && current !== null) {
      const rec = current as Record<string, unknown>;
      for (const key of ["shortMessage", "details", "reason", "errorName", "data"]) {
        const value = rec[key];
        if (typeof value === "string") blobs.push(value);
        if (value && typeof value === "object" && "errorName" in value && typeof (value as { errorName: unknown }).errorName === "string") {
          blobs.push((value as { errorName: string }).errorName);
        }
      }
      current = rec.cause ?? rec.error;
    } else {
      blobs.push(String(current));
      break;
    }
  }
  const joined = blobs.join(" ");
  return names.find((name) => joined.includes(name));
}

export async function settlePythWindow(input: {
  assetId: Hex;
  expiry: bigint;
  feedId: Hex;
  nowSeconds: bigint;
  deps: PythSettleDeps;
  maxDelaySeconds?: number;
  maxAttempts?: number;
}): Promise<PythSettleResult> {
  const maxDelay = input.maxDelaySeconds ?? PYTH_SETTLE_WINDOW_SECONDS;
  const maxAttempts = input.maxAttempts ?? PYTH_SETTLE_ATTEMPT_CAP;
  if (input.nowSeconds <= input.expiry) return { status: "too_early", attempts: 0 };
  if (await input.deps.isSettled(input.assetId, input.expiry)) {
    return { status: "already", attempts: 0 };
  }

  const times = settlementPublishTimes(Number(input.expiry), maxDelay, maxAttempts);
  let attempts = 0;
  for (let i = 0; i < times.length; i++) {
    const publishTime = times[i]!;
    attempts++;
    const delay = retryDelayMs(i);
    if (delay > 0) await input.deps.sleep(delay);
    let updateData: Hex[];
    try {
      updateData = await input.deps.fetchUpdateData(input.feedId, publishTime);
    } catch {
      continue;
    }
    let fee: bigint;
    try {
      fee = await input.deps.getUpdateFee(updateData);
    } catch {
      continue;
    }
    try {
      await input.deps.settle(input.assetId, input.expiry, updateData, fee);
      return { status: "settled", publishTimeTried: publishTime, attempts };
    } catch (error) {
      const name = revertName(error);
      if (name === "AlreadySettled") return { status: "already", publishTimeTried: publishTime, attempts };
      if (name === "PriceFeedNotFoundWithinRange") continue;
      throw error;
    }
  }
  return { status: "not_found", attempts };
}

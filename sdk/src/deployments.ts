import { getAddress, isAddress, type Address, type Hex } from "viem";

/** One asset entry in a SPEC §10 deployment manifest. */
export interface DeploymentAsset {
  symbol: string;
  assetId: Hex;
  /** Pool-TWAP assets (demo/testnet) have a pool and token; Pyth-priced assets (mainnet) do not. */
  pool?: Address;
  token?: Address;
  decimals: number;
  /** Which oracle prices/settles this asset. Defaults to "pool" when a pool is present, else "pyth". */
  oracle?: "pool" | "pyth";
  /** Pyth feed id for Pyth-priced assets. */
  feedId?: Hex;
  /** Display name. */
  name?: string;
  /** True when the underlying is a MOCK/demo market and the UI must say so. */
  mock?: boolean;
  /** Ladder depth profile: "major" | "alt" | "wrapped". */
  tier?: string;
}

/** The JSON shape emitted by script/Deploy.s.sol. */
export interface Deployment {
  chainId: number;
  rpc: string;
  /** Optional extra RPC endpoints; the app uses them as automatic fallbacks. */
  rpcs?: string[];
  /** Block explorer base URL (no trailing slash). */
  explorer?: string;
  /** Deployment tier; drives UI disclosures and guards. */
  network?: "local" | "testnet" | "mainnet";
  contracts: Record<string, Address>;
  assets: DeploymentAsset[];
  startBlock: bigint;
}

function invalid(message: string): never {
  throw new Error(`Invalid Montions deployment: ${message}`);
}

function address(value: unknown, field: string): Address {
  if (typeof value !== "string" || !isAddress(value)) invalid(`${field} must be an EVM address`);
  return getAddress(value);
}

function bytes32(value: unknown, field: string): Hex {
  if (typeof value !== "string" || !/^0x[0-9a-fA-F]{64}$/.test(value)) {
    invalid(`${field} must be a 32-byte hex value`);
  }
  return value as Hex;
}

function positiveInteger(value: unknown, field: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    invalid(`${field} must be a non-negative safe integer`);
  }
  return value;
}

/**
 * Validates and normalizes a deployment manifest. Keeping this separate from
 * file loading also makes browser and bundler consumers able to validate a
 * manifest fetched from their own asset server.
 */
export function parseDeployment(value: unknown): Deployment {
  if (value === null || typeof value !== "object") invalid("manifest must be an object");
  const raw = value as Record<string, unknown>;
  const chainId = positiveInteger(raw.chainId, "chainId");
  if (chainId === 0) invalid("chainId must be greater than zero");
  if (typeof raw.rpc !== "string" || raw.rpc.length === 0) invalid("rpc must be a non-empty URL string");
  try {
    // This catches accidental local paths while still allowing custom schemes
    // used by an application-provided RPC gateway.
    new URL(raw.rpc);
  } catch {
    invalid("rpc must be a valid URL");
  }
  if (!Array.isArray(raw.assets)) invalid("assets must be an array");
  if (raw.contracts === null || typeof raw.contracts !== "object" || Array.isArray(raw.contracts)) {
    invalid("contracts must be an object");
  }

  const contracts: Record<string, Address> = {};
  for (const [name, valueForContract] of Object.entries(raw.contracts as Record<string, unknown>)) {
    if (name.length === 0) invalid("contract names must not be empty");
    contracts[name] = address(valueForContract, `contracts.${name}`);
  }

  const assets: DeploymentAsset[] = raw.assets.map((assetValue, index) => {
    if (assetValue === null || typeof assetValue !== "object") invalid(`assets[${index}] must be an object`);
    const asset = assetValue as Record<string, unknown>;
    if (typeof asset.symbol !== "string" || asset.symbol.length === 0) {
      invalid(`assets[${index}].symbol must be a non-empty string`);
    }
    const oracle = asset.oracle === undefined ? (asset.pool ? "pool" : "pyth") : asset.oracle;
    if (oracle !== "pool" && oracle !== "pyth") invalid(`assets[${index}].oracle must be "pool" or "pyth"`);
    if (oracle === "pool" && (!asset.pool || !asset.token)) invalid(`assets[${index}] needs pool and token for oracle "pool"`);
    if (oracle === "pyth") bytes32(asset.feedId, `assets[${index}].feedId`);
    return {
      symbol: asset.symbol,
      assetId: bytes32(asset.assetId, `assets[${index}].assetId`),
      ...(asset.pool ? { pool: address(asset.pool, `assets[${index}].pool`) } : {}),
      ...(asset.token ? { token: address(asset.token, `assets[${index}].token`) } : {}),
      decimals: positiveInteger(asset.decimals, `assets[${index}].decimals`),
      oracle,
      ...(asset.feedId ? { feedId: bytes32(asset.feedId, `assets[${index}].feedId`) } : {}),
      ...(typeof asset.name === "string" ? { name: asset.name } : {}),
      ...(typeof asset.mock === "boolean" ? { mock: asset.mock } : {}),
      ...(typeof asset.tier === "string" ? { tier: asset.tier } : {}),
    };
  });

  for (const [index, asset] of assets.entries()) {
    if (asset.decimals > 255) invalid(`assets[${index}].decimals must fit in uint8`);
  }

  const rawStartBlock = raw.startBlock;
  let startBlock: bigint;
  try {
    if (typeof rawStartBlock === "number" && !Number.isSafeInteger(rawStartBlock)) {
      invalid("startBlock must be an integer");
    }
    if (typeof rawStartBlock !== "string" && typeof rawStartBlock !== "number" && typeof rawStartBlock !== "bigint") {
      invalid("startBlock must be an integer");
    }
    startBlock = BigInt(rawStartBlock);
  } catch {
    invalid("startBlock must be an integer");
  }
  if (startBlock < 0n) invalid("startBlock must be non-negative");

  const rpcs = Array.isArray(raw.rpcs) ? raw.rpcs.filter((u): u is string => typeof u === "string" && /^https?:\/\//.test(u)) : undefined;
  const network = raw.network === "local" || raw.network === "testnet" || raw.network === "mainnet" ? raw.network : undefined;
  const explorer = typeof raw.explorer === "string" && /^https?:\/\//.test(raw.explorer) ? raw.explorer.replace(/\/$/, "") : undefined;
  return { chainId, rpc: raw.rpc, ...(rpcs?.length ? { rpcs } : {}), ...(explorer ? { explorer } : {}), ...(network ? { network } : {}), contracts, assets, startBlock };
}

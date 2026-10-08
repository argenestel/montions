import { hashDomain, parseAbi,
  createPublicClient,
  createWalletClient,
  encodeFunctionData,
  getAddress,
  http,
  parseSignature,
  type Account,
  type Address,
  type Chain,
  type Hex,
  type Hash,
  type PublicClient,
  type Transport,
  type WalletClient,
} from "viem";
import { erc20Abi, mockTokenAbi, makerVaultAbi, montionsBookAbi, quoterAbi } from "./abi/index.js";
import { MULTICALL3_ADDRESS, monadTestnet } from "./chain.js";
import type { Deployment } from "./deployments.js";

export type AccountLike = Account | Address;
export type Numeric = bigint | number | string;
export type BookStatus = 0 | 1 | 2 | 3;
export type SolidityBookSide = 0 | 1 | "bid" | "ask" | "Bid" | "Ask";
export type BookTif = 0 | 1 | 2 | "gtc" | "ioc" | "postOnly" | "post-only" | "GTC" | "IOC" | "POST_ONLY";

export interface MontionsAddresses {
  book?: Address;
  quoter?: Address;
  collateral?: Address;
  vault?: Address;
  oracle?: Address;
  [contract: string]: Address | undefined;
}

export interface MontionsClientOptions {
  /** Contract addresses can be supplied directly or taken from deployment. */
  addresses?: MontionsAddresses;
  deployment?: Deployment;
  chain?: Chain;
  rpcUrl?: string;
  transport?: Transport;
  publicClient?: PublicClient;
  walletClient?: WalletClient;
  account?: AccountLike;
}

export interface SeriesInfo {
  resolver: Address;
  data: Hex;
  expiry: bigint;
  status: BookStatus;
  yes: boolean;
  yesId: bigint;
  noId: bigint;
  createdAt: bigint;
}

export interface BookDepthLevel {
  tick: number;
  qty: bigint;
}

export interface OrderView {
  id: bigint;
  maker: Address;
  seriesId: Hex;
  side: 0 | 1;
  tick: number;
  fromHeld: boolean;
  qty: bigint;
  origQty: bigint;
  placedAt: bigint;
  open: boolean;
}

export interface TradeView {
  ts: bigint;
  tick: number;
  qty: bigint;
  takerIsBuyer: boolean;
}

export interface BestBidAsk {
  bidTick: number;
  bidQty: bigint;
  askTick: number;
  askQty: bigint;
}

export interface Quote {
  filled: bigint;
  cost: bigint;
  avgTick: number;
  worstTick: number;
  complete: boolean;
}

export interface QuoterSnapshot {
  seriesId: Hex;
  info: SeriesInfo;
  bidTick: number;
  bidQty: bigint;
  askTick: number;
  askQty: bigint;
  lastTick: number;
  fairTick: number;
  probWad: bigint;
  volWad: bigint;
  spotWad: bigint;
  title: string;
}

export interface OutcomeBalances {
  seriesId: Hex;
  owner: Address;
  yes: bigint;
  no: bigint;
  cash: bigint;
  lockedCash: bigint;
}

export interface CashBalances {
  owner: Address;
  free: bigint;
  locked: bigint;
}

export interface PlaceOrderParams {
  seriesId: Hex;
  side: SolidityBookSide;
  tick: Numeric;
  qty: Numeric;
  fromHeld?: boolean;
  tif?: BookTif;
  maxFills?: Numeric;
}

export interface NormalizedPlaceOrderParams {
  seriesId: Hex;
  side: 0 | 1;
  tick: number;
  qty: bigint;
  fromHeld: boolean;
  tif: 0 | 1 | 2;
  maxFills: number;
}

export interface PermitSignature {
  owner: Address;
  spender: Address;
  value: bigint;
  deadline: bigint;
  v: number;
  r: Hex;
  s: Hex;
  signature: Hex;
}

export interface SignPermitParameters {
  amount: Numeric;
  deadline?: Numeric;
  owner?: AccountLike;
}

export interface PermitOrderOptions {
  deadline?: Numeric;
  owner?: AccountLike;
  permit?: PermitSignature;
}

const permitTypes = {
  Permit: [
    { name: "owner", type: "address" },
    { name: "spender", type: "address" },
    { name: "value", type: "uint256" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
} as const;

const MAX_UINT64 = (1n << 64n) - 1n;

function bigintValue(value: Numeric, field: string): bigint {
  try {
    if (typeof value === "number" && !Number.isSafeInteger(value)) throw new Error();
    const result = BigInt(value);
    if (result < 0n) throw new Error();
    return result;
  } catch {
    throw new TypeError(`${field} must be a non-negative integer`);
  }
}

function numberValue(value: unknown, field: string): number {
  const numeric = typeof value === "bigint" ? Number(value) : Number(value);
  if (!Number.isSafeInteger(numeric)) throw new TypeError(`${field} is outside the safe integer range`);
  return numeric;
}

function uint8Value(value: unknown, field: string): number {
  const numeric = numberValue(value, field);
  if (numeric < 0 || numeric > 255) throw new RangeError(`${field} must fit in uint8`);
  return numeric;
}

function boolValue(value: unknown): boolean {
  return Boolean(value);
}

function field(value: unknown, index: number, name: string): unknown {
  if (Array.isArray(value)) return value[index];
  if (value !== null && typeof value === "object") return (value as Record<string, unknown>)[name];
  return undefined;
}

function requiredField(value: unknown, index: number, name: string): unknown {
  const result = field(value, index, name);
  if (result === undefined) throw new Error(`Malformed Montions RPC tuple: missing ${name}`);
  return result;
}

function addressValue(value: unknown, fieldName: string): Address {
  if (typeof value !== "string") throw new Error(`Malformed Montions RPC value: ${fieldName}`);
  return getAddress(value);
}

function hexValue(value: unknown, fieldName: string): Hex {
  if (typeof value !== "string" || !value.startsWith("0x")) throw new Error(`Malformed Montions RPC value: ${fieldName}`);
  return value as Hex;
}

function resultValue(value: unknown): unknown {
  // `allowFailure: false` returns bare values. This also makes the helper
  // tolerant of a caller-provided mock that returns Multicall3's tagged form.
  if (value !== null && typeof value === "object" && "result" in value) {
    return (value as { result: unknown }).result;
  }
  return value;
}

function sideValue(side: SolidityBookSide): 0 | 1 {
  if (side === 0 || side === "bid" || side === "Bid") return 0;
  if (side === 1 || side === "ask" || side === "Ask") return 1;
  throw new TypeError(`Unknown Montions book side: ${String(side)}`);
}

function tifValue(tif: BookTif): 0 | 1 | 2 {
  if (tif === 0 || tif === "gtc" || tif === "GTC") return 0;
  if (tif === 1 || tif === "ioc" || tif === "IOC") return 1;
  if (tif === 2 || tif === "postOnly" || tif === "post-only" || tif === "POST_ONLY") return 2;
  throw new TypeError(`Unknown Montions time-in-force: ${String(tif)}`);
}

/** Converts the ergonomic SDK order shape into the Solidity tuple shape. */
export function normalizePlaceOrder(params: PlaceOrderParams): NormalizedPlaceOrderParams {
  const tick = numberValue(params.tick, "tick");
  if (tick < 1 || tick > 99) throw new RangeError("tick must be between 1 and 99");
  const qty = bigintValue(params.qty, "qty");
  if (qty === 0n) throw new RangeError("qty must be greater than zero");
  if (qty > MAX_UINT64) throw new RangeError("qty must fit in uint64");
  const maxFills = numberValue(params.maxFills ?? 0, "maxFills");
  if (maxFills < 0 || maxFills > 65535) throw new RangeError("maxFills must fit in uint16");
  return {
    seriesId: params.seriesId,
    side: sideValue(params.side),
    tick,
    qty,
    fromHeld: params.fromHeld ?? false,
    tif: tifValue(params.tif ?? "gtc"),
    maxFills,
  };
}

function contractName(name: string): string {
  return name.toLowerCase().replace(/[^a-z0-9]/g, "");
}

function addressFromMap(map: MontionsAddresses, names: readonly string[]): Address | undefined {
  for (const name of names) {
    const direct = map[name];
    if (direct) return getAddress(direct);
  }
  const wanted = new Set(names.map(contractName));
  for (const [name, value] of Object.entries(map)) {
    if (value && wanted.has(contractName(name))) return getAddress(value);
  }
  return undefined;
}

function deploymentAddresses(deployment: Deployment | undefined): MontionsAddresses {
  return deployment === undefined ? {} : deployment.contracts;
}

function tupleInfo(value: unknown): SeriesInfo {
  return {
    resolver: addressValue(requiredField(value, 0, "resolver"), "resolver"),
    data: hexValue(requiredField(value, 1, "data"), "data"),
    expiry: bigintValue(requiredField(value, 2, "expiry") as Numeric, "expiry"),
    status: numberValue(requiredField(value, 3, "status"), "status") as BookStatus,
    yes: boolValue(requiredField(value, 4, "yes")),
    yesId: bigintValue(requiredField(value, 5, "yesId") as Numeric, "yesId"),
    noId: bigintValue(requiredField(value, 6, "noId") as Numeric, "noId"),
    createdAt: bigintValue(requiredField(value, 7, "createdAt") as Numeric, "createdAt"),
  };
}

function tupleDepth(value: unknown): BookDepthLevel {
  return {
    tick: numberValue(requiredField(value, 0, "tick"), "tick"),
    qty: bigintValue(requiredField(value, 1, "qty") as Numeric, "qty"),
  };
}

function tupleOrder(value: unknown): OrderView {
  return {
    id: bigintValue(requiredField(value, 0, "id") as Numeric, "id"),
    maker: addressValue(requiredField(value, 1, "maker"), "maker"),
    seriesId: hexValue(requiredField(value, 2, "seriesId"), "seriesId"),
    side: numberValue(requiredField(value, 3, "side"), "side") as 0 | 1,
    tick: numberValue(requiredField(value, 4, "tick"), "tick"),
    fromHeld: boolValue(requiredField(value, 5, "fromHeld")),
    qty: bigintValue(requiredField(value, 6, "qty") as Numeric, "qty"),
    origQty: bigintValue(requiredField(value, 7, "origQty") as Numeric, "origQty"),
    placedAt: bigintValue(requiredField(value, 8, "placedAt") as Numeric, "placedAt"),
    open: boolValue(requiredField(value, 9, "open")),
  };
}

function tupleTrade(value: unknown): TradeView {
  return {
    ts: bigintValue(requiredField(value, 0, "ts") as Numeric, "ts"),
    tick: numberValue(requiredField(value, 1, "tick"), "tick"),
    qty: bigintValue(requiredField(value, 2, "qty") as Numeric, "qty"),
    takerIsBuyer: boolValue(requiredField(value, 3, "takerIsBuyer")),
  };
}

function tupleQuote(value: unknown): Quote {
  return {
    filled: bigintValue(requiredField(value, 0, "filled") as Numeric, "filled"),
    cost: bigintValue(requiredField(value, 1, "cost") as Numeric, "cost"),
    avgTick: numberValue(requiredField(value, 2, "avgTick"), "avgTick"),
    worstTick: numberValue(requiredField(value, 3, "worstTick"), "worstTick"),
    complete: boolValue(requiredField(value, 4, "complete")),
  };
}

function tupleSnapshot(value: unknown): QuoterSnapshot {
  const info = tupleInfo(requiredField(value, 1, "info"));
  return {
    seriesId: hexValue(requiredField(value, 0, "seriesId"), "seriesId"),
    info,
    bidTick: numberValue(requiredField(value, 2, "bidTick"), "bidTick"),
    bidQty: bigintValue(requiredField(value, 3, "bidQty") as Numeric, "bidQty"),
    askTick: numberValue(requiredField(value, 4, "askTick"), "askTick"),
    askQty: bigintValue(requiredField(value, 5, "askQty") as Numeric, "askQty"),
    lastTick: numberValue(requiredField(value, 6, "lastTick"), "lastTick"),
    fairTick: numberValue(requiredField(value, 7, "fairTick"), "fairTick"),
    probWad: bigintValue(requiredField(value, 8, "probWad") as Numeric, "probWad"),
    volWad: bigintValue(requiredField(value, 9, "volWad") as Numeric, "volWad"),
    spotWad: bigintValue(requiredField(value, 10, "spotWad") as Numeric, "spotWad"),
    title: String(requiredField(value, 11, "title")),
  };
}

type ReadContract = (parameters: Record<string, unknown>) => Promise<unknown>;
type Multicall = (parameters: Record<string, unknown>) => Promise<unknown>;
type WriteContract = (parameters: Record<string, unknown>) => Promise<Hash>;

/**
 * Thin viem wrapper for the Montions contracts.
 *
 * Reads that need more than one value use Multicall3 explicitly. The SDK has
 * no event/log dependency: all UI state comes from contract view functions.
 */
export class MontionsClient {
  readonly publicClient: PublicClient;
  readonly walletClient?: WalletClient;
  readonly chain: Chain;
  readonly addresses: Required<Pick<MontionsAddresses, "book" | "quoter">> & MontionsAddresses;
  readonly deployment?: Deployment;
  readonly account?: AccountLike;

  constructor(options: MontionsClientOptions) {
    this.deployment = options.deployment;
    const deploymentMap = deploymentAddresses(options.deployment);
    const provided = options.addresses ?? {};
    const allAddresses: MontionsAddresses = { ...deploymentMap, ...provided };
    const book = addressFromMap(allAddresses, ["book", "bookAddress", "montionsBook"]);
    const quoter = addressFromMap(allAddresses, ["quoter", "quoterAddress"]);
    if (!book) throw new Error("MontionsClient requires a Book address");
    if (!quoter) throw new Error("MontionsClient requires a Quoter address");
    const collateral = addressFromMap(allAddresses, ["collateral", "collateralAddress", "usdc", "tusdc", "testusdc"]);
    const vault = addressFromMap(allAddresses, ["vault", "vaultAddress", "makerVault"]);
    const oracle = addressFromMap(allAddresses, ["oracle", "oracleHub"]);
    this.addresses = { ...allAddresses, book, quoter, ...(collateral ? { collateral } : {}), ...(vault ? { vault } : {}), ...(oracle ? { oracle } : {}) };
    this.chain = options.chain ?? options.publicClient?.chain ?? monadTestnet;
    if (options.deployment && options.deployment.chainId !== this.chain.id) {
      throw new Error(`Deployment chain ${options.deployment.chainId} does not match client chain ${this.chain.id}`);
    }
    if (options.publicClient?.chain && options.publicClient.chain.id !== this.chain.id) {
      throw new Error(`Public client chain ${options.publicClient.chain.id} does not match client chain ${this.chain.id}`);
    }
    if (options.walletClient?.chain && options.walletClient.chain.id !== this.chain.id) {
      throw new Error(`Wallet client chain ${options.walletClient.chain.id} does not match client chain ${this.chain.id}`);
    }
    this.account = options.account;

    const rpcUrl = options.rpcUrl ?? options.deployment?.rpc ?? this.chain.rpcUrls.default.http[0];
    const transport = options.transport ?? http(rpcUrl);
    this.publicClient = options.publicClient ?? (createPublicClient({ chain: this.chain, transport }) as PublicClient);
    if (options.walletClient) {
      this.walletClient = options.walletClient;
    } else if (options.account) {
      this.walletClient = createWalletClient({ chain: this.chain, transport, account: options.account }) as WalletClient;
    }
  }

  private async read<T>(address: Address, abi: readonly unknown[], functionName: string, args: readonly unknown[] = []): Promise<T> {
    const call: Record<string, unknown> = { address, abi, functionName };
    if (args.length > 0) call.args = args;
    return (this.publicClient.readContract as unknown as ReadContract)(call) as Promise<T>;
  }

  private async multicall(calls: readonly Record<string, unknown>[]): Promise<unknown[]> {
    const result = await (this.publicClient.multicall as unknown as Multicall)({
      contracts: calls,
      allowFailure: false,
      multicallAddress: MULTICALL3_ADDRESS,
    });
    return result as unknown[];
  }

  private requireAddress(name: "collateral" | "vault"): Address {
    const value = this.addresses[name];
    if (!value) throw new Error(`MontionsClient requires a ${name} address for this operation`);
    return value;
  }

  private requireWallet(): WalletClient {
    if (!this.walletClient) throw new Error("MontionsClient requires a walletClient or account for writes");
    return this.walletClient;
  }

  private accountFor(override?: AccountLike): AccountLike {
    const walletAccount = this.walletClient?.account;
    if (override && typeof override === "string") {
      // Preserve a locally-held Account object when the caller supplied only
      // its address (as permit.owner does). Passing the address to viem would
      // make it use an RPC account and skip local signing.
      if (walletAccount && addressOf(walletAccount).toLowerCase() === override.toLowerCase()) return walletAccount;
      if (this.account && addressOf(this.account).toLowerCase() === override.toLowerCase()) return this.account;
    }
    const account = override ?? this.account ?? walletAccount;
    if (!account) throw new Error("MontionsClient requires an account for this operation");
    return account as AccountLike;
  }

  private async write(parameters: Record<string, unknown>, account?: AccountLike): Promise<Hash> {
    const wallet = this.requireWallet();
    return (wallet.writeContract as unknown as WriteContract)({
      ...parameters,
      account: this.accountFor(account),
      chain: this.chain,
    });
  }

  async seriesInfo(seriesId: Hex): Promise<SeriesInfo> {
    return tupleInfo(await this.read(this.addresses.book, montionsBookAbi, "seriesInfo", [seriesId]));
  }

  async getSeriesInfo(seriesId: Hex): Promise<SeriesInfo> {
    return this.seriesInfo(seriesId);
  }

  async snapshots(offset = 0, limit = 100): Promise<QuoterSnapshot[]> {
    const result = await this.read<unknown[]>(this.addresses.quoter, quoterAbi, "snapshots", [bigintValue(offset, "offset"), bigintValue(limit, "limit")]);
    return result.map(tupleSnapshot);
  }

  async getSnapshots(offset = 0, limit = 100): Promise<QuoterSnapshot[]> {
    return this.snapshots(offset, limit);
  }

  async snapshot(seriesId: Hex): Promise<QuoterSnapshot> {
    return tupleSnapshot(await this.read(this.addresses.quoter, quoterAbi, "snapshot", [seriesId]));
  }

  async getDepth(seriesId: Hex, side: SolidityBookSide, maxLevels = 99): Promise<BookDepthLevel[]> {
    const result = await this.read<unknown[]>(this.addresses.book, montionsBookAbi, "depth", [seriesId, sideValue(side), uint8Value(maxLevels, "maxLevels")]);
    return result.map(tupleDepth);
  }

  async depth(seriesId: Hex, side: SolidityBookSide, maxLevels = 99): Promise<BookDepthLevel[]> {
    return this.getDepth(seriesId, side, maxLevels);
  }

  /** Fetches both sides of the order book in one Multicall3 request. */
  async orderBookDepth(seriesId: Hex, maxLevels = 99): Promise<{ bids: BookDepthLevel[]; asks: BookDepthLevel[] }> {
    const calls = [
      { address: this.addresses.book, abi: montionsBookAbi, functionName: "depth", args: [seriesId, 0, uint8Value(maxLevels, "maxLevels")] },
      { address: this.addresses.book, abi: montionsBookAbi, functionName: "depth", args: [seriesId, 1, uint8Value(maxLevels, "maxLevels")] },
    ];
    const values = await this.multicall(calls);
    return {
      bids: (resultValue(values[0]) as unknown[]).map(tupleDepth),
      asks: (resultValue(values[1]) as unknown[]).map(tupleDepth),
    };
  }

  async bestBidAsk(seriesId: Hex): Promise<BestBidAsk> {
    const result = await this.read(this.addresses.book, montionsBookAbi, "bestBidAsk", [seriesId]);
    return {
      bidTick: numberValue(requiredField(result, 0, "bidTick"), "bidTick"),
      bidQty: bigintValue(requiredField(result, 1, "bidQty") as Numeric, "bidQty"),
      askTick: numberValue(requiredField(result, 2, "askTick"), "askTick"),
      askQty: bigintValue(requiredField(result, 3, "askQty") as Numeric, "askQty"),
    };
  }

  async orders(owner: Address, offset = 0, limit = 100): Promise<OrderView[]> {
    const result = await this.read<unknown[]>(this.addresses.book, montionsBookAbi, "ordersOf", [owner, bigintValue(offset, "offset"), bigintValue(limit, "limit")]);
    return result.map(tupleOrder);
  }

  async getOrders(owner: Address, offset = 0, limit = 100): Promise<OrderView[]> {
    return this.orders(owner, offset, limit);
  }

  async orderInfo(orderId: Numeric): Promise<OrderView> {
    return tupleOrder(await this.read(this.addresses.book, montionsBookAbi, "orderInfo", [bigintValue(orderId, "orderId")]));
  }

  async recentTrades(seriesId: Hex, count = 64): Promise<TradeView[]> {
    const result = await this.read<unknown[]>(this.addresses.book, montionsBookAbi, "recentTrades", [seriesId, uint8Value(count, "count")]);
    return result.map(tupleTrade);
  }

  async quoteBuy(seriesId: Hex, yes: boolean, qty: Numeric, maxTick: Numeric): Promise<Quote> {
    return tupleQuote(await this.read(this.addresses.quoter, quoterAbi, "quoteBuy", [seriesId, yes, bigintValue(qty, "qty"), numberValue(maxTick, "maxTick")]));
  }

  async quoteSell(seriesId: Hex, yes: boolean, qty: Numeric, minTick: Numeric): Promise<Quote> {
    return tupleQuote(await this.read(this.addresses.quoter, quoterAbi, "quoteSell", [seriesId, yes, bigintValue(qty, "qty"), numberValue(minTick, "minTick")]));
  }

  /** Reads YES/NO token balances and internal cash in one Multicall3 call. */
  async positions(seriesId: Hex, owner: Address): Promise<OutcomeBalances> {
    const info = await this.seriesInfo(seriesId);
    const values = await this.multicall([
      { address: this.addresses.book, abi: montionsBookAbi, functionName: "balanceOf", args: [owner, info.yesId] },
      { address: this.addresses.book, abi: montionsBookAbi, functionName: "balanceOf", args: [owner, info.noId] },
      { address: this.addresses.book, abi: montionsBookAbi, functionName: "cash", args: [owner] },
      { address: this.addresses.book, abi: montionsBookAbi, functionName: "lockedCash", args: [owner] },
    ]);
    return {
      seriesId,
      owner: getAddress(owner),
      yes: bigintValue(resultValue(values[0]) as Numeric, "yes"),
      no: bigintValue(resultValue(values[1]) as Numeric, "no"),
      cash: bigintValue(resultValue(values[2]) as Numeric, "cash"),
      lockedCash: bigintValue(resultValue(values[3]) as Numeric, "lockedCash"),
    };
  }

  async getPositions(seriesId: Hex, owner: Address): Promise<OutcomeBalances> {
    return this.positions(seriesId, owner);
  }

  async getPosition(seriesId: Hex, owner: Address): Promise<OutcomeBalances> {
    return this.positions(seriesId, owner);
  }

  /** Reads free and locked internal cash in one Multicall3 call. */
  async cashBalances(owner: Address): Promise<CashBalances> {
    const values = await this.multicall([
      { address: this.addresses.book, abi: montionsBookAbi, functionName: "cash", args: [owner] },
      { address: this.addresses.book, abi: montionsBookAbi, functionName: "lockedCash", args: [owner] },
    ]);
    return {
      owner: getAddress(owner),
      free: bigintValue(resultValue(values[0]) as Numeric, "free"),
      locked: bigintValue(resultValue(values[1]) as Numeric, "locked"),
    };
  }

  async getCashBalances(owner: Address): Promise<CashBalances> {
    return this.cashBalances(owner);
  }

  async collateralBalance(owner: Address): Promise<bigint> {
    return bigintValue(await this.read(this.requireAddress("collateral"), erc20Abi, "balanceOf", [owner]), "collateral balance");
  }

  async approveCollateral(spender: Address, amount: Numeric, account?: AccountLike): Promise<Hash> {
    return this.write({
      address: this.requireAddress("collateral"),
      abi: erc20Abi,
      functionName: "approve",
      args: [spender, bigintValue(amount, "amount")],
    }, account);
  }

  async deposit(amount: Numeric, account?: AccountLike): Promise<Hash> {
    return this.write({ address: this.addresses.book, abi: montionsBookAbi, functionName: "deposit", args: [bigintValue(amount, "amount")] }, account);
  }

  async withdraw(amount: Numeric, account?: AccountLike): Promise<Hash> {
    return this.write({ address: this.addresses.book, abi: montionsBookAbi, functionName: "withdraw", args: [bigintValue(amount, "amount")] }, account);
  }

  async placeOrder(params: PlaceOrderParams, account?: AccountLike): Promise<Hash> {
    return this.write({ address: this.addresses.book, abi: montionsBookAbi, functionName: "placeOrder", args: [{ ...normalizePlaceOrder(params) }] }, account);
  }

  async cancelOrder(orderId: Numeric, account?: AccountLike): Promise<Hash> {
    return this.write({ address: this.addresses.book, abi: montionsBookAbi, functionName: "cancelOrder", args: [bigintValue(orderId, "orderId")] }, account);
  }

  async cancel(orderId: Numeric, account?: AccountLike): Promise<Hash> {
    return this.cancelOrder(orderId, account);
  }

  async cancelOrders(orderIds: readonly Numeric[], account?: AccountLike): Promise<Hash> {
    return this.write({ address: this.addresses.book, abi: montionsBookAbi, functionName: "cancelOrders", args: [orderIds.map((id) => bigintValue(id, "orderId"))] }, account);
  }

  async split(seriesId: Hex, qty: Numeric, account?: AccountLike): Promise<Hash> {
    return this.write({ address: this.addresses.book, abi: montionsBookAbi, functionName: "split", args: [seriesId, bigintValue(qty, "qty")] }, account);
  }

  async merge(seriesId: Hex, qty: Numeric, account?: AccountLike): Promise<Hash> {
    return this.write({ address: this.addresses.book, abi: montionsBookAbi, functionName: "merge", args: [seriesId, bigintValue(qty, "qty")] }, account);
  }

  async resolve(seriesId: Hex, account?: AccountLike): Promise<Hash> {
    return this.write({ address: this.addresses.book, abi: montionsBookAbi, functionName: "resolve", args: [seriesId] }, account);
  }

  async redeem(seriesId: Hex, yesQty: Numeric, noQty: Numeric, account?: AccountLike): Promise<Hash> {
    return this.write({ address: this.addresses.book, abi: montionsBookAbi, functionName: "redeem", args: [seriesId, bigintValue(yesQty, "yesQty"), bigintValue(noQty, "noQty")] }, account);
  }

  async faucet(account?: AccountLike): Promise<Hash> {
    return this.write({ address: this.requireAddress("collateral"), abi: mockTokenAbi, functionName: "faucet" }, account);
  }

  async vaultDeposit(assets: Numeric, receiver?: Address, account?: AccountLike): Promise<Hash> {
    const owner = receiver ?? addressOf(this.accountFor(account));
    return this.write({ address: this.requireAddress("vault"), abi: makerVaultAbi, functionName: "deposit", args: [bigintValue(assets, "assets"), owner] }, account);
  }

  async vaultWithdraw(assets: Numeric, receiver?: Address, owner?: AccountLike): Promise<Hash> {
    const ownerAccount = this.accountFor(owner);
    const ownerAddress = addressOf(ownerAccount);
    return this.write({ address: this.requireAddress("vault"), abi: makerVaultAbi, functionName: "withdraw", args: [bigintValue(assets, "assets"), receiver ?? ownerAddress, ownerAddress] }, owner);
  }

  async depositToVault(assets: Numeric, receiver?: Address, account?: AccountLike): Promise<Hash> {
    return this.vaultDeposit(assets, receiver, account);
  }

  async withdrawFromVault(assets: Numeric, receiver?: Address, owner?: AccountLike): Promise<Hash> {
    return this.vaultWithdraw(assets, receiver, owner);
  }

  /**
   * EIP-712 domain version differs per token (Circle USDC uses "2", Solady/OZ mocks use "1"). Resolve it from the token and VERIFY the
   * resulting domain against the token's own DOMAIN_SEPARATOR() so a wrong guess fails loudly here instead of reverting onchain.
   */
  private permitDomainCache = new Map<string, { name: string; version: string }>();
  private async resolvePermitDomain(token: Address, erc20Name: string, chainId: number): Promise<{ name: string; version: string }> {
    const key = `${chainId}:${token.toLowerCase()}`;
    const cached = this.permitDomainCache.get(key); if (cached) return cached;
    const abi = parseAbi([
      "function version() view returns (string)",
      "function DOMAIN_SEPARATOR() view returns (bytes32)",
      "function eip712Domain() view returns (bytes1 fields, string name, string version, uint256 chainId, address verifyingContract, bytes32 salt, uint256[] extensions)",
    ]);
    // ERC-5267 tells us the exact name+version (AUSD's EIP-712 name is "Agora Dollar" while name() is "AUSD").
    let names = [erc20Name]; let versions: string[] = [];
    try {
      const d = (await this.read(token, abi, "eip712Domain")) as readonly unknown[];
      if (typeof d[1] === "string" && d[1]) names = [d[1], erc20Name];
      if (typeof d[2] === "string" && d[2]) versions.push(d[2]);
    } catch { /* no ERC-5267 */ }
    try { const v = String(await this.read(token, abi, "version")); if (v) versions.push(v); } catch { /* no version() */ }
    versions = [...versions, "2", "1"];
    let separator: Hex | undefined;
    try { separator = (await this.read(token, abi, "DOMAIN_SEPARATOR")) as Hex; } catch { /* cannot verify */ }
    const resolved = separator
      ? matchPermitDomain({ names, versions, separator, chainId, token })
      : { name: names[0]!, version: versions[0]! };    // unverifiable: trust what the token declared, else the OZ/Solady default
    this.permitDomainCache.set(key, resolved);
    return resolved;
  }

  async signPermit(parameters: SignPermitParameters): Promise<PermitSignature> {
    const amount = bigintValue(parameters.amount, "amount");
    const deadline = parameters.deadline === undefined
      ? BigInt(Math.floor(Date.now() / 1000) + 3600)
      : bigintValue(parameters.deadline, "deadline");
    const token = this.requireAddress("collateral");
    const wallet = this.requireWallet();
    const requested = parameters.owner ?? this.account ?? wallet.account;
    if (!requested) throw new Error("signPermit requires an owner account");
    const signingAccount = wallet.account ?? requested;
    const owner = addressOf(requested);
    const signer = addressOf(signingAccount);
    if (signer.toLowerCase() !== owner.toLowerCase()) {
      throw new Error(`Wallet account ${signer} does not match permit owner ${owner}`);
    }
    const metadata = await this.multicall([
      { address: token, abi: erc20Abi, functionName: "name" },
      { address: token, abi: erc20Abi, functionName: "nonces", args: [owner] },
    ]);
    const name = String(resultValue(metadata[0]));
    const nonce = bigintValue(resultValue(metadata[1]) as Numeric, "nonce");
    const chainId = await this.publicClient.getChainId();
    if (chainId !== this.chain.id) throw new Error(`RPC chain ${chainId} does not match client chain ${this.chain.id}`);
    const { name: domainName, version } = await this.resolvePermitDomain(token, name, chainId);
    const signature = await (wallet.signTypedData as unknown as (parameters: Record<string, unknown>) => Promise<Hex>)({
      account: signingAccount,
      domain: { name: domainName, version, chainId, verifyingContract: token },
      types: permitTypes,
      primaryType: "Permit",
      message: { owner, spender: this.addresses.book, value: amount, nonce, deadline },
    });
    const parsed = parseSignature(signature);
    const v = Number(parsed.v ?? BigInt(parsed.yParity + 27));
    return { owner, spender: this.addresses.book, value: amount, deadline, v, r: parsed.r, s: parsed.s, signature };
  }

  async createPermit(parameters: SignPermitParameters): Promise<PermitSignature> {
    return this.signPermit(parameters);
  }

  async depositWithPermit(amount: Numeric, permit: PermitSignature, account?: AccountLike): Promise<Hash> {
    const amountValue = bigintValue(amount, "amount");
    if (permit.value !== amountValue) throw new Error("Permit value does not match deposit amount");
    if (permit.spender.toLowerCase() !== this.addresses.book.toLowerCase()) throw new Error("Permit spender does not match the Montions Book");
    const expectedOwner = account ?? this.account ?? this.walletClient?.account;
    if (expectedOwner && permit.owner.toLowerCase() !== addressOf(expectedOwner).toLowerCase()) throw new Error("Permit owner does not match the requested account");
    return this.write({
      address: this.addresses.book,
      abi: montionsBookAbi,
      functionName: "depositWithPermit",
      args: [amountValue, permit.deadline, permit.v, permit.r, permit.s],
    }, account);
  }

  /** Signs EIP-2612 and sends Book.multicall([depositWithPermit, placeOrder]). */
  async depositWithPermitAndPlaceOrder(amount: Numeric, params: PlaceOrderParams, options: PermitOrderOptions = {}): Promise<Hash> {
    const amountValue = bigintValue(amount, "amount");
    const permit = options.permit ?? await this.signPermit({ amount: amountValue, deadline: options.deadline, owner: options.owner });
    if (permit.value !== amountValue) throw new Error("Permit value does not match deposit amount");
    if (permit.spender.toLowerCase() !== this.addresses.book.toLowerCase()) throw new Error("Permit spender does not match the Montions Book");
    const requestedOwner = options.owner ?? this.account ?? this.walletClient?.account;
    if (requestedOwner && permit.owner.toLowerCase() !== addressOf(requestedOwner).toLowerCase()) throw new Error("Permit owner does not match the requested account");
    const depositCall = encodeFunctionData({
      abi: montionsBookAbi,
      functionName: "depositWithPermit",
      args: [amountValue, permit.deadline, permit.v, permit.r, permit.s],
    });
    const orderCall = encodeFunctionData({
      abi: montionsBookAbi,
      functionName: "placeOrder",
      args: [{ ...normalizePlaceOrder(params) }],
    });
    return this.write({ address: this.addresses.book, abi: montionsBookAbi, functionName: "multicall", args: [[depositCall, orderCall]] }, options.owner ?? permit.owner);
  }

  async placeOrderWithPermit(amount: Numeric, params: PlaceOrderParams, options: PermitOrderOptions = {}): Promise<Hash> {
    return this.depositWithPermitAndPlaceOrder(amount, params, options);
  }

  async depositPermitAndPlaceOrder(amount: Numeric, params: PlaceOrderParams, options: PermitOrderOptions = {}): Promise<Hash> {
    return this.depositWithPermitAndPlaceOrder(amount, params, options);
  }
}

function addressOf(account: AccountLike): Address {
  return typeof account === "string" ? getAddress(account) : getAddress(account.address);
}

/** Encodes the exact Book tuple used by placeOrder, useful for offline signing/tests. */
export function encodePlaceOrder(params: PlaceOrderParams): Hex {
  return encodeFunctionData({ abi: montionsBookAbi, functionName: "placeOrder", args: [{ ...normalizePlaceOrder(params) }] });
}

/** Encodes a Book depositWithPermit call without requiring a wallet client. */
export function encodeDepositWithPermit(amount: Numeric, permit: Pick<PermitSignature, "deadline" | "v" | "r" | "s">): Hex {
  return encodeFunctionData({
    abi: montionsBookAbi,
    functionName: "depositWithPermit",
    args: [bigintValue(amount, "amount"), permit.deadline, permit.v, permit.r, permit.s],
  });
}


/** Pick the EIP-712 (name, version) whose domain hash equals the token's DOMAIN_SEPARATOR(). Throws if none matches. */
export function matchPermitDomain(p: { names: string[]; versions: string[]; separator: Hex; chainId: number; token: Address }): { name: string; version: string } {
  const types = { EIP712Domain: [{ name: "name", type: "string" }, { name: "version", type: "string" }, { name: "chainId", type: "uint256" }, { name: "verifyingContract", type: "address" }] } as const;
  const tried: string[] = [];
  for (const name of new Set(p.names)) for (const version of new Set(p.versions)) {
    tried.push(`${name}/${version}`);
    const h = hashDomain({ domain: { name, version, chainId: BigInt(p.chainId), verifyingContract: p.token }, types });
    if (h.toLowerCase() === p.separator.toLowerCase()) return { name, version };
  }
  throw new Error(`Cannot determine the EIP-2612 domain for collateral ${p.token}: none of [${tried.join(", ")}] matches its DOMAIN_SEPARATOR().`);
}

/** Back-compat helper: version only, for a known name. */
export function matchPermitVersion(p: { candidates: string[]; separator: Hex; name: string; chainId: number; token: Address }): string {
  return matchPermitDomain({ names: [p.name], versions: p.candidates, separator: p.separator, chainId: p.chainId, token: p.token }).version;
}

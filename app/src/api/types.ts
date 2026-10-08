export type Hex = `0x${string}`;

export interface Asset {
  symbol: string;
  name: string;
  assetId: Hex;
  spot: number;
  vol: number;          // annualised, 1 = 100%
  mock: boolean;        // true => demo token / demo pool
  tier?: string;        // major | alt | wrapped (ladder depth)
}

export interface SeriesView {
  id: Hex;
  assetSymbol: string;
  strike: number;       // USD
  expiry: number;       // unix seconds
  status: "open" | "resolved" | "void";
  yes?: boolean;
  fairProb: number;     // model P(YES)
  bidTick: number; bidQty: number;
  askTick: number; askQty: number;
  lastTick: number;
  volume: number;
  title: string;
}

export interface Level { tick: number; qty: number }
export interface TradeRow { ts: number; tick: number; qty: number; takerIsBuyer: boolean }

export interface Quote {
  filled: number;       // contracts fillable now
  cost: number;         // USD premium
  avgTick: number;
  worstTick: number;
  complete: boolean;
}

export interface Position {
  seriesId: Hex;
  title: string;
  assetSymbol: string;
  strike: number;
  expiry: number;
  status: "open" | "resolved" | "void";
  yesQty: number;
  noQty: number;
  yes?: boolean;
  markValue: number;    // USD at fair value / redemption value
}

export interface OrderRow { id: number; seriesId: Hex; title: string; side: "bid" | "ask"; tick: number; qty: number; fromHeld: boolean }

export interface AccountView {
  address?: Hex;
  usdc: number;         // wallet tUSDC
  bookCash: number;     // free cash in the Book
  locked: number;       // cash locked in resting orders
  native: number;       // MON for gas
}

export interface VaultView {
  tvl: number;
  sharePrice: number;
  myShares: number;
  myAssets: number;
  activeSeries: number;
  exposurePct: number;
}

export interface ChainInfo {
  name: string;
  chainId: number;
  block: number;
  explorer: string;
  rpc: string;
  mock: boolean;        // true => dev mock, not connected to a deployment
  network: "mock" | "local" | "testnet" | "mainnet";
  paused: boolean;      // Book is paused for NEW risk (exits always work)
  collateralCapUsd?: number; totalCollateralUsd?: number;
  contracts: { name: string; address: string; role: string }[];
}

export type Step = { label: string; state: "todo" | "active" | "done" | "error"; hash?: string };
export interface TxResult { ok: boolean; filled: number; cost: number; hash?: string; block?: number; error?: string }

export interface WalletState { address?: Hex; chainId?: number; expectedChainId: number; wrongNetwork: boolean }
export interface Api {
  mode: "mock" | "chain";
  wallet(): Promise<WalletState>;
  switchNetwork(): Promise<void>;
  disconnect(): void;
  /** subscribe to wallet account/network changes; returns an unsubscribe function */
  onWalletChange(cb: () => void): () => void;
  chainInfo(): Promise<ChainInfo>;
  assets(): Promise<Asset[]>;
  seriesFor(assetSymbol: string): Promise<SeriesView[]>;
  depth(seriesId: Hex, levels?: number): Promise<{ bids: Level[]; asks: Level[] }>;
  trades(seriesId: Hex): Promise<TradeRow[]>;
  quoteBuy(seriesId: Hex, yes: boolean, contracts: number): Promise<Quote>;
  buy(seriesId: Hex, yes: boolean, contracts: number, maxPriceTick: number, onStep: (s: Step[]) => void): Promise<TxResult>;
  connect(): Promise<AccountView>;
  account(): Promise<AccountView>;
  faucet(): Promise<void>;
  positions(): Promise<Position[]>;
  orders(): Promise<OrderRow[]>;
  cancel(orderId: number): Promise<void>;
  redeem(seriesId: Hex): Promise<void>;
  vault(): Promise<VaultView>;
  vaultDeposit(amount: number): Promise<void>;
  vaultWithdraw(amount: number): Promise<void>;
}

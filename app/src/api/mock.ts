// DEV MOCK — in-memory simulation of the Montions contracts so the UI can be built before/without a deployment.
// The production app uses chainApi.ts; this file never talks to a chain and is clearly labelled in the UI.
import { clampTick, digitalProb } from "../lib/model";
import type { AccountView, Api, Asset, ChainInfo, Hex, Level, OrderRow, Position, Quote, SeriesView, Step, TradeRow, TxResult, VaultView, WalletState } from "./types";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));
const hex = (n: number): Hex => `0x${(n + 1).toString(16).padStart(64, "0")}` as Hex;

const ASSETS: Asset[] = [
  { symbol: "MON", name: "Monad", assetId: ("0x" + "11".repeat(32)) as Hex, spot: 1.0, vol: 0.9, mock: true },
  { symbol: "NVDA", name: "Tokenized NVIDIA (mock)", assetId: ("0x" + "22".repeat(32)) as Hex, spot: 182.4, vol: 0.45, mock: true },
];

const STRIKE_MULT = [0.8, 0.9, 0.95, 1.0, 1.05, 1.1, 1.2, 1.35, 1.5];
const EXPIRY_OFFSETS = [15 * 60, 3600, 4 * 3600, 24 * 3600, 3 * 86400, 7 * 86400];

const t0 = Math.floor(Date.now() / 1000);
const spots: Record<string, number> = { MON: 1.0, NVDA: 182.4 };

function niceStrike(spot: number, mult: number) {
  const raw = spot * mult;
  const step = raw >= 100 ? 2.5 : raw >= 10 ? 0.5 : 0.05;
  return Math.round(raw / step) * step;
}

interface MockSeries extends SeriesView { idx: number }
const allSeries: MockSeries[] = [];
{
  let i = 0;
  for (const a of ASSETS) {
    for (const off of EXPIRY_OFFSETS) {
      for (const m of STRIKE_MULT) {
        const strike = niceStrike(a.spot, m);
        const expiry = Math.ceil((t0 + off) / 300) * 300;
        allSeries.push({
          idx: i, id: hex(i), assetSymbol: a.symbol, strike, expiry, status: "open",
          fairProb: 0.5, bidTick: 0, bidQty: 0, askTick: 0, askQty: 0, lastTick: 0, volume: Math.floor(200 + ((i * 7919) % 4000)),
          title: `${a.symbol} ≥ $${strike} (60s TWAP)`,
        });
        i++;
      }
    }
  }
}

const rng = (seed: number) => { let s = seed >>> 0; return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 2 ** 32); };

function ladder(s: MockSeries): { bids: Level[]; asks: Level[]; fair: number } {
  const a = ASSETS.find((x) => x.symbol === s.assetSymbol)!;
  const now = Date.now() / 1000;
  const fair = digitalProb(spots[s.assetSymbol], s.strike, a.vol, s.expiry - now);
  const fTick = fair * 100;
  const r = rng(s.idx * 31 + Math.floor(now / 6));
  const bids: Level[] = []; const asks: Level[] = [];
  const spread = Math.max(1.5, 5 * (1 - Math.abs(fair - 0.5) * 1.6));
  for (let k = 0; k < 7; k++) {
    const at = clampTick(Math.round(fTick + spread / 2 + k * 1.6));
    const bt = clampTick(Math.round(fTick - spread / 2 - k * 1.6));
    if (at < 99 && !asks.find((x) => x.tick === at)) asks.push({ tick: at, qty: Math.round(40 + r() * 460) });
    if (bt >= 1 && !bids.find((x) => x.tick === bt)) bids.push({ tick: bt, qty: Math.round(40 + r() * 460) });
  }
  asks.sort((x, y) => x.tick - y.tick);
  bids.sort((x, y) => y.tick - x.tick);
  return { bids, asks, fair };
}

const state = {
  connected: false,
  usdc: 0, bookCash: 0, locked: 0,
  positions: new Map<string, { yes: number; no: number; cost: number }>(),
  orders: [] as OrderRow[],
  vaultMy: 0,
  block: 1_204_330,
};

setInterval(() => {
  state.block += 3;
  for (const a of ASSETS) spots[a.symbol] *= 1 + (Math.random() - 0.5) * 0.0016 * (a.vol > 0.6 ? 1.6 : 1);
}, 1200);

const view = (s: MockSeries): SeriesView => {
  const l = ladder(s);
  return { ...s, fairProb: l.fair, bidTick: l.bids[0]?.tick ?? 0, bidQty: l.bids[0]?.qty ?? 0, askTick: l.asks[0]?.tick ?? 0, askQty: l.asks[0]?.qty ?? 0, lastTick: Math.round(l.fair * 100) };
};

export const mockApi: Api = {
  mode: "mock",
  async wallet(): Promise<WalletState> { return { address: state.connected ? ("0x95B0A1c9f4d2e6B7A3c8D5e1F0a9B2c48Da8" as Hex) : undefined, chainId: 10143, expectedChainId: 10143, wrongNetwork: false }; },
  async switchNetwork() {},
  disconnect() { state.connected = false; },
  connectOptions() { return ["dev"]; },
  passkeyAccounts() { return []; },
  async switchPasskeyAccount(_i: number) { return mockApi.account(); },
  async peek(_a: string) { return { usdc: 0, native: 0 }; },
  onWalletChange() { return () => {}; },
  async chainInfo(): Promise<ChainInfo> {
    return {
      name: "DEV MOCK (no chain)", chainId: 10143, block: state.block, explorer: "https://testnet.monadvision.com", rpc: "mock", mock: true, network: "mock", paused: false,
      contracts: [
        { name: "MontionsBook", address: "0x0000000000000000000000000000000000000001", role: "Orderbook + collateral + settlement" },
        { name: "OracleHub", address: "0x0000000000000000000000000000000000000002", role: "TWAP oracle over onchain pools" },
        { name: "MakerVault", address: "0x0000000000000000000000000000000000000003", role: "Onchain market maker" },
      ],
    };
  },
  async assets() { return ASSETS.map((a) => ({ ...a, spot: spots[a.symbol] })); },
  async seriesFor(sym) { return allSeries.filter((s) => s.assetSymbol === sym).map(view); },
  async depth(id) {
    const s = allSeries.find((x) => x.id === id)!;
    const l = ladder(s);
    return { bids: l.bids, asks: l.asks };
  },
  async trades(id) {
    const s = allSeries.find((x) => x.id === id)!;
    const l = ladder(s); const r = rng(s.idx + Math.floor(Date.now() / 4000));
    const out: TradeRow[] = [];
    for (let i = 0; i < 12; i++) out.push({ ts: Math.floor(Date.now() / 1000) - i * 9, tick: clampTick(l.fair * 100 + (r() - 0.5) * 6), qty: Math.round(5 + r() * 90), takerIsBuyer: r() > 0.45 });
    return out;
  },
  async quoteBuy(id, yes, contracts): Promise<Quote> {
    const s = allSeries.find((x) => x.id === id)!;
    const l = ladder(s);
    const lv = yes ? l.asks : l.bids;
    let left = contracts, cost = 0, worst = 0;
    for (const lev of lv) {
      if (left <= 0) break;
      const take = Math.min(left, lev.qty);
      const p = yes ? lev.tick : 100 - lev.tick;
      cost += (take * p) / 100; left -= take; worst = p;
    }
    const filled = contracts - left;
    return { filled, cost, avgTick: filled ? Math.round((cost / filled) * 100) : 0, worstTick: worst, complete: left <= 0 };
  },
  async buy(id, yes, contracts, _maxTick, onStep): Promise<TxResult> {
    const s = allSeries.find((x) => x.id === id)!;
    const steps: Step[] = [
      { label: "Sign tUSDC permit (no approval tx)", state: "active" },
      { label: "deposit + placeOrder (one multicall)", state: "todo" },
      { label: "Matched against the onchain book", state: "todo" },
    ];
    onStep(steps); await sleep(700);
    steps[0].state = "done"; steps[1].state = "active"; onStep([...steps]); await sleep(900);
    const q = await mockApi.quoteBuy(id, yes, contracts);
    steps[1].state = "done"; steps[1].hash = "0x" + Math.random().toString(16).slice(2).padEnd(64, "0"); steps[2].state = "active"; onStep([...steps]); await sleep(500);
    steps[2].state = "done"; onStep([...steps]);
    const p = state.positions.get(s.id) ?? { yes: 0, no: 0, cost: 0 };
    if (yes) p.yes += q.filled; else p.no += q.filled; p.cost += q.cost; state.positions.set(s.id, p);
    state.usdc = Math.max(0, state.usdc - q.cost);
    return { ok: true, filled: q.filled, cost: q.cost, hash: steps[1].hash, block: state.block };
  },
  async connect(_k?: unknown) { state.connected = true; if (!state.usdc) state.usdc = 10000; return mockApi.account(); },
  async account(): Promise<AccountView> {
    return { address: state.connected ? ("0x95B0A1c9f4d2e6B7A3c8D5e1F0a9B2c48Da8" as Hex) : undefined, usdc: state.usdc, bookCash: state.bookCash, locked: state.locked, native: state.connected ? 4.2 : 0 };
  },
  async faucet() { state.usdc += 10000; },
  async positions(): Promise<Position[]> {
    const out: Position[] = [];
    for (const [id, p] of state.positions) {
      const s = allSeries.find((x) => x.id === id)!; const v = view(s);
      out.push({ seriesId: s.id, title: s.title, assetSymbol: s.assetSymbol, strike: s.strike, expiry: s.expiry, status: "open", yesQty: p.yes, noQty: p.no, markValue: p.yes * v.fairProb + p.no * (1 - v.fairProb) });
    }
    return out;
  },
  async orders() { return state.orders; },
  async cancel(orderId) { state.orders = state.orders.filter((o) => o.id !== orderId); },
  async redeem() {},
  async vault(): Promise<VaultView> { return { tvl: 182_400, sharePrice: 1.0132, myShares: state.vaultMy, myAssets: state.vaultMy * 1.0132, activeSeries: 18, exposurePct: 0.062 }; },
  async vaultDeposit(a) { state.usdc -= a; state.vaultMy += a / 1.0132; },
  async vaultWithdraw(a) { state.usdc += a; state.vaultMy = Math.max(0, state.vaultMy - a / 1.0132); },
};

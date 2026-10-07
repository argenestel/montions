// Real onchain adapter: everything is read from view functions (no logs, no indexer, no backend).
import { createPublicClient, createWalletClient, custom, decodeAbiParameters, http, type Address, type PublicClient } from "viem";
import { MontionsClient, MULTICALL3_ADDRESS, erc20Abi, makerVaultAbi, monadTestnet, parseDeployment, priceOracleAbi, type Deployment, type QuoterSnapshot } from "@montions/sdk";
import type { AccountView, Api, Asset, ChainInfo, Hex, Level, OrderRow, Position, Quote, SeriesView, Step, TradeRow, TxResult, VaultView } from "./types";

const WAD = 1e18, USDC = 1e6;
const ROLES: Record<string, string> = {
  book: "Orderbook · collateral · settlement", montionsBook: "Orderbook · collateral · settlement", quoter: "Fair value + book walking",
  oracle: "TWAP oracle over onchain pools", oracleHub: "TWAP oracle over onchain pools", vault: "Onchain market maker", makerVault: "Onchain market maker",
  collateral: "Test USDC (6 dec, permit)", usdc: "Test USDC (6 dec, permit)", twapResolver: "Settles price series from TWAP", timelockResolver: "Settles governance-event series",
};

export async function loadDeployment(): Promise<Deployment | undefined> {
  try {
    const r = await fetch(`${import.meta.env.BASE_URL}deployment.json`, { cache: "no-store" });
    if (!r.ok) return undefined;
    const text = await r.text();
    if (!text.trim().startsWith("{")) return undefined;
    return parseDeployment(JSON.parse(text));
  } catch { return undefined; }
}

type Eth = { request: (a: { method: string; params?: unknown[] }) => Promise<unknown> };
const eth = (): Eth | undefined => (globalThis as unknown as { ethereum?: Eth }).ethereum;
const num = (b: bigint) => Number(b);

export function createChainApi(deployment: Deployment): Api {
  const publicClient = createPublicClient({ chain: monadTestnet, transport: http(deployment.rpc), batch: { multicall: { wait: 16 } } }) as PublicClient;
  let client = new MontionsClient({ deployment, publicClient });
  let address: Address | undefined;

  const hub = (deployment.contracts.oracleHub ?? deployment.contracts.oracle) as Address | undefined;
  const assetBySym = new Map(deployment.assets.map((a) => [a.symbol, a]));
  const assetById = new Map(deployment.assets.map((a) => [a.assetId.toLowerCase(), a]));

  // ───────── snapshots (cached a few seconds so parallel polls share one RPC burst)
  let snapCache: { at: number; rows: QuoterSnapshot[] } | undefined;
  const snaps = async (): Promise<QuoterSnapshot[]> => {
    if (snapCache && Date.now() - snapCache.at < 2500) return snapCache.rows;
    const rows: QuoterSnapshot[] = [];
    for (let off = 0; off < 400; off += 50) {
      const page = await client.snapshots(off, 50);
      rows.push(...page);
      if (page.length < 50) break;
    }
    snapCache = { at: Date.now(), rows };
    return rows;
  };

  const decodeData = (data: Hex) => {
    try {
      const [oracle, assetId, strikeWad, above, window] = decodeAbiParameters(
        [{ type: "address" }, { type: "bytes32" }, { type: "uint256" }, { type: "bool" }, { type: "uint32" }], data);
      return { oracle, assetId, strike: Number(strikeWad) / WAD, above, window };
    } catch { return undefined; }
  };

  const toView = (s: QuoterSnapshot): SeriesView | undefined => {
    const d = decodeData(s.info.data);
    const a = d && assetById.get(d.assetId.toLowerCase());
    if (!d || !a) return undefined;
    const status = s.info.status === 2 ? "resolved" : s.info.status === 3 ? "void" : "open";
    return {
      id: s.seriesId, assetSymbol: a.symbol, strike: d.strike, expiry: num(s.info.expiry), status, yes: s.info.status === 2 ? s.info.yes : undefined,
      fairProb: Number(s.probWad) / WAD, bidTick: s.bidTick, bidQty: num(s.bidQty), askTick: s.askTick, askQty: num(s.askQty), lastTick: s.lastTick,
      volume: 0, title: s.title || `${a.symbol} ≥ $${d.strike}`,
    };
  };

  const requireClient = () => { if (!address) throw new Error("Connect a wallet first"); return client; };

  return {
    mode: "chain",
    async chainInfo(): Promise<ChainInfo> {
      const block = await publicClient.getBlockNumber();
      return {
        name: "Monad testnet", chainId: deployment.chainId, block: Number(block), explorer: monadTestnet.blockExplorers.default.url, rpc: deployment.rpc, mock: false,
        contracts: Object.entries(deployment.contracts).map(([name, address]) => ({ name, address, role: ROLES[name] ?? "" })),
      };
    },
    async assets(): Promise<Asset[]> {
      const rows = await snaps();
      return Promise.all(deployment.assets.map(async (a) => {
        let spot = 0;
        if (hub) { const [p] = (await publicClient.readContract({ address: hub, abi: priceOracleAbi, functionName: "latestPrice", args: [a.assetId] })) as [bigint, bigint]; spot = Number(p) / WAD; }
        const vols = rows.filter((r) => decodeData(r.info.data)?.assetId.toLowerCase() === a.assetId.toLowerCase() && r.volWad > 0n).map((r) => Number(r.volWad) / WAD);
        return { symbol: a.symbol, name: a.symbol === "MON" ? "Monad (demo pool)" : `${a.symbol} (mock)`, assetId: a.assetId, spot, vol: vols[0] ?? 0.8, mock: true };
      }));
    },
    async seriesFor(sym) {
      const a = assetBySym.get(sym);
      return (await snaps()).map(toView).filter((v): v is SeriesView => !!v && v.assetSymbol === sym && !!a);
    },
    async depth(id, levels = 8) {
      const d = await client.orderBookDepth(id, levels);
      const m = (l: { tick: number; qty: bigint }): Level => ({ tick: l.tick, qty: num(l.qty) });
      return { bids: d.bids.map(m), asks: d.asks.map(m) };
    },
    async trades(id): Promise<TradeRow[]> {
      return (await client.recentTrades(id, 12)).map((t) => ({ ts: num(t.ts), tick: t.tick, qty: num(t.qty), takerIsBuyer: t.takerIsBuyer }));
    },
    async quoteBuy(id, yes, contracts): Promise<Quote> {
      const q = await client.quoteBuy(id, yes, BigInt(contracts), 99);
      return { filled: num(q.filled), cost: Number(q.cost) / USDC, avgTick: q.avgTick, worstTick: q.worstTick, complete: q.complete };
    },
    async buy(id, yes, contracts, maxPriceTick, onStep): Promise<TxResult> {
      const c = requireClient(); const owner = address!;
      const steps: Step[] = [
        { label: "Sign tUSDC permit (no approval tx)", state: "active" },
        { label: "deposit + placeOrder (one multicall)", state: "todo" },
        { label: "Matched against the onchain book", state: "todo" },
      ];
      const push = () => onStep(steps.map((s) => ({ ...s })));
      push();
      try {
        const qty = BigInt(contracts);
        const tick = yes ? Math.min(99, maxPriceTick) : Math.max(1, 100 - maxPriceTick);
        const escrow = yes ? qty * BigInt(tick) * 10_000n : qty * BigInt(100 - tick) * 10_000n;
        const need = (escrow * 102n) / 100n + 1n;
        const before = await c.positions(id, owner);
        const deposit = need > before.cash ? need - before.cash : 0n;
        const params = { seriesId: id, side: yes ? "bid" : "ask", tick, qty, tif: "ioc", fromHeld: false } as const;
        let hash: Hex;
        if (deposit > 0n) {
          const permit = await c.signPermit({ amount: deposit, owner });
          steps[0].state = "done"; steps[1].state = "active"; push();
          hash = await c.depositWithPermitAndPlaceOrder(deposit, params, { permit });
        } else {
          steps[0].state = "done"; steps[1].state = "active"; push();
          hash = await c.placeOrder(params);
        }
        steps[1].hash = hash; steps[1].state = "done"; steps[2].state = "active"; push();
        const rc = await publicClient.waitForTransactionReceipt({ hash });
        if (rc.status !== "success") throw new Error("Transaction reverted");
        const after = await c.positions(id, owner);
        const filled = Number(yes ? after.yes - before.yes : after.no - before.no);
        const cost = Number(before.cash + deposit - after.cash) / USDC;
        steps[2].state = "done"; push();
        snapCache = undefined;
        return { ok: true, filled, cost, hash, block: Number(rc.blockNumber) };
      } catch (e) {
        const i = steps.findIndex((s) => s.state === "active"); if (i >= 0) steps[i].state = "error"; push();
        return { ok: false, filled: 0, cost: 0, error: e instanceof Error ? e.message.split("\n")[0] : String(e) };
      }
    },
    async connect(): Promise<AccountView> {
      const e = eth(); if (!e) throw new Error("No wallet found. Install MetaMask or Rabby.");
      const [acct] = (await e.request({ method: "eth_requestAccounts" })) as Address[];
      const hexId = `0x${deployment.chainId.toString(16)}`;
      try { await e.request({ method: "wallet_switchEthereumChain", params: [{ chainId: hexId }] }); }
      catch {
        await e.request({ method: "wallet_addEthereumChain", params: [{ chainId: hexId, chainName: "Monad Testnet", nativeCurrency: { name: "MON", symbol: "MON", decimals: 18 }, rpcUrls: [deployment.rpc], blockExplorerUrls: [monadTestnet.blockExplorers.default.url] }] });
      }
      address = acct;
      const walletClient = createWalletClient({ account: acct, chain: monadTestnet, transport: custom(e as never) });
      client = new MontionsClient({ deployment, publicClient, walletClient });
      return this.account();
    },
    async account(): Promise<AccountView> {
      if (!address) return { usdc: 0, bookCash: 0, locked: 0, native: 0 };
      const [usdc, cash, native] = await Promise.all([client.collateralBalance(address), client.cashBalances(address), publicClient.getBalance({ address })]);
      return { address, usdc: Number(usdc) / USDC, bookCash: Number(cash.free) / USDC, locked: Number(cash.locked) / USDC, native: Number(native) / WAD };
    },
    async faucet() { const h = await requireClient().faucet(); await publicClient.waitForTransactionReceipt({ hash: h }); },
    async positions(): Promise<Position[]> {
      if (!address) return [];
      const rows = (await snaps()).filter((s) => !!toView(s));
      const bal = await Promise.all(rows.map((s) => client.positions(s.seriesId, address!)));
      const out: Position[] = [];
      rows.forEach((s, i) => {
        const b = bal[i]; if (b.yes === 0n && b.no === 0n) return;
        const v = toView(s)!; const p = v.fairProb;
        const mark = v.status === "resolved" ? (v.yes ? Number(b.yes) : Number(b.no)) : v.status === "void" ? (Number(b.yes) + Number(b.no)) / 2 : Number(b.yes) * p + Number(b.no) * (1 - p);
        out.push({ seriesId: s.seriesId, title: v.title, assetSymbol: v.assetSymbol, strike: v.strike, expiry: v.expiry, status: v.status, yesQty: Number(b.yes), noQty: Number(b.no), yes: v.yes, markValue: mark });
      });
      return out;
    },
    async orders(): Promise<OrderRow[]> {
      if (!address) return [];
      const rows = await snaps(); const title = new Map(rows.map((s) => [s.seriesId, s.title]));
      return (await client.orders(address, 0, 100)).filter((o) => o.open).map((o) => ({ id: num(o.id), seriesId: o.seriesId, title: title.get(o.seriesId) ?? "", side: o.side === 0 ? "bid" : "ask", tick: o.tick, qty: num(o.qty), fromHeld: o.fromHeld }));
    },
    async cancel(orderId) { const h = await requireClient().cancelOrder(BigInt(orderId)); await publicClient.waitForTransactionReceipt({ hash: h }); },
    async redeem(seriesId) {
      const c = requireClient(); const b = await c.positions(seriesId, address!);
      const h = await c.redeem(seriesId, b.yes, b.no); await publicClient.waitForTransactionReceipt({ hash: h });
    },
    async vault(): Promise<VaultView> {
      const v = deployment.contracts.vault ?? deployment.contracts.makerVault as Address | undefined;
      if (!v) return { tvl: 0, sharePrice: 1, myShares: 0, myAssets: 0, activeSeries: 0, exposurePct: 0 };
      const [assets, supply] = await Promise.all([
        publicClient.readContract({ address: v, abi: makerVaultAbi, functionName: "totalAssets" }) as Promise<bigint>,
        publicClient.readContract({ address: v, abi: makerVaultAbi, functionName: "totalSupply" }) as Promise<bigint>,
      ]);
      const my = address ? ((await publicClient.readContract({ address: v, abi: makerVaultAbi, functionName: "balanceOf", args: [address] })) as bigint) : 0n;
      const price = supply > 0n ? Number(assets) / Number(supply) : 1;
      return { tvl: Number(assets) / USDC, sharePrice: price, myShares: Number(my) / USDC, myAssets: (Number(my) / USDC) * price, activeSeries: (await snaps()).filter((s) => s.info.status === 1).length, exposurePct: 0.3 };
    },
    async vaultDeposit(amount) {
      const c = requireClient(); const v = deployment.contracts.vault ?? deployment.contracts.makerVault as Address;
      const raw = BigInt(Math.round(amount * USDC));
      await publicClient.waitForTransactionReceipt({ hash: await c.approveCollateral(v, raw) });
      await publicClient.waitForTransactionReceipt({ hash: await c.vaultDeposit(raw, address) });
    },
    async vaultWithdraw(amount) {
      const c = requireClient(); const raw = BigInt(Math.round(amount * USDC));
      await publicClient.waitForTransactionReceipt({ hash: await c.vaultWithdraw(raw, address, address) });
    },
  };
}
void erc20Abi; void MULTICALL3_ADDRESS;

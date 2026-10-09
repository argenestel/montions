// Real onchain adapter: everything is read from view functions (no logs, no indexer, no backend).
import { createPublicClient, createWalletClient, custom, decodeAbiParameters, defineChain, fallback, http, parseAbi, type Address, type Chain, type PublicClient } from "viem";
import { MontionsClient, MULTICALL3_ADDRESS, makerVaultAbi, montionsBookAbi, monadTestnet, parseDeployment, priceOracleAbi, type Deployment, type QuoterSnapshot } from "@montions/sdk";
import { explain, isUserRejection } from "../lib/errors";
import { gasPadded } from "../lib/gasPad";
import { listWallets, startWalletDiscovery, walletById } from "../lib/wallets";
import { createPasskeyAccount, endPasskeySession, explainPasskey, passkeyAccountAddresses, passkeyAccountIndex, passkeySupported, signInWithPasskey, switchPasskeyAccount, touchPasskeySession, type PasskeySession } from "../lib/passkey";
import type { AccountView, Api, Asset, Leaderboard, MarketRow, TraderRow, ChainInfo, ConnectKind, Hex, Level, OrderRow, Position, Quote, SeriesView, Step, TradeRow, TxResult, VaultView, WalletState } from "./types";

const vaultConvertAbi = parseAbi(["function convertToAssets(uint256 shares) view returns (uint256)"]);

const WAD = 1e18, USDC = 1e6;
const MONAD_MAINNET_ID = 143;
export const monadMainnet = defineChain({
  id: MONAD_MAINNET_ID, name: "Monad", nativeCurrency: { name: "Monad", symbol: "MON", decimals: 18 },
  rpcUrls: { default: { http: ["https://rpc.monad.xyz"] } },
  blockExplorers: { default: { name: "MonadVision", url: "https://monadvision.com" } },
  contracts: { multicall3: { address: MULTICALL3_ADDRESS } },
});

// Optional Book views added by the safety-controls upgrade; absent on older deployments (calls are try/caught).
const bookExtraAbi = parseAbi([
  "function balanceOfBatch(address[] accounts, uint256[] ids) view returns (uint256[])",
  "function paused() view returns (bool)",
  "function collateralCap() view returns (uint256)",
  "function totalCollateral() view returns (uint256)",
  "function orderCount() view returns (uint64)",
  "function pool(bytes32 seriesId) view returns (uint256)",
]);

const ROLES: Record<string, string> = {
  book: "Orderbook · collateral · settlement", quoter: "Fair value + book walking", oracleHub: "TWAP oracle over onchain pools",
  pythOracle: "Pyth price adapter", pythResolver: "Settles from Pyth's first price at expiry", vault: "Onchain market maker", collateral: "Collateral token (USDC)",
  twapResolver: "Settles price series from the pool TWAP", timelockResolver: "Settles governance-event series",
};

/** Extra RPC endpoints (comma separated, e.g. provider URLs that carry an API key) are tried before the manifest's own. */
const extraRpcs = (chainId: number): string[] => {
  const urls = String(import.meta.env.VITE_RPC_URLS ?? "").split(",").map((u) => u.trim()).filter((u) => /^https:\/\//.test(u));
  // Alchemy: paste only the key; the endpoint for the network the app is on is built here. The key is public in the bundle, so restrict it by domain in the Alchemy dashboard.
  const key = String(import.meta.env.VITE_ALCHEMY_KEY ?? "").trim().replace(/\/+$/, "").split("/").pop() ?? "";   // accepts the bare key or a pasted Alchemy URL
  const slug = chainId === 143 ? "monad-mainnet" : chainId === 10143 ? "monad-testnet" : "";
  return key && slug && /^[A-Za-z0-9_-]+$/.test(key) ? [`https://${slug}.g.alchemy.com/v2/${key}`, ...urls] : urls;
};

export async function loadDeployment(): Promise<Deployment | undefined> {
  try {
    // Dev only: `?deployment=testnet` loads /deployment.testnet.json instead of /deployment.json (look at another network without rebuilding).
    const alt = import.meta.env.DEV && typeof location !== "undefined" ? new URLSearchParams(location.search).get("deployment") : null;
    const file = alt && /^[a-z0-9-]+$/.test(alt) ? `deployment.${alt}.json` : "deployment.json";
    let r = await fetch(`${import.meta.env.BASE_URL}${file}`, { cache: "no-store" });
    // Until a mainnet manifest is published, production serves the testnet deployment instead of an empty page.
    if ((!r.ok || !(await r.clone().text()).trim().startsWith("{")) && file === "deployment.json") r = await fetch(`${import.meta.env.BASE_URL}deployment.testnet.json`, { cache: "no-store" });
    if (!r.ok) return undefined;
    const text = await r.text();
    if (!text.trim().startsWith("{")) return undefined;
    return parseDeployment(JSON.parse(text));
  } catch { return undefined; }
}

type Eth = { request: (a: { method: string; params?: unknown[] }) => Promise<unknown>; on?: (ev: string, cb: (...a: unknown[]) => void) => void; removeListener?: (ev: string, cb: (...a: unknown[]) => void) => void };
startWalletDiscovery();
let chosenWallet: Eth | undefined;
const eth = (): Eth | undefined => chosenWallet ?? (listWallets()[0]?.provider as Eth | undefined);
const num = (b: bigint) => Number(b);

export function createChainApi(deployment: Deployment): Api {
  // "local" = anvil (31337) or any fork served from localhost (e.g. scripts/fork-demo.sh) — fake money, built-in dev wallet.
  const isLocal = deployment.chainId === 31337 || deployment.network === "local" || /^https?:\/\/(127\.0\.0\.1|localhost)/.test(deployment.rpc);
  const network: ChainInfo["network"] = deployment.network ?? (isLocal ? "local" : deployment.chainId === MONAD_MAINNET_ID ? "mainnet" : "testnet");
  // Local anvil: built-in DEV wallet from the node's unlocked accounts (no MetaMask, no keys in the page). `?injected` forces the browser wallet.
  const useDevWallet = isLocal && typeof location !== "undefined" && !new URLSearchParams(location.search).has("injected");

  const chain: Chain = deployment.chainId === monadTestnet.id ? monadTestnet
    : deployment.chainId === MONAD_MAINNET_ID ? monadMainnet
    : defineChain({ id: deployment.chainId, name: isLocal ? "Local anvil (dev)" : `Chain ${deployment.chainId}`, nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 }, rpcUrls: { default: { http: [deployment.rpc] } }, contracts: { multicall3: { address: MULTICALL3_ADDRESS } } });
  const explorer = deployment.explorer ?? chain.blockExplorers?.default.url ?? "";
  const rpcs = [...new Set([...(isLocal ? [] : extraRpcs(deployment.chainId)), deployment.rpc, ...(deployment.rpcs ?? [])])];
  // Multiple endpoints => automatic failover with retries; one endpoint => plain http with retries.
  const transport = rpcs.length > 1 ? fallback(rpcs.map((u) => http(u, { retryCount: 2, timeout: 12_000 })), { retryCount: 1 }) : http(rpcs[0], { retryCount: 2, timeout: 12_000 });
  // No Multicall3 batching: big view calls (Quoter.snapshots) run out of gas when wrapped by aggregate3 on public RPCs.
  const publicClient = createPublicClient({ chain, transport }) as PublicClient;
  let client = new MontionsClient({ deployment, publicClient });
  let address: Address | undefined;
  let kind: ConnectKind | undefined;

  const c = deployment.contracts;
  const poolHub = (c.oracleHub ?? c.oracle) as Address | undefined;
  const pyth = c.pythOracle as Address | undefined;
  const oracleFor = (a: { oracle?: "pool" | "pyth" }) => (a.oracle === "pyth" ? pyth : poolHub);
  const assetBySym = new Map(deployment.assets.map((a) => [a.symbol, a]));
  const assetById = new Map(deployment.assets.map((a) => [a.assetId.toLowerCase(), a]));

  // ───────── series index: scan once, then only the tail; refresh just the asset being viewed (scales to 1000+ markets)
  const snapById = new Map<Hex, QuoterSnapshot>();
  const idsByAsset = new Map<string, Set<Hex>>();
  const refreshedAt = new Map<string, number>();
  let scanned = 0;
  let scanning: Promise<void> | undefined;
  const indexSnap = (s: QuoterSnapshot) => {
    snapById.set(s.seriesId, s);
    const d = decodeData(s.info.data); if (!d) return;
    const k = d.assetId.toLowerCase(); let set = idsByAsset.get(k); if (!set) idsByAsset.set(k, (set = new Set()));
    set.add(s.seriesId);
  };
  const scanNew = (): Promise<void> => (scanning ??= (async () => {
    try {
      for (;;) {
        const page = await client.snapshots(scanned, 50);
        page.forEach(indexSnap); scanned += page.length;
        if (page.length < 50) break;
      }
    } finally { scanning = undefined; }
  })());
  const refreshAsset = async (assetId: string, maxAgeMs = 2500) => {
    const k = assetId.toLowerCase(); if (Date.now() - (refreshedAt.get(k) ?? 0) < maxAgeMs) return;
    refreshedAt.set(k, Date.now());
    const ids = [...(idsByAsset.get(k) ?? [])];
    for (let i = 0; i < ids.length; i += 25) (await Promise.all(ids.slice(i, i + 25).map((id) => client.snapshot(id)))).forEach(indexSnap);
  };
  const allSnaps = (): QuoterSnapshot[] => [...snapById.values()];

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
  const listeners = new Set<() => void>();
  const emit = () => listeners.forEach((f) => f());

  // injected-wallet events
  const attach = (e: Eth) => {
    const onAccounts = (...a: unknown[]) => {
      const list = (a[0] as Address[]) ?? [];
      if (!list.length) { address = undefined; client = new MontionsClient({ deployment, publicClient }); } else if (address) { address = list[0]; rebuildWallet(e); }
      refreshedAt.clear(); emit();
    };
    const onChain = () => { refreshedAt.clear(); emit(); };
    e.on?.("accountsChanged", onAccounts); e.on?.("chainChanged", onChain);
  };
  let attached = false;
  const lbOrders = new Map<number, { maker: Address; seriesId: Hex; open: boolean }>();
  let lbFrom = 0, lbNext = 1;
  const applyPasskey = (session: PasskeySession) => {
    address = session.account.address;
    const walletClient = createWalletClient({ account: session.account, chain, transport: gasPadded(transport) });
    client = new MontionsClient({ deployment, publicClient, walletClient });
  };
  const rebuildWallet = (e: Eth) => {
    const walletClient = createWalletClient({ account: address, chain, transport: custom(e as never) });
    client = new MontionsClient({ deployment, publicClient, walletClient });
  };

  const walletChainId = async (): Promise<number | undefined> => {
    if (kind === "dev" || kind === "passkey" || kind === "passkey-new") return deployment.chainId;
    const e = eth(); if (!e || !address) return undefined;
    try { return parseInt((await e.request({ method: "eth_chainId" })) as string, 16); } catch { return undefined; }
  };

  let collateralSym: string | undefined;
  const readCollateralSymbol = async () => { if (!collateralSym) { try { collateralSym = (await publicClient.readContract({ address: c.collateral as Address, abi: parseAbi(["function symbol() view returns (string)"]), functionName: "symbol" })) as string; } catch { collateralSym = "USDC"; } } return collateralSym; };
  let hasFaucet: boolean | undefined;
  const detectFaucet = async () => { if (hasFaucet === undefined) { try { const code = await publicClient.getCode({ address: c.collateral as Address }); hasFaucet = !!code && code.toLowerCase().includes("de5f72fd"); } catch { hasFaucet = false; } } return hasFaucet; };
  const readExtra = async <T,>(fn: "paused" | "collateralCap" | "totalCollateral", fallbackValue: T): Promise<T> => {
    try { return (await publicClient.readContract({ address: c.book as Address, abi: bookExtraAbi, functionName: fn })) as T; } catch { return fallbackValue; }
  };

  const guardNetwork = async () => {
    const id = await walletChainId();
    if (id !== undefined && id !== deployment.chainId) throw Object.assign(new Error(`Wrong network: wallet is on chain ${id}, expected ${deployment.chainId}`), { code: "WRONG_NETWORK" });
  };

  return {
    mode: "chain",
    async wallet(): Promise<WalletState> {
      const id = await walletChainId();
      touchPasskeySession();
      return { address, chainId: id, expectedChainId: deployment.chainId, wrongNetwork: id !== undefined && id !== deployment.chainId, kind };
    },
    async switchNetwork() {
      const e = eth(); if (!e) throw new Error("No wallet found.");
      const hexId = `0x${deployment.chainId.toString(16)}`;
      try { await e.request({ method: "wallet_switchEthereumChain", params: [{ chainId: hexId }] }); }
      catch (err) {
        if (isUserRejection(err)) throw err;
        await e.request({ method: "wallet_addEthereumChain", params: [{ chainId: hexId, chainName: chain.name, nativeCurrency: chain.nativeCurrency, rpcUrls: rpcs, blockExplorerUrls: explorer ? [explorer] : [] }] });
      }
      emit();
    },
    disconnect() { endPasskeySession(); address = undefined; kind = undefined; client = new MontionsClient({ deployment, publicClient }); emit(); },
    connectOptions(): ConnectKind[] {
      const out: ConnectKind[] = [];
      if (passkeySupported()) out.push("passkey", "passkey-new");
      if (useDevWallet) out.push("dev");
      // A local fork reuses chain id 143: real wallets must not be pointed at it (they would add a fake "Monad" chain). `?injected` opts in.
      if (listWallets().length && !useDevWallet) out.push("injected");
      return out;
    },
    onWalletChange(cb) { listeners.add(cb); return () => { listeners.delete(cb); }; },

    async chainInfo(): Promise<ChainInfo> {
      const [block, paused, cap, total] = await Promise.all([publicClient.getBlockNumber(), readExtra<boolean>("paused", false), readExtra<bigint | undefined>("collateralCap", undefined), readExtra<bigint | undefined>("totalCollateral", undefined)]);
      const big = (v?: bigint) => (v === undefined || v > 10n ** 30n ? undefined : Number(v) / USDC);
      return {
        name: isLocal ? "Local fork" : chain.name, chainId: deployment.chainId, block: Number(block), explorer, rpc: deployment.rpc, mock: false, network, paused,
        collateralCapUsd: big(cap), totalCollateralUsd: big(total),
        contracts: Object.entries(c).map(([name, address]) => ({ name, address, role: ROLES[name] ?? "" })),
      };
    },
    async assets(): Promise<Asset[]> {
      if (scanned === 0) { void scanNew(); }
      return Promise.all(deployment.assets.map(async (a) => {
        let spot = 0, stale = false;
        const oracle = oracleFor(a);
        if (oracle) {
          // One bad/stale feed must never take down the whole asset list.
          try { const [p] = (await publicClient.readContract({ address: oracle, abi: priceOracleAbi, functionName: "latestPrice", args: [a.assetId] })) as [bigint, bigint]; spot = Number(p) / WAD; }
          catch { stale = true; }
        }
        const vols = [...(idsByAsset.get(a.assetId.toLowerCase()) ?? [])].map((id) => snapById.get(id)!).filter((r) => r.volWad > 0n).map((r) => Number(r.volWad) / WAD);
        const mock = a.mock ?? a.oracle !== "pyth";
        const liquid = [...(idsByAsset.get(a.assetId.toLowerCase()) ?? [])].filter((id) => { const r = snapById.get(id); return !!r && r.info.status === 1 && (r.askQty > 0n || r.bidQty > 0n); }).length;
        return { liquid, symbol: a.symbol, name: a.name ?? a.symbol, assetId: a.assetId, spot, vol: vols[0] ?? 0.8, mock, tier: a.tier, stale };
      }));
    },
    async seriesFor(sym) {
      const a = assetBySym.get(sym); if (!a) return [];
      // Progressive: wait only for the FIRST page; keep indexing the rest in the background (the UI polls again in a few seconds).
      if (scanned === 0) { const first = scanNew(); await Promise.race([first, new Promise((r) => setTimeout(r, 4000))]); } else void scanNew();
      await refreshAsset(a.assetId);
      return [...(idsByAsset.get(a.assetId.toLowerCase()) ?? [])].map((id) => toView(snapById.get(id)!)).filter((v): v is SeriesView => !!v);
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
      const steps: Step[] = [
        { label: "Sign collateral permit (no approval tx)", state: "active" },
        { label: "deposit + placeOrder (one transaction)", state: "todo" },
        { label: "Matched against the onchain book", state: "todo" },
      ];
      const push = () => onStep(steps.map((s) => ({ ...s })));
      push();
      try {
        const cl = requireClient(); const owner = address!;
        await guardNetwork();
        const qty = BigInt(contracts);
        const tick = yes ? Math.min(99, maxPriceTick) : Math.max(1, 100 - maxPriceTick);
        const escrow = yes ? qty * BigInt(tick) * 10_000n : qty * BigInt(100 - tick) * 10_000n;
        const need = (escrow * 102n) / 100n + 1n;      // +2% covers any taker-fee reserve
        const before = await cl.positions(id, owner);
        const deposit = need > before.cash ? need - before.cash : 0n;
        const params = { seriesId: id, side: yes ? "bid" : "ask", tick, qty, tif: "ioc", fromHeld: false } as const;
        let hash: Hex;
        if (deposit > 0n) {
          const permit = await cl.signPermit({ amount: deposit, owner });
          steps[0].state = "done"; steps[1].state = "active"; push();
          hash = await cl.depositWithPermitAndPlaceOrder(deposit, params, { permit });
        } else {
          steps[0].state = "done"; steps[1].state = "active"; push();
          hash = await cl.placeOrder(params);
        }
        steps[1].hash = hash; steps[1].state = "done"; steps[2].state = "active"; push();
        const rc = await publicClient.waitForTransactionReceipt({ hash, timeout: 90_000 });
        if (rc.status !== "success") throw new Error("Transaction reverted");
        const after = await cl.positions(id, owner);
        const filled = Number(yes ? after.yes - before.yes : after.no - before.no);
        const cost = Number(before.cash + deposit - after.cash) / USDC;
        steps[2].state = "done"; push();
        refreshedAt.clear();
        if (filled === 0) return { ok: false, filled: 0, cost: 0, hash, error: "Nothing filled: the price moved beyond your limit. You were not charged." };
        return { ok: true, filled, cost, hash, block: Number(rc.blockNumber) };
      } catch (e) {
        const i = steps.findIndex((s) => s.state === "active"); if (i >= 0) steps[i].state = "error"; push();
        return { ok: false, filled: 0, cost: 0, error: explain(e) };
      }
    },
    passkeyAccounts() {
      if (kind !== "passkey" && kind !== "passkey-new") return [];
      const active = passkeyAccountIndex();
      return passkeyAccountAddresses().map((a) => ({ ...a, address: a.address as Hex, active: a.index === active }));
    },
    async switchPasskeyAccount(index: number): Promise<AccountView> {
      applyPasskey(switchPasskeyAccount(index));
      emit();
      return this.account();
    },
    async peek(addr: Hex) {
      const [usdc, native] = await Promise.all([publicClient.readContract({ address: c.collateral as Address, abi: parseAbi(["function balanceOf(address) view returns (uint256)"]), functionName: "balanceOf", args: [addr as Address] }) as Promise<bigint>, publicClient.getBalance({ address: addr as Address })]);
      return { usdc: Number(usdc) / USDC, native: Number(native) / WAD };
    },
    wallets() { return listWallets().map(({ id, name, icon }) => ({ id, name, icon })); },
    async connect(want?: ConnectKind, walletId?: string): Promise<AccountView> {
      const choice: ConnectKind = want ?? (useDevWallet ? "dev" : eth() ? "injected" : "passkey");
      if (choice === "passkey" || choice === "passkey-new") {
        try {
          const expire = () => { address = undefined; kind = undefined; client = new MontionsClient({ deployment, publicClient }); emit(); };
          const session = choice === "passkey" ? await signInWithPasskey(expire) : await createPasskeyAccount("Montions trader", expire);
          kind = choice; applyPasskey(session);
          emit();
          return this.account();
        } catch (e) { throw new Error(explainPasskey(e)); }
      }
      if (choice === "dev") {
        const accts = (await publicClient.request({ method: "eth_accounts" } as never)) as Address[];
        address = accts[5] ?? accts[accts.length - 1]; kind = "dev";
        const walletClient = createWalletClient({ account: address, chain, transport: http(deployment.rpc) });
        client = new MontionsClient({ deployment, publicClient, walletClient });
        emit();
        return this.account();
      }
      chosenWallet = (walletById(walletId)?.provider as Eth | undefined) ?? chosenWallet;
      const e = eth(); if (!e) throw new Error("No browser wallet found. Use a passkey instead, or install MetaMask / Rabby.");
      const [acct] = (await e.request({ method: "eth_requestAccounts" })) as Address[];
      address = acct; kind = "injected";
      if (!attached) { attach(e); attached = true; }
      rebuildWallet(e);
      const id = await walletChainId();
      if (id !== deployment.chainId) { try { await this.switchNetwork(); } catch { /* the wrong-network banner offers a retry */ } }
      emit();
      return this.account();
    },
    async account(): Promise<AccountView> {
      if (!address) return { usdc: 0, bookCash: 0, locked: 0, native: 0 };
      const [usdc, cash, native] = await Promise.all([client.collateralBalance(address), client.cashBalances(address), publicClient.getBalance({ address })]);
      return { address, usdc: Number(usdc) / USDC, bookCash: Number(cash.free) / USDC, locked: Number(cash.locked) / USDC, native: Number(native) / WAD };
    },
    async faucet() {
      if (network === "mainnet") throw new Error("There is no faucet on mainnet.");
      const h = await requireClient().faucet(); await publicClient.waitForTransactionReceipt({ hash: h });
    },
    async positions(): Promise<Position[]> {
      if (!address) return [];
      await scanNew();
      const rows = allSnaps().filter((s) => !!toView(s));
      const owner = address, book = c.book as Address;
      const held = new Set<Hex>();
      for (let i = 0; i < rows.length; i += 200) {            // one eth_call per 200 series (YES+NO ids): no per-series round trips
        const chunk = rows.slice(i, i + 200);
        const ids = chunk.flatMap((r) => [r.info.yesId, r.info.noId]);
        const bals = (await publicClient.readContract({ address: book, abi: bookExtraAbi, functionName: "balanceOfBatch", args: [ids.map(() => owner), ids] })) as bigint[];
        chunk.forEach((r, j) => { if (bals[2 * j] > 0n || bals[2 * j + 1] > 0n) held.add(r.seriesId); });
      }
      const out: Position[] = [];
      for (const id of held) {
        const [fresh, b] = await Promise.all([client.snapshot(id), client.positions(id, owner)]); indexSnap(fresh);
        const v = toView(fresh)!; const p = v.fairProb;
        const mark = v.status === "resolved" ? (v.yes ? Number(b.yes) : Number(b.no)) : v.status === "void" ? (Number(b.yes) + Number(b.no)) / 2 : Number(b.yes) * p + Number(b.no) * (1 - p);
        out.push({ seriesId: id, title: v.title, assetSymbol: v.assetSymbol, strike: v.strike, expiry: v.expiry, status: v.status, yesQty: Number(b.yes), noQty: Number(b.no), yes: v.yes, markValue: mark });
      }
      return out;
    },
    async orders(): Promise<OrderRow[]> {
      if (!address) return [];
      await scanNew(); const title = new Map(allSnaps().map((s) => [s.seriesId, s.title]));
      return (await client.orders(address, 0, 100)).filter((o) => o.open).map((o) => ({ id: num(o.id), seriesId: o.seriesId, title: title.get(o.seriesId) ?? "", side: o.side === 0 ? "bid" : "ask", tick: o.tick, qty: num(o.qty), fromHeld: o.fromHeld }));
    },
    async cancel(orderId) { await guardNetwork(); const h = await requireClient().cancelOrder(BigInt(orderId)); await publicClient.waitForTransactionReceipt({ hash: h }); },
    async redeem(seriesId) {
      await guardNetwork();
      const cl = requireClient(); const b = await cl.positions(seriesId, address!);
      const h = await cl.redeem(seriesId, b.yes, b.no); await publicClient.waitForTransactionReceipt({ hash: h });
    },
    async leaderboard(): Promise<Leaderboard> {
      await scanNew();
      const book = c.book as Address;
      const total = Number((await publicClient.readContract({ address: book, abi: bookExtraAbi, functionName: "orderCount" })) as bigint);
      // Orders: scan incrementally (newest 2,000 at first), 150 cheap view calls per multicall.
      if (lbFrom === 0) lbFrom = Math.max(1, total - 1999);
      while (lbNext <= total) {
        const ids = Array.from({ length: Math.min(150, total - Math.max(lbNext, lbFrom) + 1) }, (_, i) => Math.max(lbNext, lbFrom) + i);
        if (!ids.length) break;
        const res = await publicClient.multicall({ allowFailure: true, contracts: ids.map((id) => ({ address: book, abi: montionsBookAbi, functionName: "orderInfo", args: [BigInt(id)] }) as const) });
        res.forEach((r, i) => { if (r.status === "success") { const o = r.result as { maker: Address; seriesId: Hex; open: boolean }; lbOrders.set(ids[i]!, { maker: o.maker, seriesId: o.seriesId, open: o.open }); } });
        lbNext = ids[ids.length - 1]! + 1;
      }
      const by = new Map<Address, { orders: number; series: Set<Hex>; open: number }>();
      for (const o of lbOrders.values()) { const e = by.get(o.maker) ?? { orders: 0, series: new Set<Hex>(), open: 0 }; e.orders++; e.series.add(o.seriesId); if (o.open) e.open++; by.set(o.maker, e); }
      const top = [...by.entries()].sort((a, b) => b[1].orders - a[1].orders).slice(0, 20);
      // Contracts held (YES + NO outcome tokens) for the top traders: exact balances from the Book's ERC-1155.
      const rows = allSnaps().filter((s) => s.info.status === 1 || s.info.status === 2);
      const held = async (owner: Address) => {
        let sum = 0;
        for (let i = 0; i < rows.length; i += 200) {
          const ids = rows.slice(i, i + 200).flatMap((r) => [r.info.yesId, r.info.noId]);
          const bals = (await publicClient.readContract({ address: book, abi: bookExtraAbi, functionName: "balanceOfBatch", args: [ids.map(() => owner), ids] })) as bigint[];
          for (const b of bals) sum += Number(b);
        }
        return sum;
      };
      const traders: TraderRow[] = [];
      for (let i = 0; i < top.length; i += 5) {
        const part = await Promise.all(top.slice(i, i + 5).map(async ([address, e]) => ({ address: address as Hex, orders: e.orders, markets: e.series.size, open: e.open, held: await held(address).catch(() => 0) })));
        traders.push(...part);
      }
      traders.sort((a, b) => b.orders - a.orders || b.held - a.held);
      // Markets: collateral locked per series (open interest), plus the trades still in the Book's recent-trade ring.
      const live = allSnaps().filter((s) => s.info.status === 1);
      const pools: number[] = [];
      for (let i = 0; i < live.length; i += 150) {
        const res = await publicClient.multicall({ allowFailure: true, contracts: live.slice(i, i + 150).map((s) => ({ address: book, abi: bookExtraAbi, functionName: "pool", args: [s.seriesId] }) as const) });
        res.forEach((r) => pools.push(r.status === "success" ? Number(r.result as bigint) / USDC : 0));
      }
      const ranked = live.map((s, i) => ({ s, pool: pools[i] ?? 0 })).sort((a, b) => b.pool - a.pool).slice(0, 10);
      const markets: MarketRow[] = await Promise.all(ranked.map(async ({ s, pool }) => {
        const v = toView(s); const t = await client.recentTrades(s.seriesId, 64).catch(() => []);
        return { seriesId: s.seriesId, title: v?.title ?? s.title, assetSymbol: v?.assetSymbol ?? "", expiry: num(s.info.expiry), status: "open" as const, pool, trades: t.length };
      }));
      return { traders, markets, ordersScanned: lbOrders.size, ordersTotal: total };
    },
    async vault(): Promise<VaultView> {
      const v = (c.vault ?? c.makerVault) as Address | undefined;
      if (!v) return { tvl: 0, sharePrice: 1, myShares: 0, myAssets: 0, activeSeries: 0, exposurePct: 0 };
      const [assets, supply] = await Promise.all([
        publicClient.readContract({ address: v, abi: makerVaultAbi, functionName: "totalAssets" }) as Promise<bigint>,
        publicClient.readContract({ address: v, abi: makerVaultAbi, functionName: "totalSupply" }) as Promise<bigint>,
      ]);
      const my = address ? ((await publicClient.readContract({ address: v, abi: makerVaultAbi, functionName: "balanceOf", args: [address] })) as bigint) : 0n;
      // Shares carry a 6-digit virtual offset (12 effective decimals), so price and balances go through convertToAssets.
      const toAssets = (shares: bigint) => publicClient.readContract({ address: v, abi: vaultConvertAbi, functionName: "convertToAssets", args: [shares] }) as Promise<bigint>;
      const [one, mine] = await Promise.all([toAssets(10n ** 12n), my > 0n ? toAssets(my) : Promise.resolve(0n)]);
      void supply;
      return { tvl: Number(assets) / USDC, sharePrice: Number(one) / USDC, myShares: Number(my) / 1e12, myAssets: Number(mine) / USDC, activeSeries: (await scanNew(), allSnaps().filter((s) => s.info.status === 1).length), exposurePct: 0.3 };
    },
    async vaultDeposit(amount) {
      await guardNetwork();
      const cl = requireClient(); const v = (c.vault ?? c.makerVault) as Address;
      const raw = BigInt(Math.round(amount * USDC));
      await publicClient.waitForTransactionReceipt({ hash: await cl.approveCollateral(v, raw) });
      await publicClient.waitForTransactionReceipt({ hash: await cl.vaultDeposit(raw, address) });
    },
    async vaultWithdraw(amount) {
      await guardNetwork();
      const cl = requireClient(); const raw = BigInt(Math.round(amount * USDC));
      await publicClient.waitForTransactionReceipt({ hash: await cl.vaultWithdraw(raw, address, address) });
    },
  };
}

import { useCallback, useEffect, useMemo, useState, type ReactElement } from "react";
import { mockApi } from "./api/mock";
import { createChainApi, loadDeployment } from "./api/chain";
import type { AccountView, Api, ChainInfo, ConnectKind, WalletState } from "./api/types";
import { Header } from "./components/Header";
import { AccountSheet } from "./components/AccountSheet";
import { Banners, ErrorBoundary, RiskGate } from "./components/Resilience";
import { explain } from "./lib/errors";
import { withHealth, type Health } from "./lib/health";
import { ApiCtx, CollateralCtx, DockCtx, type DockAction } from "./lib/hooks";
import { ConnectSheet } from "./components/ConnectSheet";
import { PositionsView } from "./views/PositionsView";
import { TradeView } from "./views/TradeView";
import { VaultView } from "./views/VaultView";
import { LeaderboardView } from "./views/LeaderboardView";

type Tab = "trade" | "positions" | "vault" | "leaders";
const Ico = ({ d }: { d: string }) => <svg viewBox="0 0 24 24" width="20" height="20" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d={d} /></svg>;
const TABS: { id: Tab; icon: ReactElement; label: string }[] = [
  { id: "trade", icon: <Ico d="M4 16l5-5 4 4 7-8M15 7h5v5" />, label: "Trade" },
  { id: "positions", icon: <Ico d="M12 3v9h9M20.5 15A9 9 0 1112 3" />, label: "Positions" },
  { id: "vault", icon: <Ico d="M4 8h16v11H4zM8 8V6a4 4 0 018 0v2M12 13v2" />, label: "Vault" },
  { id: "leaders", icon: <Ico d="M8 21h8M12 17v4M7 4h10v5a5 5 0 01-10 0zM17 5h3v2a3 3 0 01-3 3M7 5H4v2a3 3 0 003 3" />, label: "Leaders" },
];

// The simulated API exists for UI development only. A production build never falls back to it silently.
const ALLOW_MOCK = import.meta.env.DEV || import.meta.env.VITE_ALLOW_MOCK === "1";

export default function App() {
  const [raw, setRaw] = useState<Api | undefined>();
  const [state, setState] = useState<"loading" | "ready" | "undeployed">("loading");
  const [health, setHealth] = useState<Health>({ failing: false });
  useEffect(() => {
    loadDeployment().then((d) => {
      if (d) { setRaw(createChainApi(d)); setState("ready"); }
      else if (ALLOW_MOCK) { setRaw(mockApi); setState("ready"); }
      else setState("undeployed");
    });
  }, []);
  const api = useMemo(() => (raw ? withHealth(raw, setHealth) : undefined), [raw]);

  const [tab, setTab] = useState<Tab>("trade");
  const [account, setAccount] = useState<AccountView>();
  const [info, setInfo] = useState<ChainInfo>();
  const [wallet, setWallet] = useState<WalletState>();
  const [toast, setToast] = useState<string>();
  const [dockAction, setDockAction] = useState<DockAction>();
  const [connectOpen, setConnectOpen] = useState(false);
  const [accountOpen, setAccountOpen] = useState(false);
  const say = useCallback((m: string) => { setToast(m); setTimeout(() => setToast(undefined), 5000); }, []);

  const refresh = useCallback(async () => {
    if (!api) return;
    try { setAccount(await api.account()); setWallet(await api.wallet()); } catch (e) { console.error(e); }
  }, [api]);

  useEffect(() => {
    if (!api) return;
    refresh();
    let alive = true;
    const loop = async () => { try { const i = await api.chainInfo(); if (alive) setInfo(i); } catch { /* health banner handles repeated failures */ } if (alive) t = setTimeout(loop, 2500); };
    let t = setTimeout(loop, 0);
    const off = api.onWalletChange(() => { refresh(); });
    return () => { alive = false; clearTimeout(t); off(); };
  }, [api, refresh]);

  // Opens the connect sheet (passkey / browser wallet / dev wallet). Resolves when the sheet closes.
  const connect = useCallback(async () => { setConnectOpen(true); }, []);
  const doConnect = useCallback(async (kind: ConnectKind, walletId?: string) => {
    if (!api) return;
    const acct = await api.connect(kind, walletId);               // throws a readable Error on failure; the sheet shows it
    setAccount(acct); setWallet(await api.wallet()); setConnectOpen(false);
  }, [api]);
  const disconnect = useCallback(() => { api?.disconnect(); setAccount(undefined); setWallet(undefined); }, [api]);
  const switchNet = useCallback(async () => { try { await api?.switchNetwork(); await refresh(); } catch (e) { say(explain(e)); } }, [api, say, refresh]);

  if (state === "undeployed") {
    return (
      <div className="app"><main>
        <h1 className="page-title">Montions isn't deployed here yet</h1>
        <p className="page-sub">This build has no <span className="mono">deployment.json</span>. Deploy the contracts, write the manifest to <span className="mono">app/public/deployment.json</span> and rebuild. See docs/DEPLOY.md.</p>
      </main></div>
    );
  }
  if (!api) return <div className="app"><main><p className="page-sub">Loading deployment…</p></main></div>;

  return (
    <ErrorBoundary>
      <ApiCtx.Provider value={api}>
      <CollateralCtx.Provider value={info?.collateralSymbol ?? "USDC"}>
      <DockCtx.Provider value={setDockAction}>
        <div className="bg" aria-hidden="true"><i /><i /><i /><i /></div>
        <div className="app">
          <Header info={info} account={account} walletKind={wallet?.kind} onAccount={() => setAccountOpen(true)} onConnect={connect} onFaucet={async () => { try { await api.faucet(); await refresh(); } catch (e) { say(explain(e)); } }} />
          <Banners info={info} wallet={wallet} account={account} health={health} onSwitch={switchNet} onRetry={() => { setHealth({ failing: false }); refresh(); }} />
          <RiskGate info={info}>
            <main key={tab} className="view">
              {tab === "trade" && <TradeView account={account} wallet={wallet} info={info} onNeedConnect={connect} onToast={say} />}
              {tab === "positions" && <PositionsView account={account} onChanged={refresh} />}
              {tab === "vault" && <VaultView account={account} onChanged={refresh} />}
              {tab === "leaders" && <LeaderboardView account={account} info={info} />}
            </main>
          </RiskGate>
          <nav className="dock" aria-label="Primary" style={{ "--i": TABS.findIndex((t) => t.id === tab) } as React.CSSProperties}>
            <span className="ind" aria-hidden="true" />
            {TABS.map((t) => (
              <button key={t.id} className={`tab ${tab === t.id ? "sel" : ""}`} title={t.label} aria-label={t.label} aria-current={tab === t.id ? "page" : undefined} onClick={() => setTab(t.id)}>{t.icon}</button>
            ))}
            {tab === "trade" && dockAction && (
              <span className="act"><button className="cta" disabled={dockAction.disabled} onClick={dockAction.onClick} onMouseMove={(e) => { const r = e.currentTarget.getBoundingClientRect(); e.currentTarget.style.setProperty("--mx", `${e.clientX - r.left}px`); e.currentTarget.style.setProperty("--my", `${e.clientY - r.top}px`); }}>{dockAction.label.replace(/ (\S+)$/, "")} <b>{dockAction.label.split(" ").pop()}</b><span className="arr">→</span></button></span>
            )}
          </nav>
          {accountOpen && <AccountSheet account={account} symbol={info?.collateralSymbol ?? "USDC"} onFaucet={info?.faucet !== false && info?.network !== "mainnet" ? async () => { await api.faucet(); await refresh(); } : undefined} onChanged={refresh} onDisconnect={disconnect} onClose={() => setAccountOpen(false)} />}
          {connectOpen && <ConnectSheet options={api.connectOptions()} wallets={api.wallets()} onConnect={doConnect} onClose={() => setConnectOpen(false)} />}
          {toast && <div className="toast" role="status">{toast}</div>}
        </div>
      </DockCtx.Provider>
      </CollateralCtx.Provider>
      </ApiCtx.Provider>
    </ErrorBoundary>
  );
}

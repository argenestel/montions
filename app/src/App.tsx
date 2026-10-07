import { useCallback, useEffect, useMemo, useState } from "react";
import { mockApi } from "./api/mock";
import { createChainApi, loadDeployment } from "./api/chain";
import type { AccountView, Api, ChainInfo, WalletState } from "./api/types";
import { Header } from "./components/Header";
import { Banners, ErrorBoundary, RiskGate } from "./components/Resilience";
import { explain } from "./lib/errors";
import { withHealth, type Health } from "./lib/health";
import { ApiCtx } from "./lib/hooks";
import { PositionsView } from "./views/PositionsView";
import { ProofView } from "./views/ProofView";
import { TradeView } from "./views/TradeView";
import { VaultView } from "./views/VaultView";

type Tab = "trade" | "positions" | "vault" | "proof";
const TABS: { id: Tab; icon: string; label: string }[] = [
  { id: "trade", icon: "↗", label: "Trade" },
  { id: "positions", icon: "◔", label: "Positions" },
  { id: "vault", icon: "◎", label: "Vault" },
  { id: "proof", icon: "⛓", label: "Onchain" },
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

  const connect = useCallback(async () => {
    if (!api) return;
    try { setAccount(await api.connect()); setWallet(await api.wallet()); } catch (e) { say(explain(e)); }
  }, [api, say]);
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
        <div className="app">
          <Header info={info} account={account} onConnect={connect} onFaucet={async () => { try { await api.faucet(); await refresh(); } catch (e) { say(explain(e)); } }} />
          <Banners info={info} wallet={wallet} health={health} onSwitch={switchNet} onRetry={() => { setHealth({ failing: false }); refresh(); }} />
          <RiskGate info={info}>
            <main key={tab} className="view">
              {tab === "trade" && <TradeView account={account} wallet={wallet} info={info} onNeedConnect={connect} onToast={say} />}
              {tab === "positions" && <PositionsView account={account} onChanged={refresh} />}
              {tab === "vault" && <VaultView account={account} onChanged={refresh} />}
              {tab === "proof" && <ProofView />}
            </main>
          </RiskGate>
          <nav className="dock" aria-label="Primary">
            {TABS.map((t) => (
              <button key={t.id} className={tab === t.id ? "sel" : ""} aria-current={tab === t.id ? "page" : undefined} onClick={() => setTab(t.id)}><span aria-hidden="true">{t.icon}</span><span className="t">{t.label}</span></button>
            ))}
          </nav>
          {toast && <div className="toast" role="status">{toast}</div>}
        </div>
      </ApiCtx.Provider>
    </ErrorBoundary>
  );
}

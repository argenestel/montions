import { useCallback, useEffect, useState } from "react";
import { mockApi } from "./api/mock";
import { createChainApi, loadDeployment } from "./api/chain";
import type { AccountView, Api, ChainInfo } from "./api/types";
import { Header } from "./components/Header";
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

export default function App() {
  const [api, setApi] = useState<Api | undefined>();
  useEffect(() => { loadDeployment().then((d) => setApi(d ? createChainApi(d) : mockApi)); }, []);
  const [tab, setTab] = useState<Tab>("trade");
  const [account, setAccount] = useState<AccountView>();
  const [info, setInfo] = useState<ChainInfo>();

  const refresh = useCallback(async () => { try { if (api) setAccount(await api.account()); } catch (e) { console.error(e); } }, [api]);
  useEffect(() => {
    if (!api) return;
    refresh();
    const t = setInterval(async () => { try { setInfo(await api.chainInfo()); } catch { /* ignore */ } }, 2500);
    api.chainInfo().then(setInfo).catch(() => undefined);
    return () => clearInterval(t);
  }, [api, refresh]);

  const connect = useCallback(async () => { if (api) setAccount(await api.connect()); }, [api]);
  if (!api) return <div className="app"><main><p className="page-sub">Loading deployment…</p></main></div>;

  return (
    <ApiCtx.Provider value={api}>
      <div className="app">
        <Header info={info} account={account} onConnect={connect} onFaucet={async () => { await api.faucet(); await refresh(); }} />
        <main key={tab} className="view">
          {tab === "trade" && <TradeView account={account} onNeedConnect={connect} />}
          {tab === "positions" && <PositionsView account={account} onChanged={refresh} />}
          {tab === "vault" && <VaultView account={account} onChanged={refresh} />}
          {tab === "proof" && <ProofView />}
        </main>
        <nav className="dock">
          {TABS.map((t) => (
            <button key={t.id} className={tab === t.id ? "sel" : ""} onClick={() => setTab(t.id)}><span>{t.icon}</span><span className="t">{t.label}</span></button>
          ))}
        </nav>
      </div>
    </ApiCtx.Provider>
  );
}

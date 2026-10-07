import { useState } from "react";
import type { AccountView } from "../api/types";
import { pct, usd } from "../lib/format";
import { useApi, usePoll } from "../lib/hooks";

export function VaultView(props: { account?: AccountView; onChanged: () => void }) {
  const api = useApi();
  const [n, setN] = useState(0);
  const v = usePoll(() => api.vault(), [api, n], 4000);
  const [amt, setAmt] = useState("1000");
  const a = Number(amt) || 0;
  const act = async (f: () => Promise<void>) => { await f(); setN((x) => x + 1); props.onChanged(); };
  return (
    <div>
      <h1 className="page-title">Maker vault</h1>
      <p className="page-sub">An onchain market maker. Anyone can call <span className="mono">refresh(series)</span> to cancel stale quotes and post a ladder around the model fair value. Depositors take the other side of flow — including adverse selection. Exposure per series is hard-capped.</p>
      <div className="stats">
        <div className="stat"><div className="k">Total value</div><div className="v">{usd(v?.tvl ?? 0)}</div></div>
        <div className="stat"><div className="k">Share price</div><div className="v">{(v?.sharePrice ?? 1).toFixed(4)}</div></div>
        <div className="stat"><div className="k">Series quoted</div><div className="v">{v?.activeSeries ?? 0}</div></div>
        <div className="stat"><div className="k">Max exposure / series</div><div className="v">{pct(v?.exposurePct ?? 0, 1)}</div></div>
      </div>
      <div className="card">
        <h3>Your deposit <span className="hint">{usd(v?.myAssets ?? 0, 2)} · {(v?.myShares ?? 0).toFixed(2)} mmUSDC</span></h3>
        <div className="inline-form">
          <div className="big-input"><span>$</span><input inputMode="decimal" value={amt} onChange={(e) => setAmt(e.target.value.replace(/[^\d.]/g, ""))} /></div>
          <button className="btn primary" disabled={!props.account?.address || a <= 0} onClick={() => act(() => api.vaultDeposit(a))}>Deposit</button>
          <button className="btn" disabled={!props.account?.address || a <= 0 || (v?.myAssets ?? 0) < a} onClick={() => act(() => api.vaultWithdraw(a))}>Withdraw</button>
        </div>
        {!props.account?.address && <p className="subnote" style={{ marginTop: 10 }}>Connect a wallet first.</p>}
      </div>
      <div className="card"><h3>Risk, stated plainly</h3>
        <ul className="page-sub" style={{ margin: 0, paddingLeft: 18 }}>
          <li>The vault quotes from an onchain model; informed traders can pick it off when the model lags the market.</li>
          <li>It stops quoting within 10 minutes of expiry and caps per-series exposure; it can still lose money.</li>
          <li>Demo oracle pools are mock and manipulable at low liquidity — this is a testnet demonstration.</li>
        </ul></div>
    </div>
  );
}

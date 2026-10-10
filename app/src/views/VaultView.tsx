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
      <p className="page-sub">An onchain market maker that quotes markets around fair value. Deposits can lose value.</p>
      <div className="stats">
        <div className="stat"><div className="k">TVL</div><div className="v">{usd(v?.tvl ?? 0)}</div></div>
        <div className="stat"><div className="k">Share price</div><div className="v">{(v?.sharePrice ?? 1).toFixed(4)}</div></div>
        <div className="stat"><div className="k">Markets</div><div className="v">{v?.activeSeries ?? 0}</div></div>
        <div className="stat"><div className="k">Max / market</div><div className="v">{pct(v?.exposurePct ?? 0, 1)}</div></div>
      </div>
      <div className="card">
        <h3>Your deposit <span className="hint">{usd(v?.myAssets ?? 0, 2)}</span></h3>
        <div className="inline-form">
          <div className="big-input"><span>$</span><input inputMode="decimal" value={amt} onChange={(e) => setAmt(e.target.value.replace(/[^\d.]/g, ""))} /></div>
          <button className="btn primary" disabled={!props.account?.address || a <= 0} onClick={() => act(() => api.vaultDeposit(a))}>Deposit</button>
          <button className="btn" disabled={!props.account?.address || a <= 0 || (v?.myAssets ?? 0) < a} onClick={() => act(() => api.vaultWithdraw(a))}>Withdraw</button>
        </div>
              </div>
      <p className="subnote">Informed traders can pick off the vault when its model lags. It stops quoting 10 minutes before expiry and caps exposure per market.</p>
    </div>
  );
}

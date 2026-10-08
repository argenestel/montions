import { useState } from "react";
import { createPortal } from "react-dom";
import type { ChainInfo, Quote, SeriesView, Step, TxResult } from "../api/types";
import { price, usd, whenText } from "../lib/format";
import { useApi, useCollateral } from "../lib/hooks";
import { PayoffChart } from "./PayoffChart";

export function ConfirmSheet(props: {
  series: SeriesView; sym: string; spot: number; above: boolean; payout: number; contracts: number; quote?: Quote;
  slip: number; mock: boolean; explorer?: string; network?: ChainInfo["network"]; onClose: () => void;
}) {
  const { series, sym, spot, above, payout, contracts, mock, slip } = props;
  const api = useApi();
  const collateral = useCollateral();
  const [ok, setOk] = useState(false);
  const [steps, setSteps] = useState<Step[]>([]);
  const [res, setRes] = useState<TxResult>();
  const [busy, setBusy] = useState(false);
  const [quote, setQuote] = useState(props.quote);
  const [moved, setMoved] = useState<{ from: number; to: number }>();
  const cost = quote?.cost ?? 0;
  const profit = payout - cost;
  const maxTick = Math.min(99, (quote?.worstTick ?? 99) + slip);
  const realMoney = props.network === "mainnet";

  const go = async () => {
    setBusy(true);
    try {
      // Re-quote right before sending. If the price got materially worse since the user looked, make them confirm the new price.
      const fresh = await api.quoteBuy(series.id, above, contracts);
      if (!fresh.filled) { setRes({ ok: false, filled: 0, cost: 0, error: "There is no liquidity at this price any more. Nothing was sent." }); return; }
      if (quote && fresh.cost > quote.cost * 1.01 + 0.01 && !moved) { setMoved({ from: quote.cost, to: fresh.cost }); setQuote(fresh); return; }
      setQuote(fresh); setMoved(undefined);
      setRes(await api.buy(series.id, above, contracts, Math.min(99, fresh.worstTick + slip), setSteps));
    } catch (e) {
      setRes({ ok: false, filled: 0, cost: 0, error: e instanceof Error ? e.message : String(e) });
    } finally { setBusy(false); }
  };

  const hi = series.strike * 1.08, lo = series.strike * 0.92;
  const rowsList = above
    ? [{ t: `Ends above ${price(series.strike)}`, a: profit, win: true }, { t: `Ends at ${price(lo)}`, a: -cost, win: false }, { t: `Ends below ${price(lo * 0.9)}`, a: -cost, win: false }]
    : [{ t: `Ends below ${price(series.strike)}`, a: profit, win: true }, { t: `Ends at ${price(hi)}`, a: -cost, win: false }, { t: `Ends above ${price(hi * 1.1)}`, a: -cost, win: false }];
  const tx = (h?: string) => (h && props.explorer ? <a href={`${props.explorer}/tx/${h}`} target="_blank" rel="noreferrer">{h.slice(0, 10)}…</a> : h ? <span>{h.slice(0, 10)}…</span> : null);

  return createPortal(
    <div className="scrim" role="dialog" aria-modal="true" aria-label="Confirm position" onMouseDown={(e) => { if (e.target === e.currentTarget && !busy) props.onClose(); }} onKeyDown={(e) => { if (e.key === "Escape" && !busy) props.onClose(); }}>
      <div className="sheet">
        <div className="card">
          <div className="subnote">Your position</div>
          <div className="pos-title">
            Make <mark>{usd(payout)}</mark> if {sym} ends {above ? "above" : "below"} <mark className="g">{price(series.strike)}</mark> by <mark className="v">{whenText(series.expiry)}</mark>
          </div>
          <div className="outcomes">
            {rowsList.map((r) => (
              <div key={r.t} className={`outcome ${r.win ? "win" : "lose"}`}><span>{r.t}</span><span className="a">{r.a >= 0 ? "+" : "−"}{usd(Math.abs(r.a))}</span></div>
            ))}
          </div>
          <PayoffChart strike={series.strike} spot={spot} payout={payout} cost={cost} yes={above} height={180} />
        </div>
        <div className="card">
          {!res ? (
            <>
              <dl className="kv">
                <div><dt>Contracts</dt><dd className="mono">{contracts.toLocaleString()} × $1 payout</dd></div>
                <div><dt>Side</dt><dd>{above ? "YES (above)" : "NO (below)"} · avg {quote?.avgTick ?? "—"}¢</dd></div>
                <div><dt>Maximum loss</dt><dd className="neg">{usd(cost, 2)}</dd></div>
                <div><dt>Maximum profit</dt><dd className="pos">{usd(profit, 2)}</dd></div>
                <div><dt>Price limit</dt><dd>{maxTick}¢ per $1 <span className="subnote">(slippage {slip}¢)</span></dd></div>
                <div><dt>Matching</dt><dd>Onchain CLOB · price-time</dd></div>
                <div><dt>Settlement</dt><dd>{mock ? `Contract · 60s TWAP of demo ${sym} pool` : "Contract · Pyth first price at expiry"}</dd></div>
                <div><dt>Collateral</dt><dd>100% — pays {usd(payout)} from locked {collateral}</dd></div>
              </dl>
              {moved && <div className="banner" style={{ position: "static", borderRadius: 12, marginTop: 10 }} role="alert">Price moved: {usd(moved.from, 2)} → {usd(moved.to, 2)}. Review and confirm again.</div>}
              <label className="check"><input type="checkbox" checked={ok} onChange={(e) => setOk(e.target.checked)} />
                <span>{mock
                  ? "I understand this is a testnet binary option on a DEMO oracle. It pays $1 per contract if the condition is true at expiry and 0 otherwise; I can lose the full premium."
                  : `I understand this binary option pays $1 per contract if true at expiry and $0 otherwise, that I can lose the full premium${realMoney ? " (real funds)" : ""}, and that this software is unaudited.`}</span>
              </label>
              {steps.length > 0 && <div className="steps">{steps.map((s) => (
                <div key={s.label} className={`step ${s.state}`}><span className="ic">{s.state === "done" ? "✓" : s.state === "error" ? "!" : ""}</span>{s.label}{s.hash && <span style={{ marginLeft: "auto" }} className="addr">{tx(s.hash)}</span>}</div>
              ))}</div>}
              <button className="cta" style={{ width: "100%", justifyContent: "center", marginTop: 14 }} disabled={!ok || busy || !quote || quote.filled === 0} onClick={go}>
                {busy ? "Confirming…" : moved ? `Confirm new price ${usd(cost, 2)}` : ok ? `Confirm and pay ${usd(cost, 2)}` : `Tick the box to pay ${usd(cost, 2)}`}
              </button>
              <button className="btn ghost" style={{ width: "100%", marginTop: 8 }} disabled={busy} onClick={props.onClose}>Cancel</button>
            </>
          ) : res.ok ? (
            <div className="success">
              <svg className="check-draw" viewBox="0 0 64 64" aria-hidden="true"><circle cx="32" cy="32" r="30" /><path d="M19 33l9 9 17-19" /></svg>
              <div className="subnote">Filled onchain</div>
              <div className="big">{res.filled.toLocaleString()} contracts</div>
              <p className="subnote">Paid {usd(res.cost, 2)} · block {res.block?.toLocaleString()}</p>
              {res.hash && <p className="addr">{tx(res.hash)}</p>}
              <button className="cta" style={{ width: "100%", justifyContent: "center", marginTop: 8 }} onClick={props.onClose}>Done</button>
            </div>
          ) : (
            <div className="success"><div className="big" style={{ color: "var(--no)" }}>Not filled</div><p className="subnote" role="alert">{res.error}</p><button className="btn" onClick={props.onClose}>Close</button></div>
          )}
        </div>
      </div>
    </div>,
    document.body,
  );
}

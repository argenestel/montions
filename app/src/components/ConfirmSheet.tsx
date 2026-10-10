import { useState } from "react";
import { createPortal } from "react-dom";
import type { ChainInfo, Quote, SeriesView, Step, TxResult } from "../api/types";
import { fullDate, price, short, usd } from "../lib/format";
import { useApi } from "../lib/hooks";
import { PayoffChart } from "./PayoffChart";

export function ConfirmSheet(props: {
  series: SeriesView; sym: string; spot: number; above: boolean; payout: number; contracts: number; quote?: Quote;
  slip: number; onSlip: (n: number) => void; mock: boolean; explorer?: string; network?: ChainInfo["network"]; address?: string; onClose: () => void;
}) {
  const { series, sym, spot, above, payout, contracts, mock, slip } = props;
  const api = useApi();
  const [ok, setOk] = useState(false);
  const [steps, setSteps] = useState<Step[]>([]);
  const [res, setRes] = useState<TxResult>();
  const [busy, setBusy] = useState(false);
  const [more, setMore] = useState(false);
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

  const k = price(series.strike);
  const rows = above
    ? [{ ic: "↗", t: `Ends above ${k}`, a: profit, win: true }, { ic: "→", t: `Ends exactly at ${k}`, a: profit, win: true }, { ic: "↘", t: `Ends below ${k}`, a: -cost, win: false }]
    : [{ ic: "↘", t: `Ends below ${k}`, a: profit, win: true }, { ic: "→", t: `Ends exactly at ${k}`, a: -cost, win: false }, { ic: "↗", t: `Ends above ${k}`, a: -cost, win: false }];
  const tx = (h?: string) => (h && props.explorer ? <a href={`${props.explorer}/tx/${h}`} target="_blank" rel="noreferrer">{h.slice(0, 10)}…</a> : h ? <span>{h.slice(0, 10)}…</span> : null);

  return createPortal(
    <div className="scrim" role="dialog" aria-modal="true" aria-label="Confirm position" onMouseDown={(e) => { if (e.target === e.currentTarget && !busy) props.onClose(); }} onKeyDown={(e) => { if (e.key === "Escape" && !busy) props.onClose(); }}>
      <div className="sheet">
        <div className="card">
          <div className="sheet-head"><span>Your position</span><button className="btn" style={{ padding: "5px 12px" }} disabled={busy} onClick={props.onClose}>Edit</button></div>
          <div className="pos-title">
            Make <mark>{usd(payout)}</mark> if {sym} ends {above ? "above" : "below"} <mark className="g">{k}</mark> by <mark className="v">{fullDate(series.expiry)}</mark>
          </div>
          <div className="outcomes">
            {rows.map((r) => (
              <div key={r.t} className={`outcome ${r.win ? "win" : "lose"}`}><span className="ic" aria-hidden="true">{r.ic}</span><span>{r.t}</span><span className="a">{r.a >= 0 ? "+" : "−"}{usd(Math.abs(r.a))}</span></div>
            ))}
          </div>
          <p className="chartlbl">Profit or loss by {sym} price on {fullDate(series.expiry)} · hover the bars</p>
          <PayoffChart strike={series.strike} spot={spot} payout={payout} cost={cost} yes={above} height={170} />
          <button className="expander" onClick={() => setMore((m) => !m)} aria-expanded={more}><span>Contracts</span><span>{more ? "−" : "+"}</span></button>
          {more && (
            <dl className="kv">
              <div><dt>Contracts</dt><dd>{contracts.toLocaleString()} × $1</dd></div>
              <div><dt>Average price</dt><dd>{quote?.avgTick ?? "—"}¢</dd></div>
              <div><dt>Worst fill</dt><dd>{quote?.worstTick ?? "—"}¢ · limit {maxTick}¢</dd></div>
              <div><dt>Slippage</dt><dd><span className="seg" style={{ gap: 4 }}>{[0, 1, 2, 5].map((n) => <button key={n} className={n === slip ? "sel" : ""} style={{ padding: "4px 10px", borderRadius: 999 }} onClick={() => props.onSlip(n)}>{n === 0 ? "None" : `${n}¢`}</button>)}</span></dd></div>
            </dl>
          )}
        </div>
        <div className="card">
          {!res ? (
            <>
              <dl className="kv">
                <div><dt>Wallet</dt><dd className="mono">{short(props.address)}</dd></div>
                <div><dt>Contracts</dt><dd>{contracts.toLocaleString()}</dd></div>
                <div><dt>Maximum cost</dt><dd>{usd(cost, 2)}</dd></div>
                <div><dt>Maximum profit</dt><dd className="pos">{usd(profit, 2)}</dd></div>
                <div><dt>Maximum loss</dt><dd className="neg">{usd(cost, 2)}</dd></div>
                <div><dt>Protocol fee</dt><dd>$0 · gas only</dd></div>
                <div><dt>Expires</dt><dd>{fullDate(series.expiry)}</dd></div>
                <div><dt>Settlement</dt><dd>{mock ? "Cash · 60 s TWAP of its onchain pool" : "Cash · Pyth first price at expiry"}</dd></div>
              </dl>
              {moved && <div className="banner" style={{ position: "static", borderRadius: 12, marginTop: 10 }} role="alert">Price moved {usd(moved.from, 2)} → {usd(moved.to, 2)}. Confirm again.</div>}
              <label className="check"><input type="checkbox" checked={ok} onChange={(e) => setOk(e.target.checked)} />
                <span>I understand this {mock ? "testnet" : realMoney ? "real-money" : ""} binary pays $1 per contract or nothing, settles in cash onchain, and that I can lose the full {usd(cost, 2)}. The software is unaudited.</span>
              </label>
              {steps.length > 0 && <div className="steps">{steps.map((s) => (
                <div key={s.label} className={`step ${s.state}`}><span className="ic">{s.state === "done" ? "✓" : s.state === "error" ? "!" : ""}</span>{s.label}{s.hash && tx(s.hash)}</div>
              ))}</div>}
              <button className="cta" style={{ width: "100%", marginTop: 6 }} disabled={!ok || busy || !quote || quote.filled === 0} onClick={go}>
                {busy ? "Confirming…" : !ok ? `Tick the box to pay ${usd(cost, 2)}` : moved ? `Confirm ${usd(cost, 2)}` : `Confirm and pay ${usd(cost, 2)}`}
              </button>
            </>
          ) : res.ok ? (
            <div className="success">
              <svg className="check-draw" viewBox="0 0 64 64" aria-hidden="true"><circle cx="32" cy="32" r="30" /><path d="M19 33l9 9 17-19" /></svg>
              <div className="subnote">Filled</div>
              <div className="big">{res.filled.toLocaleString()} contracts</div>
              <p className="subnote">Paid {usd(res.cost, 2)}</p>
              {res.hash && <p className="addr">{tx(res.hash)}</p>}
              <button className="cta" style={{ width: "100%", marginTop: 8 }} onClick={props.onClose}>Done</button>
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

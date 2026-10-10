import { useEffect, useMemo, useRef, useState } from "react";
import type { AccountView, ChainInfo, Quote, SeriesView, WalletState } from "../api/types";
import { AssetPicker } from "../components/AssetPicker";
import { BookLadder, BookSkeleton } from "../components/BookLadder";
import { Num, Skel } from "../components/Motion";
import { ConfirmSheet } from "../components/ConfirmSheet";
import { dayText, price, pct, usd, whenText, untilText } from "../lib/format";
import { PillPopover, useApi, useDockAction, useNow, usePoll } from "../lib/hooks";

const nearest = <T,>(xs: T[], f: (x: T) => number, target: number): T | undefined =>
  xs.reduce<T | undefined>((best, x) => (best === undefined || Math.abs(f(x) - target) < Math.abs(f(best) - target) ? x : best), undefined);
const signed = (p: number, dp = 0) => `${p >= 0 ? "↑" : "↓"}${Math.abs(p * 100).toFixed(dp)}%`;
const Chev = () => <svg className="chev" viewBox="0 0 12 8" width="1em" height="1em" aria-hidden="true"><path d="M1.5 1.5L6 6l4.5-4.5" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" /></svg>;

export function TradeView(props: { account?: AccountView; wallet?: WalletState; info?: ChainInfo; onNeedConnect: () => Promise<void>; onToast: (m: string) => void }) {
  const api = useApi();
  const now = useNow(1000);
  const assets = usePoll(() => api.assets(), [api], 2500);
  const [sym, setSym] = useState("MON");
  const series = usePoll(() => api.seriesFor(sym), [api, sym], 4000);
  const [above, setAbove] = useState(true);
  const [payout, setPayout] = useState(1000);
  const [expiry, setExpiry] = useState<number>();
  const [strike, setStrike] = useState<number>();
  const [confirm, setConfirm] = useState(false);
  const [showBook, setShowBook] = useState(false);
  const [slip, setSlip] = useState(() => { try { return Number(localStorage.getItem("montions.slip") ?? 1); } catch { return 1; } });
  const setSlipSaved = (n: number) => { setSlip(n); try { localStorage.setItem("montions.slip", String(n)); } catch { /* private mode */ } };

  // Start on an asset that actually has resting orders (until the user picks one themselves).
  const picked = useRef(false);
  useEffect(() => {
    if (picked.current || !assets?.length) return;
    const cur = assets.find((a) => a.symbol === sym);
    if (cur && (cur.liquid ?? 0) > 0) { picked.current = true; return; }
    const best = [...assets].filter((a) => !a.stale && (a.liquid ?? 0) > 0).sort((x, y) => (y.liquid ?? 0) - (x.liquid ?? 0))[0];
    if (best) { picked.current = true; setSym(best.symbol); setStrike(undefined); setExpiry(undefined); }
  }, [assets, sym]);
  const asset = assets?.find((a) => a.symbol === sym);
  const spot = asset?.spot ?? 1;

  const open = useMemo(() => (series ?? []).filter((s) => s.status === "open" && s.expiry > now + 60), [series, Math.floor(now / 30)]);
  const expiries = useMemo(() => [...new Set(open.map((s) => s.expiry))].sort((a, b) => a - b), [open]);
  const none = series !== undefined && open.length === 0;   // loaded, but nothing open for this asset

  // default selections once data arrives / asset changes
  useEffect(() => {
    if (!expiries.length) return;
    if (expiry === undefined || !expiries.includes(expiry)) {
      const liquid = (e: number) => open.some((x) => x.expiry === e && (above ? x.askQty > 0 : x.bidQty > 0));
      const day = expiries.find((e) => e - now > 20 * 3600 && liquid(e));
      setExpiry(day ?? expiries.find(liquid) ?? expiries.find((e) => e - now > 20 * 3600) ?? expiries[expiries.length - 1]);
    }
  }, [expiries, expiry]);
  const atExpiry = useMemo(() => open.filter((s) => s.expiry === expiry).sort((a, b) => a.strike - b.strike), [open, expiry]);
  useEffect(() => {
    if (!atExpiry.length) return;
    if (strike === undefined || !atExpiry.some((s) => s.strike === strike)) {
      // default to the strike (with resting liquidity if any) whose chance of paying is closest to 30%
      const liquid = atExpiry.filter((s) => (above ? s.askQty > 0 : s.bidQty > 0));
      setStrike(nearest(liquid.length ? liquid : atExpiry, (s) => (above ? s.fairProb : 1 - s.fairProb), 0.3)?.strike);
    }
  }, [atExpiry, strike, spot, above]);

  const selected: SeriesView | undefined = atExpiry.find((s) => s.strike === strike);
  const chanceOf = (s?: SeriesView) => (s ? (above ? s.fairProb : 1 - s.fairProb) : 0);

  const contracts = Math.max(1, Math.ceil(payout));
  const [quote, setQuote] = useState<Quote>();
  useEffect(() => {
    if (!selected) return;
    let alive = true;
    const t = setTimeout(async () => { const q = await api.quoteBuy(selected.id, above, contracts); if (alive) setQuote(q); }, 150);
    const iv = setInterval(async () => { const q = await api.quoteBuy(selected.id, above, contracts); if (alive) setQuote(q); }, 3000);
    return () => { alive = false; clearTimeout(t); clearInterval(iv); };
  }, [api, selected?.id, above, contracts]);

  const depth = usePoll(() => (selected && showBook ? api.depth(selected.id) : Promise.resolve(undefined)), [api, selected?.id, showBook], 2000);
  const trades = usePoll(() => (selected && showBook ? api.trades(selected.id) : Promise.resolve([])), [api, selected?.id, showBook], 5000);

  const cost = quote?.cost ?? 0;
  // When the book is thinner than the request, the order fills what is there (IOC), so the sheet shows that amount.
  const fillable = quote && quote.filled > 0 && !quote.complete ? quote.filled : contracts;
  const profit = fillable - cost;
  const chance = chanceOf(selected);
  const strikePct = spot ? (strike ?? spot) / spot - 1 : 0;

  const tradingBlocked = !!props.info?.paused || !!props.wallet?.wrongNetwork || !!asset?.stale || (selected ? selected.expiry <= now + 30 : false);
  const canBuy = !!selected && !!quote && quote.filled > 0 && !tradingBlocked;
  const buy = async () => {
    if (!props.account?.address) { await props.onNeedConnect(); return; }
    setConfirm(true);
  };
  useDockAction(none ? undefined : { label: `Buy for ${selected && quote ? usd(cost, cost < 100 ? 2 : 0) : "—"}`, disabled: !canBuy, onClick: buy },
    [none, canBuy, cost, selected?.id, props.account?.address]);

  // strike popover: typed value snaps to the nearest listed strike
  const [typed, setTyped] = useState<string>();
  const strikeIdx = Math.max(0, atExpiry.findIndex((s) => s.strike === strike));
  const snap = (v: number) => { const s = nearest(atExpiry, (x) => x.strike, v); if (s) setStrike(s.strike); setTyped(undefined); };
  const payoutPos = Math.round((Math.log10(Math.max(10, payout) / 10) / Math.log10(10000)) * 100);

  return (
    <div className="trade">
      <div className="eyebrow">
        <span className="tag dark">Binary</span>
        {asset && spot > 0 && <span className="tag soft" title={asset.mock ? "Settles on the 60-second TWAP of its onchain pool" : "Settles on Pyth's first price at expiry"}><span className={`dot ${asset.stale ? "warn" : ""}`} />{sym} {price(spot)}</span>}
        <span className="sp" />
        <button className="toplink" onClick={() => setShowBook((b) => !b)} aria-pressed={showBook}>▤ Book</button>
      </div>

      <h1 className="sentence">
        <span className="w">I want to make </span>
        <PillPopover pill={(o, t) => <button className={`pill amber ${o ? "open" : ""}`} onClick={t}><span className="pv" key={payout}>{usd(payout)}</span><Chev /></button>}>
          {() => (
            <div>
              <div className="pop-title">How much do you want to make?</div>
              <div className="big-input"><span>$</span>
                <input inputMode="numeric" autoFocus value={payout} onChange={(e) => setPayout(Math.min(1_000_000, Math.max(1, Math.floor(Number(e.target.value.replace(/\D/g, "")) || 1))))} />
                <span className="hint">type or drag</span>
              </div>
              <div className="rangewrap">
                <input className="range" type="range" min={0} max={100} value={payoutPos} style={{ "--fill": `${payoutPos}%`, "--fillc": "var(--amber)" } as React.CSSProperties}
                  onChange={(e) => setPayout(Math.max(10, Math.round(10 * Math.pow(10000, Number(e.target.value) / 100) / 10) * 10))} />
              </div>
              <div className="range-foot"><span>$10</span><b>costs {usd(cost)}</b><span>$100K</span></div>
            </div>
          )}
        </PillPopover>
        <span className="w"> if </span>
        <PillPopover pill={(o, t) => <button className={`pill violet ${o ? "open" : ""}`} onClick={t}><span className="pv" key={sym}>{sym}</span><Chev /></button>}>
          {(close) => <AssetPicker assets={assets ?? []} current={sym} onPick={(symbol) => { picked.current = true; setSym(symbol); setStrike(undefined); setExpiry(undefined); close(); }} />}
        </PillPopover>{" "}
        <PillPopover pill={(o, t) => <button className={`pill salmon ${o ? "open" : ""}`} onClick={t}><span className="pv" key={String(above)}>{above ? "hits" : "stays under"}</span><span className="arrow">{above ? "↗" : "↘"}</span></button>}>
          {(close) => (
            <div>
              <div className="pop-title">Finishes</div>
              <div className="seg">
                <button className={above ? "sel" : ""} onClick={() => { setAbove(true); setStrike(undefined); close(); }}>↗ Hits</button>
                <button className={!above ? "sel" : ""} onClick={() => { setAbove(false); setStrike(undefined); close(); }}>↘ Stays under</button>
              </div>
            </div>
          )}
        </PillPopover>{" "}
        <PillPopover pill={(o, t) => strike ? <button className={`pill yes ${o ? "open" : ""}`} onClick={t}><span className="pv" key={strike}>{price(strike)}</span><small className={strikePct < 0 ? "down" : ""}>{signed(strikePct)}</small><Chev /></button> : none ? <button className="pill yes" onClick={t}>—</button> : <button className="pill yes loading" aria-busy="true"><Skel w="2.6em" h=".62em" r={999} /></button>}>
          {() => (
            <div>
              <div className="pop-title">{sym} reference price {price(spot)}</div>
              <div className="big-input"><span>$</span>
                <input inputMode="decimal" value={typed ?? (strike ? +strike.toPrecision(6) : "")} onChange={(e) => setTyped(e.target.value.replace(/[^\d.]/g, ""))}
                  onBlur={() => typed !== undefined && snap(Number(typed) || spot)} onKeyDown={(e) => { if (e.key === "Enter") snap(Number(typed) || spot); }} />
                <span className="hint">type or drag</span>
              </div>
              {atExpiry.length > 1 && (
                <div className="rangewrap">
                  <span className={`range-chip ${strikePct < 0 ? "down" : ""}`} style={{ left: `calc(17px + (100% - 34px) * ${strikeIdx / (atExpiry.length - 1)})` }}>{signed(strikePct)}</span>
                  <input className="range" type="range" min={0} max={atExpiry.length - 1} step={1} value={strikeIdx} style={{ "--fill": `${(strikeIdx / (atExpiry.length - 1)) * 100}%`, "--fillc": "var(--mint)" } as React.CSSProperties}
                    onChange={(e) => { setStrike(atExpiry[Number(e.target.value)]?.strike); setTyped(undefined); }} />
                </div>
              )}
              <div className="range-foot"><span>{atExpiry[0] ? price(atExpiry[0].strike) : "—"}</span><b>{pct(chance)} chance · {signed(strikePct)} from now</b><span>{atExpiry.length ? price(atExpiry[atExpiry.length - 1]!.strike) : "—"}</span></div>
            </div>
          )}
        </PillPopover>
        <span className="w"> by </span>
        <PillPopover align="right" pill={(o, t) => expiry ? <button className={`pill blue ${o ? "open" : ""}`} onClick={t}><span className="pv" key={expiry}>{dayText(expiry, now)}</span><Chev /></button> : none ? <button className="pill blue" onClick={t}>—</button> : <button className="pill blue loading" aria-busy="true"><Skel w="4.6em" h=".62em" r={999} /></button>}>
          {(close) => (
            <div>
              <div className="pop-title">Expires</div>
              <div className="opt-list">
                {expiries.map((e) => {
                  const s = open.find((x) => x.expiry === e && x.strike === strike);
                  return (
                    <button key={e} className={`opt ${e === expiry ? "sel" : ""}`} onClick={() => { setExpiry(e); close(); }}>
                      <div><div className="l1">{whenText(e)}</div><div className="l2">in {untilText(e, now)}</div></div>
                      <span className={`chance ${chanceOf(s) < 0.25 ? "low" : ""}`}>{s ? pct(chanceOf(s)) : "—"}</span>
                    </button>
                  );
                })}
                {expiries.length === 0 && <div className="subnote" style={{ padding: 12 }}>No open {sym} markets right now.</div>}
              </div>
            </div>
          )}
        </PillPopover>
      </h1>

      <div className="costline">
        <div className="costbox"><span className="lbl">It costs</span><span className="val">{none ? "—" : selected && quote ? <Num value={cost} format={(n) => usd(n, n < 100 ? 2 : 0)} /> : <Skel w={96} h={28} r={10} />}</span></div>
        <div className="chancebox"><b>{none ? "—" : selected ? <Num value={chance * 100} format={(n) => `${Math.round(n)}%`} /> : <Skel w={34} h={14} />}</b> chance it happens</div>
      </div>
      <div className="subnote">
        {none ? `No open ${sym} markets right now. New ones list every week; try another asset.` : !quote ? "Reading the book…" : quote.filled > 0 ? <>Win <b className="pos">{usd(profit)}</b> · lose <b className="neg">{usd(cost)}</b> · settles {asset?.mock ? "on its onchain pool" : "on Pyth"}</> : "No orders here — try another strike or time."}
      </div>
      {quote && quote.filled > 0 && !quote.complete && <div className="warnline" style={{ marginTop: 6 }}>Only {quote.filled.toLocaleString()} of {contracts.toLocaleString()} available right now — you would get {usd(quote.filled)}.</div>}
      {props.info?.paused && <div className="warnline" style={{ marginTop: 6 }}>Trading is paused.</div>}
      {asset?.stale && <div className="warnline" style={{ marginTop: 6 }}>{sym} price feed is stale — trading off. Pick another asset.</div>}

      {showBook && !none && (
        <div className="bookpanel">
          <div className="card">
            <h3>Orderbook <span className="hint">{slip}¢ slippage · <button className="btn ghost" style={{ padding: "0 4px" }} onClick={() => setSlipSaved(slip === 0 ? 1 : slip === 1 ? 2 : slip === 2 ? 5 : 0)}>change</button></span></h3>
            {depth ? <BookLadder bids={depth.bids} asks={depth.asks} fairTick={selected ? Math.round(selected.fairProb * 100) : undefined} lastTick={selected?.lastTick}
              highlight={above && quote?.worstTick ? { side: "ask", worst: quote.worstTick } : undefined} /> : <BookSkeleton />}
          </div>
          <div className="card">
            <h3>Recent trades</h3>
            <div className="tape">{(trades ?? []).length === 0 && <div className="subnote">No trades yet.</div>}{(trades ?? []).slice(0, 8).map((t, i) => (
              <div key={i}><span className={t.takerIsBuyer ? "b" : "s"}>{t.tick}¢ {t.takerIsBuyer ? "buy" : "sell"}</span><span>{t.qty}</span><span className="t">{Math.max(0, Math.floor(now - t.ts))}s</span></div>
            ))}</div>
          </div>
        </div>
      )}

      {confirm && selected && (
        <ConfirmSheet series={selected} sym={sym} spot={spot} above={above} payout={fillable} contracts={fillable} quote={quote} slip={slip} onSlip={setSlipSaved} mock={!!asset?.mock} explorer={props.info?.explorer} network={props.info?.network} address={props.account?.address} onClose={() => setConfirm(false)} />
      )}
    </div>
  );
}

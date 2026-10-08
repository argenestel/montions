import { useEffect, useMemo, useState } from "react";
import type { AccountView, ChainInfo, Quote, SeriesView, WalletState } from "../api/types";
import { AssetPicker } from "../components/AssetPicker";
import { BookLadder, BookSkeleton } from "../components/BookLadder";
import { Num, Skel } from "../components/Motion";
import { ConfirmSheet } from "../components/ConfirmSheet";
import { PayoffChart } from "../components/PayoffChart";
import { price, pct, usd, whenText, untilText, durationLabel } from "../lib/format";
import { PillPopover, useApi, useNow, usePoll } from "../lib/hooks";

const nearest = <T,>(xs: T[], f: (x: T) => number, target: number): T | undefined =>
  xs.reduce<T | undefined>((best, x) => (best === undefined || Math.abs(f(x) - target) < Math.abs(f(best) - target) ? x : best), undefined);

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
  const [slip, setSlip] = useState(() => { try { return Number(localStorage.getItem("montions.slip") ?? 1); } catch { return 1; } });
  const setSlipSaved = (n: number) => { setSlip(n); try { localStorage.setItem("montions.slip", String(n)); } catch { /* private mode */ } };

  const asset = assets?.find((a) => a.symbol === sym);
  const spot = asset?.spot ?? 1;

  const open = useMemo(() => (series ?? []).filter((s) => s.status === "open" && s.expiry > now + 60), [series, Math.floor(now / 30)]);
  const expiries = useMemo(() => [...new Set(open.map((s) => s.expiry))].sort((a, b) => a - b), [open]);

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

  const depth = usePoll(() => (selected ? api.depth(selected.id) : Promise.resolve(undefined)), [api, selected?.id], 2000);
  const trades = usePoll(() => (selected ? api.trades(selected.id) : Promise.resolve([])), [api, selected?.id], 5000);

  const cost = quote?.cost ?? 0;
  const profit = payout - cost;
  const chance = chanceOf(selected);
  const strikePct = spot ? (strike ?? spot) / spot - 1 : 0;

  const tradingBlocked = !!props.info?.paused || !!props.wallet?.wrongNetwork || !!asset?.stale || (selected ? selected.expiry <= now + 30 : false);
  const buy = async () => {
    if (!props.account?.address) { await props.onNeedConnect(); return; }
    setConfirm(true);
  };

  return (
    <div className="trade-grid">
      <section>
        <div className="eyebrow">
          <span className="tag dark">Binary option</span>
          <span className="tag soft">{asset ? `${sym} ${price(spot)}` : "…"}{asset?.mock ? " · DEMO oracle" : " · Pyth"}</span>
          <span className="tag soft">{asset?.mock ? "Settles by 60s TWAP of a demo pool" : "Settles on Pyth's first price at expiry"}</span>
        </div>

        <h1 className="sentence">
          <span className="w">I want to make </span>
          <PillPopover pill={(o, t) => <button className={`pill amber ${o ? "open" : ""}`} onClick={t}>{usd(payout)}<span className="chev">▾</span></button>}>
            {() => (
              <div>
                <div className="pop-title">How much do you want to make?</div>
                <div className="big-input"><span>$</span>
                  <input inputMode="numeric" value={payout} onChange={(e) => setPayout(Math.min(1_000_000, Math.max(1, Math.floor(Number(e.target.value.replace(/\D/g, "")) || 1))))} />
                </div>
                <input className="range" type="range" min={0} max={100} value={Math.round((Math.log10(payout / 10) / Math.log10(10000)) * 100)}
                  onChange={(e) => setPayout(Math.max(10, Math.round(10 * Math.pow(10000, Number(e.target.value) / 100) / 10) * 10))} />
                <div className="range-foot"><span>$10</span><span>costs {usd(cost)}</span><span>$100K</span></div>
              </div>
            )}
          </PillPopover>
          <span className="w"> if </span>
          <PillPopover pill={(o, t) => <button className={`pill violet ${o ? "open" : ""}`} onClick={t}>{sym}<span className="chev">▾</span></button>}>
            {(close) => <AssetPicker assets={assets ?? []} current={sym} onPick={(symbol) => { setSym(symbol); setStrike(undefined); setExpiry(undefined); close(); }} />}
          </PillPopover>{" "}
          <PillPopover pill={(o, t) => <button className={`pill ${above ? "yes" : "no"} ${o ? "open" : ""}`} onClick={t}>ends {above ? "above" : "below"}<span className="chev">▾</span></button>}>
            {(close) => (
              <div>
                <div className="pop-title">Where do you think it finishes?</div>
                <div className="seg">
                  <button className={`yes ${above ? "sel" : ""}`} onClick={() => { setAbove(true); setStrike(undefined); close(); }}>↗ Above</button>
                  <button className={`no ${!above ? "sel" : ""}`} onClick={() => { setAbove(false); setStrike(undefined); close(); }}>↘ Below</button>
                </div>
                <div className="subnote" style={{ marginTop: 10 }}>“Below” buys the NO side of the same onchain book — one liquidity pool for both directions.</div>
              </div>
            )}
          </PillPopover>{" "}
          <PillPopover pill={(o, t) => strike ? <button className={`pill yes ${o ? "open" : ""}`} onClick={t}>{price(strike)}<small>{strikePct >= 0 ? "↑" : "↓"}{Math.abs(strikePct * 100).toFixed(0)}%</small><span className="chev">▾</span></button> : <button className="pill yes loading" aria-busy="true"><Skel w="2.6em" h=".62em" r={999} /></button>}>
            {(close) => (
              <div>
                <div className="pop-title">{sym} reference price {price(spot)}</div>
                <div className="opt-list">
                  {atExpiry.map((s) => (
                    <button key={s.id} className={`opt ${s.strike === strike ? "sel" : ""}`} onClick={() => { setStrike(s.strike); close(); }}>
                      <div><div className="l1">{price(s.strike)}</div><div className="l2">{s.strike >= spot ? "↑" : "↓"} {Math.abs((s.strike / spot - 1) * 100).toFixed(0)}% from now</div></div>
                      <span className={`chance ${chanceOf(s) < 0.25 ? "low" : ""}`}>{pct(chanceOf(s))}</span>
                    </button>
                  ))}
                </div>
              </div>
            )}
          </PillPopover>
          <span className="w"> by </span>
          <PillPopover align="right" pill={(o, t) => expiry ? <button className={`pill blue ${o ? "open" : ""}`} onClick={t}>{whenText(expiry).replace(/,/g, "")}<span className="chev">▾</span></button> : <button className="pill blue loading" aria-busy="true"><Skel w="4.6em" h=".62em" r={999} /></button>}>
            {(close) => (
              <div>
                <div className="pop-title">Pick an expiry (60s TWAP at that moment decides)</div>
                <div className="opt-list">
                  {expiries.map((e) => {
                    const s = open.find((x) => x.expiry === e && x.strike === strike);
                    return (
                      <button key={e} className={`opt ${e === expiry ? "sel" : ""}`} onClick={() => { setExpiry(e); close(); }}>
                        <div><div className="l1">{whenText(e)}</div><div className="l2">in {untilText(e, now)} · {durationLabel(e, now)}</div></div>
                        <span className={`chance ${chanceOf(s) < 0.25 ? "low" : ""}`}>{s ? pct(chanceOf(s)) : "—"}</span>
                      </button>
                    );
                  })}
                </div>
              </div>
            )}
          </PillPopover>
        </h1>

        <div className="costline">
          <div className="costbox"><span className="lbl">It costs</span><span className="val">{selected && quote ? <Num value={cost} format={(n) => usd(n, n < 100 ? 2 : 0)} /> : <Skel w={104} h={30} r={10} />}</span></div>
          <div className="chancebox"><b>{selected ? <Num value={chance * 100} format={(n) => `${Math.round(n)}%`} /> : <Skel w={34} h={14} />}</b> chance it happens <span style={{ color: "var(--faint)" }}>· model</span></div>
        </div>
        <div className="subnote">
          {!quote ? "Reading the onchain book…" : quote.filled > 0 ? <>Fills against the onchain book · avg {quote.avgTick}¢ per $1 · you win {usd(profit)} if it happens, lose {usd(cost)} if not.</> : "No resting orders on this market yet — try another strike or expiry."}
        </div>
        {quote && quote.filled > 0 && !quote.complete && <div className="warnline" style={{ marginTop: 6 }}>Only {quote.filled.toLocaleString()} of {contracts.toLocaleString()} contracts are available right now — lower the amount to fill completely.</div>}

        <div className="cta-row">
          <button className="cta" disabled={!selected || !quote || quote.filled === 0 || tradingBlocked} onClick={buy}>
            {props.account?.address ? "Buy for" : "Connect & buy for"} {selected ? usd(cost, cost < 100 ? 2 : 0) : "—"} <span>→</span>
          </button>
          <PillPopover pill={(o, t) => <button className={`btn ghost ${o ? "open" : ""}`} onClick={t} aria-label="Slippage tolerance">Slippage {slip}¢ ▾</button>}>
            {(close) => (
              <div>
                <div className="pop-title">You won't pay more than this much above the quoted price (per $1 of payout).</div>
                <div className="seg">{[0, 1, 2, 5].map((n) => <button key={n} className={`${n === slip ? "sel yes" : ""}`} onClick={() => { setSlipSaved(n); close(); }}>{n === 0 ? "None" : `${n}¢`}</button>)}</div>
              </div>
            )}
          </PillPopover>
          {!props.account?.address && <span className="subnote">{props.info?.network === "mainnet" ? "Connect a wallet to trade." : "Connect a wallet to trade (test USDC faucet included)."}</span>}
          {props.info?.paused && <span className="warnline">Trading is paused.</span>}
          {asset?.stale && <span className="warnline">{sym}'s price feed isn't updating right now, so trading is disabled for it. Pick another asset.</span>}
        </div>

        <div className="chartwrap card">
          <h3>Profit / loss at expiry <span className="hint">hover to inspect</span></h3>
          {selected && quote ? <PayoffChart strike={selected.strike} spot={spot} payout={payout} cost={cost} yes={above} /> : <Skel w="100%" h={210} r={14} />}
        </div>
      </section>

      <aside>
        <div className="card">
          <h3>Live orderbook <span className="hint">100% onchain CLOB</span></h3>
          {depth ? <BookLadder bids={depth.bids} asks={depth.asks} fairTick={selected ? Math.round(selected.fairProb * 100) : undefined} lastTick={selected?.lastTick}
            highlight={above && quote?.worstTick ? { side: "ask", worst: quote.worstTick } : undefined} /> : <BookSkeleton />}
          <div className="onchain-note">ⓘ Orders match by price-time priority inside <span className="mono">MontionsBook</span>. No matcher, no indexer, no signed quotes.</div>
        </div>
        <div className="card">
          <h3>Recent trades</h3>
          <div className="tape">{(trades ?? []).slice(0, 10).map((t, i) => (
            <div key={i}><span className={t.takerIsBuyer ? "b" : "s"}>{t.tick}¢ {t.takerIsBuyer ? "buy" : "sell"}</span><span>{t.qty}</span><span className="t">{Math.max(0, Math.floor(now - t.ts))}s</span></div>
          ))}</div>
        </div>
      </aside>

      {confirm && selected && (
        <ConfirmSheet series={selected} sym={sym} spot={spot} above={above} payout={payout} contracts={contracts} quote={quote} slip={slip} mock={!!asset?.mock} explorer={props.info?.explorer} network={props.info?.network} onClose={() => setConfirm(false)} />
      )}
    </div>
  );
}

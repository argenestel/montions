import { useState } from "react";
import type { AccountView, ChainInfo } from "../api/types";
import { Skel } from "../components/Motion";
import { short, usd, whenText } from "../lib/format";
import { useApi, usePoll } from "../lib/hooks";

/** Activity boards read straight from the Book's views: no indexer. Traders are ranked by orders placed; markets by collateral locked. */
export function LeaderboardView(props: { account?: AccountView; info?: ChainInfo }) {
  const api = useApi();
  const [tab, setTab] = useState<"traders" | "markets">("traders");
  const lb = usePoll(() => api.leaderboard(), [api], 20_000);
  const me = props.account?.address?.toLowerCase();
  const vault = props.info?.contracts?.find((c) => c.name === "vault")?.address.toLowerCase();   // the market maker is not a trader to rank
  const link = (a: string) => (props.info?.explorer ? `${props.info.explorer}/address/${a}` : undefined);
  return (
    <div>
      <h1 className="page-title">Leaderboard</h1>
      <div className="seg" style={{ maxWidth: 320, marginBottom: 16 }}>
        <button className={tab === "traders" ? "sel yes" : ""} onClick={() => setTab("traders")}>Traders</button>
        <button className={tab === "markets" ? "sel yes" : ""} onClick={() => setTab("markets")}>Markets</button>
      </div>
      {!lb ? <div className="rows">{[0, 1, 2, 3, 4].map((i) => <Skel key={i} w="100%" h={64} r={16} />)}</div> : tab === "traders" ? (
        <div className="rows lb">
          {lb.traders.filter((t) => t.address.toLowerCase() !== vault).length === 0 && <div className="empty">No trades yet.</div>}
          {lb.traders.filter((t) => t.address.toLowerCase() !== vault).map((t, i) => (
            <div key={t.address} className={`rowcard ${t.address.toLowerCase() === me ? "acct on" : ""}`}>
              <div className="lb-rank">{i + 1}</div>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div className="ttl mono">{link(t.address) ? <a href={link(t.address)} target="_blank" rel="noreferrer">{short(t.address)}</a> : short(t.address)}{t.address.toLowerCase() === me && <span className="badge" style={{ marginLeft: 8 }}>you</span>}</div>
                <div className="meta">{t.markets} market{t.markets === 1 ? "" : "s"} · {t.open} open</div>
              </div>
              <div className="amt">{t.orders.toLocaleString()}<div className="meta">orders</div></div>
              <div className="amt">{t.held.toLocaleString()}<div className="meta">held</div></div>
            </div>
          ))}
        </div>
      ) : (
        <div className="rows lb">
          {lb.markets.length === 0 && <div className="empty">No markets yet.</div>}
          {lb.markets.map((m, i) => (
            <div key={m.seriesId} className="rowcard">
              <div className="lb-rank">{i + 1}</div>
              <div style={{ flex: 1, minWidth: 0 }}>
                <div className="ttl">{m.title || m.assetSymbol}</div>
                <div className="meta">{whenText(m.expiry)}</div>
              </div>
              <div className="amt">{usd(m.pool)}<div className="meta">locked</div></div>
              <div className="amt">{m.trades}<div className="meta">trades</div></div>
            </div>
          ))}
        </div>
      )}
      {lb && lb.ordersTotal > lb.ordersScanned && <p className="subnote" style={{ marginTop: 10 }}>Latest {lb.ordersScanned.toLocaleString()} of {lb.ordersTotal.toLocaleString()} orders.</p>}
    </div>
  );
}

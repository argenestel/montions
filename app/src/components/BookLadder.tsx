import type { Level } from "../api/types";
import { Skel, useFlash } from "./Motion";

function Row(props: { l: Level; side: "ask" | "bid"; max: number; mine: boolean }) {
  const { l, side, max, mine } = props;
  const f = useFlash(l.qty);
  return (
    <div className={`book-row ${side} ${mine ? "mine" : ""} ${f ? `flash-${f}` : ""}`}>
      <div className="bar" style={{ width: `${Math.max(2, (l.qty / max) * 100)}%` }} />
      <span className="px">{l.tick}¢</span>
      <span />
      <span className="sz">{l.qty.toLocaleString()}</span>
    </div>
  );
}

/** Live YES order book from the onchain CLOB. Prices in cents (ticks); NO price = 100 − YES price. */
export function BookLadder(props: { bids: Level[]; asks: Level[]; fairTick?: number; lastTick?: number; highlight?: { side: "ask" | "bid"; worst: number } }) {
  const { bids, asks, fairTick, lastTick, highlight } = props;
  const max = Math.max(1, ...bids.map((b) => b.qty), ...asks.map((a) => a.qty));
  const asksTop = [...asks].sort((a, b) => b.tick - a.tick); // highest first, best ask at the bottom
  const bestBid = bids[0]?.tick, bestAsk = asks[0]?.tick;
  const spread = bestBid && bestAsk ? bestAsk - bestBid : undefined;
  const mine = (side: "ask" | "bid", tick: number) => !!highlight && highlight.side === side && (side === "ask" ? tick <= highlight.worst : tick >= highlight.worst);
  const empty = bids.length === 0 && asks.length === 0;
  return (
    <div className="book">
      <div className="book-head"><span>YES price</span><span /><span style={{ textAlign: "right" }}>contracts</span></div>
      {empty && <div className="empty" style={{ margin: "10px 0", padding: 18 }}>No resting orders yet — the maker vault quotes shortly before and after each refresh.</div>}
      {asksTop.map((l) => <Row key={`a${l.tick}`} l={l} side="ask" max={max} mine={mine("ask", l.tick)} />)}
      <div className="book-mid">
        <span>last <b>{lastTick ? `${lastTick}¢` : "—"}</b></span>
        <span className="fair">model {fairTick ? `${fairTick}¢` : "—"}</span>
        <span>spread {spread ?? "—"}¢</span>
      </div>
      {bids.map((l) => <Row key={`b${l.tick}`} l={l} side="bid" max={max} mine={mine("bid", l.tick)} />)}
    </div>
  );
}

export function BookSkeleton() {
  return (
    <div className="book" aria-busy="true">
      <div className="book-head"><span>YES price</span><span /><span style={{ textAlign: "right" }}>contracts</span></div>
      {Array.from({ length: 9 }).map((_, i) => (
        <div key={i} className="book-row"><Skel w={34} h={12} /><span /><span style={{ justifySelf: "end" }}><Skel w={44 + ((i * 17) % 26)} h={12} /></span></div>
      ))}
    </div>
  );
}

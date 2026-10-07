import type { Level } from "../api/types";

/** Live YES order book from the onchain CLOB. Prices in cents (ticks); NO price = 100 − YES price. */
export function BookLadder(props: { bids: Level[]; asks: Level[]; fairTick?: number; lastTick?: number; highlight?: { side: "ask" | "bid"; worst: number } }) {
  const { bids, asks, fairTick, lastTick, highlight } = props;
  const max = Math.max(1, ...bids.map((b) => b.qty), ...asks.map((a) => a.qty));
  const asksTop = [...asks].sort((a, b) => b.tick - a.tick); // highest first, best ask at the bottom
  const bestBid = bids[0]?.tick, bestAsk = asks[0]?.tick;
  const spread = bestBid && bestAsk ? bestAsk - bestBid : undefined;
  const row = (l: Level, side: "ask" | "bid") => (
    <div key={side + l.tick} className={`book-row ${side} ${highlight && highlight.side === side && (side === "ask" ? l.tick <= highlight.worst : l.tick >= highlight.worst) ? "mine" : ""}`}>
      <div className="bar" style={{ width: `${(l.qty / max) * 100}%` }} />
      <span className="px">{l.tick}¢</span>
      <span />
      <span className="sz">{l.qty.toLocaleString()}</span>
    </div>
  );
  return (
    <div className="book">
      <div className="book-head"><span>YES price</span><span /><span style={{ textAlign: "right" }}>contracts</span></div>
      {asksTop.map((l) => row(l, "ask"))}
      <div className="book-mid">
        <span>last <b>{lastTick ? `${lastTick}¢` : "—"}</b></span>
        <span className="fair">model {fairTick ? `${fairTick}¢` : "—"}</span>
        <span>spread {spread ?? "—"}¢</span>
      </div>
      {bids.map((l) => row(l, "bid"))}
    </div>
  );
}

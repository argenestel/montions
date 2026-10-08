import { useState } from "react";
import type { AccountView } from "../api/types";
import { price, usd, whenText } from "../lib/format";
import { useApi, usePoll } from "../lib/hooks";

export function PositionsView(props: { account?: AccountView; onChanged: () => void }) {
  const api = useApi();
  const [tick, setTick] = useState(0);
  const positions = usePoll(() => api.positions(), [api, tick], 3000);
  const orders = usePoll(() => api.orders(), [api, tick], 3000);
  return (
    <div>
      <h1 className="page-title">Positions</h1>
      {props.account?.address && (
        <div className="stats">
          <div className="stat"><div className="k">Wallet</div><div className="v">{usd(props.account.usdc)}</div></div>
          <div className="stat"><div className="k">In book</div><div className="v">{usd(props.account.bookCash)}</div></div>
          <div className="stat"><div className="k">In orders</div><div className="v">{usd(props.account.locked)}</div></div>
        </div>
      )}
      <div className="rows">
        {(positions ?? []).length === 0 && <div className="empty">No positions yet.</div>}
        {(positions ?? []).map((p) => (
          <div key={p.seriesId} className="rowcard">
            <div><div className="ttl">{p.assetSymbol} {p.yesQty > 0 ? "above" : "below"} {price(p.strike)}</div>
              <div className="meta">{whenText(p.expiry)} · {(p.yesQty > 0 ? p.yesQty : p.noQty).toLocaleString()}× · {p.status}</div></div>
            <div className="amt">{usd(p.markValue, 2)}<div className="meta">mark</div>
              {p.status !== "open" && <button className="btn primary" onClick={async () => { await api.redeem(p.seriesId); setTick((t) => t + 1); props.onChanged(); }}>Redeem</button>}</div>
          </div>
        ))}
      </div>
      <h3 style={{ margin: "30px 0 12px", color: "var(--muted)", fontSize: 13, letterSpacing: ".08em", textTransform: "uppercase" }}>Open orders</h3>
      <div className="rows">
        {(orders ?? []).length === 0 && <div className="empty">None.</div>}
        {(orders ?? []).map((o) => (
          <div key={o.id} className="rowcard">
            <div><div className="ttl">{o.side === "bid" ? "Buy YES" : o.fromHeld ? "Sell YES" : "Write"} @ {o.tick}¢</div><div className="meta">{o.title} · {o.qty} contracts</div></div>
            <div className="amt"><button className="btn" onClick={async () => { await api.cancel(o.id); setTick((t) => t + 1); }}>Cancel</button></div>
          </div>
        ))}
      </div>
    </div>
  );
}

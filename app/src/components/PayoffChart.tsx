import { useMemo, useState } from "react";
import { price, usd } from "../lib/format";

/** Step payoff chart: P&L at expiry vs underlying price for a digital (cash-or-nothing) position. Rounded bars, green above zero, red below. */
export function PayoffChart(props: { strike: number; spot: number; payout: number; cost: number; yes: boolean; height?: number }) {
  const { strike, spot, payout, cost, yes } = props;
  const W = 560, H = props.height ?? 190, padL = 6, padR = 6, padT = 26, padB = 26;
  const lo = Math.min(spot, strike) * 0.8, hi = Math.max(spot, strike) * 1.2;
  const profit = payout - cost;
  const yMax = Math.max(profit, cost) * 1.1 || 1;
  const x = (p: number) => padL + ((p - lo) / (hi - lo)) * (W - padL - padR);
  const y = (v: number) => padT + ((yMax - v) / (2 * yMax)) * (H - padT - padB);
  const win = (p: number) => (yes ? p >= strike : p < strike);
  const pnl = (p: number) => (win(p) ? profit : -cost);
  const [hover, setHover] = useState<number | null>(null);

  const bars = useMemo(() => {
    const n = 22; const out: { px: number; v: number }[] = [];
    for (let i = 0; i < n; i++) { const p = lo + ((i + 0.5) / n) * (hi - lo); out.push({ px: p, v: pnl(p) }); }
    return out;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [lo, hi, strike, profit, cost, yes]);

  const bw = ((W - padL - padR) / bars.length) * 0.72;
  const hp = hover ?? spot;
  return (
    <svg className="chart" viewBox={`0 0 ${W} ${H}`} role="img" aria-label="Profit and loss at expiry"
      onMouseMove={(e) => {
        const r = (e.currentTarget as SVGSVGElement).getBoundingClientRect();
        const fx = ((e.clientX - r.left) / r.width) * W;
        setHover(lo + ((fx - padL) / (W - padL - padR)) * (hi - lo));
      }}
      onMouseLeave={() => setHover(null)}>
      <g key={`${strike}-${yes}`}>
        {bars.map((b, i) => {
          const top = Math.min(y(b.v), y(0)), h = Math.max(3, Math.abs(y(b.v) - y(0)));
          return <rect key={i} className={`bar ${b.v >= 0 ? "pos" : "neg"}`} x={x(b.px) - bw / 2} width={bw} rx={bw / 2}
            style={{ y: top, height: h, animationDelay: `${i * 12}ms`, opacity: hover != null && Math.abs(b.px - hp) > (hi - lo) / 22 ? 0.45 : 1 }}
            fill={b.v >= 0 ? "#bfe9cc" : "#f7c9c0"} />;
        })}
      </g>
      <line x1={padL} x2={W - padR} y1={y(0)} y2={y(0)} stroke="rgba(20,18,14,.18)" />
      <line x1={x(spot)} x2={x(spot)} y1={padT + 2} y2={H - padB} stroke="rgba(20,18,14,.35)" strokeDasharray="2 4" />
      <text x={padL} y={H - 6}>{price(lo)}</text>
      <text x={x(strike)} y={H - 6} textAnchor="middle" style={{ fill: "#141413", fontWeight: 600 }}>{price(strike)}</text>
      <text x={W - padR} y={H - 6} textAnchor="end">{price(hi)}</text>
      <g className="tip" style={{ transform: `translate(${Math.min(Math.max(x(hp), 78), W - 78)}px,2px)` }}>
        <rect x={-74} y={-1} width={148} height={22} rx={11} fill="#171716" />
        <text textAnchor="middle" y={14} style={{ fill: "#fff", fontWeight: 600 }}>
          {hover == null ? "now " : ""}{price(hp)} → {pnl(hp) >= 0 ? "+" : "−"}{usd(Math.abs(pnl(hp)))}
        </text>
      </g>
    </svg>
  );
}

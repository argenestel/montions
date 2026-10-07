import { useMemo, useState } from "react";
import { price, usd } from "../lib/format";

/** Step payoff chart: P&L at expiry vs underlying price for a digital (cash-or-nothing) position. */
export function PayoffChart(props: { strike: number; spot: number; payout: number; cost: number; yes: boolean; height?: number }) {
  const { strike, spot, payout, cost, yes } = props;
  const W = 560, H = props.height ?? 210, padL = 8, padR = 8, padT = 22, padB = 28;
  const lo = Math.min(spot, strike) * 0.72, hi = Math.max(spot, strike) * 1.28;
  const profit = payout - cost;
  const yMax = Math.max(profit, cost) * 1.18 || 1;
  const x = (p: number) => padL + ((p - lo) / (hi - lo)) * (W - padL - padR);
  const y = (v: number) => padT + ((yMax - v) / (2 * yMax)) * (H - padT - padB);
  const win = (p: number) => (yes ? p >= strike : p < strike);
  const pnl = (p: number) => (win(p) ? profit : -cost);
  const [hover, setHover] = useState<number | null>(null);

  const bars = useMemo(() => {
    const n = 44; const out: { px: number; v: number }[] = [];
    for (let i = 0; i < n; i++) { const p = lo + ((i + 0.5) / n) * (hi - lo); out.push({ px: p, v: pnl(p) }); }
    return out;
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [lo, hi, strike, profit, cost, yes]);

  const bw = ((W - padL - padR) / bars.length) * 0.78;
  const hp = hover ?? spot;
  return (
    <svg className="chart" viewBox={`0 0 ${W} ${H}`} role="img" aria-label="Profit and loss at expiry"
      onMouseMove={(e) => {
        const r = (e.currentTarget as SVGSVGElement).getBoundingClientRect();
        const fx = ((e.clientX - r.left) / r.width) * W;
        setHover(lo + ((fx - padL) / (W - padL - padR)) * (hi - lo));
      }}
      onMouseLeave={() => setHover(null)}>
      <line x1={padL} x2={W - padR} y1={y(0)} y2={y(0)} stroke="rgba(255,255,255,.18)" />
      {bars.map((b, i) => {
        const top = Math.min(y(b.v), y(0)), h = Math.abs(y(b.v) - y(0));
        return <rect key={i} x={x(b.px) - bw / 2} y={top} width={bw} height={Math.max(2, h)} rx={3}
          fill={b.v >= 0 ? "rgba(111,240,176,.55)" : "rgba(255,123,146,.5)"} opacity={hover != null && Math.abs(b.px - hp) > (hi - lo) / 44 ? 0.55 : 1} />;
      })}
      <line x1={x(strike)} x2={x(strike)} y1={padT - 6} y2={H - padB + 4} stroke="#836ef9" strokeDasharray="4 4" />
      <text x={x(strike)} y={12} textAnchor="middle" style={{ fill: "#b4a8ff" }}>strike {price(strike)}</text>
      <line x1={x(spot)} x2={x(spot)} y1={padT + 8} y2={H - padB} stroke="rgba(255,255,255,.4)" strokeDasharray="2 3" />
      <text x={x(spot)} y={H - 8} textAnchor="middle">now {price(spot)}</text>
      <text x={padL} y={H - 8}>{price(lo)}</text>
      <text x={W - padR} y={H - 8} textAnchor="end">{price(hi)}</text>
      <g transform={`translate(${Math.min(Math.max(x(hp), 70), W - 70)},${padT + 2})`}>
        <rect x={-62} y={-2} width={124} height={22} rx={11} fill="#0f0d1c" stroke="rgba(131,110,249,.4)" />
        <text textAnchor="middle" y={13} style={{ fill: pnl(hp) >= 0 ? "#6ff0b0" : "#ff7b92", fontWeight: 600 }}>
          {price(hp)} → {pnl(hp) >= 0 ? "+" : "−"}{usd(Math.abs(pnl(hp)))}
        </text>
      </g>
    </svg>
  );
}

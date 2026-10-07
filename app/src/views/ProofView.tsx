import { useApi, usePoll } from "../lib/hooks";

const PARTS = [
  { n: "Orderbook", d: "Price-time CLOB, tick bitmaps, FIFO queues, atomic matching and escrow", b: "MontionsBook" },
  { n: "Collateral", d: "Every contract is backed 1:1 — YES + NO = 1 USDC, locked in the Book", b: "MontionsBook" },
  { n: "Settlement", d: "Resolver contracts decide outcomes from onchain facts only", b: "Resolvers" },
  { n: "Oracle", d: "TWAP computed from onchain pool observations — no signed feeds", b: "OracleHub + SpotPool" },
  { n: "Pricing", d: "Fair value N(d2) and realised vol computed in Solidity", b: "PricingLib + Quoter" },
  { n: "Liquidity", d: "Permissionless market-making vault that anyone can refresh", b: "MakerVault" },
  { n: "Data for the UI", d: "Depth, trades, orders, positions served by view functions — no indexer, no logs", b: "Views" },
];

export function ProofView() {
  const api = useApi();
  const info = usePoll(() => api.chainInfo(), [api], 2500);
  return (
    <div>
      <h1 className="page-title">Everything onchain</h1>
      <p className="page-sub">The frontend is a static page. There is no backend, no matching server, no indexer, no signed price feed. Every component below is a contract you can read on the explorer.</p>
      <div className="arch">{PARTS.map((p) => (<div className="a" key={p.n}><h4>{p.n} <span className="badge">ONCHAIN</span></h4><p>{p.d}</p><p className="addr" style={{ marginTop: 6 }}>{p.b}</p></div>))}</div>
      <div className="card">
        <h3>Deployment <span className="hint">{info ? `${info.name} · chain ${info.chainId} · block ${info.block.toLocaleString()}` : "…"}</span></h3>
        <dl className="kv">
          {(info?.contracts ?? []).map((c) => (
            <div key={c.name}><dt>{c.name} <span className="subnote">· {c.role}</span></dt>
              <dd>{info?.mock || !info?.explorer ? <span className="addr">{c.address}</span> : <a className="addr" href={`${info?.explorer}/address/${c.address}`} target="_blank" rel="noreferrer">{c.address}</a>}</dd></div>
          ))}
        </dl>
      </div>
      <div className="card"><h3>How one trade settles</h3>
        <ol className="flow">
          <li><span><b>Sign</b> one tUSDC permit — no approval transaction.</span></li>
          <li><span><b>One multicall</b>: <span className="mono">depositWithPermit + placeOrder</span>.</span></li>
          <li><span>The Book <b>matches</b> your order against resting orders by price-time priority and mints YES/NO against locked collateral.</span></li>
          <li><span>After expiry anyone calls <span className="mono">resolve</span>: the resolver reads the <b>60s TWAP</b> from the onchain pool.</span></li>
          <li><span>Winners <b>redeem</b> $1 per contract. Void after 2 days of oracle failure refunds 50/50.</span></li>
        </ol></div>
    </div>
  );
}

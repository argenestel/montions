import { short } from "../lib/format";
import { useApi, usePoll } from "../lib/hooks";

const PARTS = [
  { n: "Orderbook", d: "Price-time CLOB with atomic matching and escrow", b: "MontionsBook" },
  { n: "Collateral", d: "Every contract backed 1:1 by USDC or AUSD", b: "MontionsBook" },
  { n: "Settlement", d: "Pyth first price at expiry, or a demo TWAP on testnet", b: "Resolvers" },
  { n: "Pricing", d: "Fair value computed in Solidity", b: "Quoter" },
  { n: "Liquidity", d: "Permissionless market-making vault", b: "MakerVault" },
];

export function ProofView() {
  const api = useApi();
  const info = usePoll(() => api.chainInfo(), [api], 2500);
  return (
    <div>
      <h1 className="page-title">Everything onchain</h1>
      <p className="page-sub">No backend, no indexer. The page just reads these contracts.</p>
      <div className="arch">{PARTS.map((p) => (<div className="a" key={p.n}><h4>{p.n}</h4><p>{p.d}</p><p className="addr" style={{ marginTop: 6 }}>{p.b}</p></div>))}</div>
      <div className="card">
        <h3>Deployment <span className="hint">{info ? `${info.name} · chain ${info.chainId} · block ${info.block.toLocaleString()}` : "…"}</span></h3>
        <dl className="kv">
          {(info?.contracts ?? []).map((c) => (
            <div key={c.name}><dt>{c.name} <span className="subnote role">· {c.role}</span></dt>
              <dd>{info?.mock || !info?.explorer ? <span className="addr" title={c.address}>{short(c.address)}</span> : <a className="addr" title={c.address} href={`${info?.explorer}/address/${c.address}`} target="_blank" rel="noreferrer">{short(c.address)}</a>}</dd></div>
          ))}
        </dl>
      </div>
    </div>
  );
}

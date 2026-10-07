import { Component, useEffect, useState, type ReactNode } from "react";
import type { ChainInfo, WalletState } from "../api/types";
import type { Health } from "../lib/health";

export class ErrorBoundary extends Component<{ children: ReactNode }, { err?: Error }> {
  state: { err?: Error } = {};
  static getDerivedStateFromError(err: Error) { return { err }; }
  componentDidCatch(err: Error) { console.error("UI crashed:", err); }
  render() {
    if (!this.state.err) return this.props.children;
    return (
      <div className="app"><main>
        <h1 className="page-title">Something went wrong</h1>
        <p className="page-sub">The page hit an unexpected error. Your funds are not affected — positions and orders live onchain. Reload to continue.</p>
        <button className="btn primary" onClick={() => location.reload()}>Reload</button>
      </main></div>
    );
  }
}

export function Banners(props: { info?: ChainInfo; wallet?: WalletState; health: Health; onSwitch: () => void; onRetry: () => void }) {
  const { info, wallet, health } = props;
  return (
    <>
      {wallet?.wrongNetwork && (
        <div className="banner err" role="alert">Your wallet is on the wrong network (chain {wallet.chainId}). Switch to {info?.name ?? `chain ${wallet.expectedChainId}`} to trade.<button onClick={props.onSwitch}>Switch network</button></div>
      )}
      {info?.paused && <div className="banner" role="status">New trading is paused. You can still cancel orders, withdraw and redeem winnings.</div>}
      {health.failing && <div className="banner err" role="alert">Can't reach the network ({health.lastError}). Showing the last data we have — retrying automatically.<button onClick={props.onRetry}>Retry now</button></div>}
      {info && info.collateralCapUsd !== undefined && info.totalCollateralUsd !== undefined && info.totalCollateralUsd >= info.collateralCapUsd * 0.95 && (
        <div className="banner" role="status">The launch deposit limit is almost full — new deposits may be rejected.</div>
      )}
    </>
  );
}

const RISK_KEY = "montions.risk.v1";
/** First-run disclosure on real-money networks. Acknowledgement is stored locally; trading UI stays behind it. */
export function RiskGate(props: { info?: ChainInfo; children: ReactNode }) {
  const [ok, setOk] = useState(() => { try { return localStorage.getItem(RISK_KEY) === "1"; } catch { return false; } });
  const [checked, setChecked] = useState(false);
  useEffect(() => { /* no-op: keeps hooks order stable */ }, []);
  if (props.info?.network !== "mainnet" || ok) return <>{props.children}</>;
  return (
    <div className="scrim" role="dialog" aria-modal="true" aria-labelledby="risk-title">
      <div className="card" style={{ maxWidth: 560, background: "#14122b" }}>
        <h1 id="risk-title" className="page-title" style={{ fontSize: 28 }}>Before you trade real money</h1>
        <ul className="page-sub" style={{ paddingLeft: 18, margin: "0 0 16px" }}>
          <li>Montions is <b>new, unaudited software</b>. Smart-contract bugs can lose funds. Launch limits cap total deposits.</li>
          <li>Each contract pays $1 if its condition is true at expiry and <b>$0 otherwise</b>. You can lose your entire premium.</li>
          <li>Settlement uses Pyth's signed first price at or after expiry. If no valid price arrives, the market is voided and pays 50/50.</li>
          <li>Collateral is USDC, which its issuer can freeze. Binary options may be restricted where you live — you are responsible for complying with local law.</li>
          <li>Nothing here is financial advice.</li>
        </ul>
        <label className="check"><input type="checkbox" checked={checked} onChange={(e) => setChecked(e.target.checked)} /><span>I understand these risks and that I am solely responsible for my use of this app.</span></label>
        <button className="cta" style={{ width: "100%", justifyContent: "center" }} disabled={!checked} onClick={() => { try { localStorage.setItem(RISK_KEY, "1"); } catch { /* private mode */ } setOk(true); }}>Continue</button>
      </div>
    </div>
  );
}

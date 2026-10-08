import { Component, useEffect, useState, type ReactNode } from "react";
import type { AccountView, ChainInfo, WalletState } from "../api/types";
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

export function Banners(props: { info?: ChainInfo; wallet?: WalletState; account?: AccountView; health: Health; onSwitch: () => void; onRetry: () => void }) {
  const { info, wallet, health, account } = props;
  const lowGas = !!account?.address && account.native < (info?.network === "mainnet" ? 0.5 : 0.3);
  return (
    <>
      {wallet?.wrongNetwork && (
        <div className="banner err" role="alert">Wrong network. Switch to {info?.name ?? `chain ${wallet.expectedChainId}`}.<button onClick={props.onSwitch}>Switch network</button></div>
      )}
      {lowGas && (
        <div className="banner" role="status">Low on MON ({account!.native.toFixed(3)}) — needed for fees.
          <button onClick={() => navigator.clipboard?.writeText(account!.address!)}>Copy my address</button>
          {info?.network === "testnet" && <a href="https://faucet.monad.xyz" target="_blank" rel="noreferrer"><button>Get testnet MON</button></a>}
        </div>
      )}
      {info?.paused && <div className="banner" role="status">Trading paused. You can still cancel, withdraw and redeem.</div>}
      {health.failing && <div className="banner err" role="alert">Network unreachable ({health.lastError}). Retrying…<button onClick={props.onRetry}>Retry now</button></div>}
      {info && info.collateralCapUsd !== undefined && info.totalCollateralUsd !== undefined && info.totalCollateralUsd >= info.collateralCapUsd * 0.95 && (
        <div className="banner" role="status">Deposit limit almost full.</div>
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
          <li>Collateral is {props.info?.collateralSymbol ?? "a stablecoin"}, which its issuer can freeze or restrict. Binary options may be restricted where you live — you are responsible for complying with local law.</li>
          <li>Nothing here is financial advice.</li>
        </ul>
        <label className="check"><input type="checkbox" checked={checked} onChange={(e) => setChecked(e.target.checked)} /><span>I understand these risks and that I am solely responsible for my use of this app.</span></label>
        <button className="cta" style={{ width: "100%", justifyContent: "center" }} disabled={!checked} onClick={() => { try { localStorage.setItem(RISK_KEY, "1"); } catch { /* private mode */ } setOk(true); }}>Continue</button>
      </div>
    </div>
  );
}

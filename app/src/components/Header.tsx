import type { AccountView, ChainInfo } from "../api/types";
import { short, usd } from "../lib/format";
import { useBlip } from "./Motion";

export function Header(props: { info?: ChainInfo; account?: AccountView; onConnect: () => void; onFaucet: () => void }) {
  const { info, account } = props;
  const blip = useBlip(info?.block);
  return (
    <>
      {info?.mock && <div className="mockbar">DEV MOCK — simulated contracts, no chain. Deploy the contracts and set VITE_DEPLOYMENT to use the real onchain app.</div>}
      <header className="header">
        <div className="logo"><span className="logo-mark" /> montions</div>
        <div className="header-right">
          <span className="chip"><span className={`dot ${info?.mock ? "warn" : ""} ${blip ? "blip" : ""}`} /> {info ? <><b>{info.mock ? "mock" : info.name}</b> block <span className="mono">{info.block.toLocaleString()}</span></> : "connecting…"}</span>
          {account?.address ? (
            <>
              <span className="chip"><b>{usd(account.usdc)}</b> tUSDC</span>
              <button className="btn" onClick={props.onFaucet}>+ Faucet</button>
              <span className="chip mono">{short(account.address)}</span>
            </>
          ) : <button className="btn primary" onClick={props.onConnect}>Connect wallet</button>}
        </div>
      </header>
    </>
  );
}

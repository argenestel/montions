import type { AccountView, ChainInfo } from "../api/types";
import { short, usd } from "../lib/format";
import { InstallButton } from "./InstallButton";
import { useBlip } from "./Motion";

export function Header(props: { info?: ChainInfo; account?: AccountView; walletKind?: string; onConnect: () => void; onAccount: () => void; onFaucet: () => void }) {
  const { info, account } = props;
  const blip = useBlip(info?.block);
  return (
    <>
      {info?.mock && <div className="mockbar">DEV MOCK — simulated contracts, no chain. Deploy the contracts and set VITE_DEPLOYMENT to use the real onchain app.</div>}
      <header className="header">
        <div className="logo"><img className="logo-mark" src="/mark.svg" alt="" width={28} height={28} /> <span className="logo-t">montions</span></div>
        <div className="header-right">
          <InstallButton className="btn btn-install" />
          <span className="chip chip-net"><span className={`dot ${info?.mock ? "warn" : ""} ${blip ? "blip" : ""}`} /> {info ? <><b>{info.mock ? "mock" : info.name}</b> block <span className="mono">{info.block.toLocaleString()}</span></> : "connecting…"}</span>
          {account?.address ? (
            <>
              <span className="chip chip-bal"><b>{usd(account.usdc)}</b> {info?.collateralSymbol ?? "USDC"}</span>
              {info?.faucet !== false && info?.network !== "mainnet" && <button className="btn btn-faucet" onClick={props.onFaucet}>+ Faucet</button>}
              <button className="chip mono" onClick={props.onAccount} title={account.address} data-address={account.address} aria-label="Account menu">{props.walletKind?.startsWith("passkey") ? "🔑 " : ""}{short(account.address)} ▾</button>
            </>
          ) : <button className="btn primary" onClick={props.onConnect}>Connect wallet</button>}
        </div>
      </header>
    </>
  );
}

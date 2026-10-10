import type { AccountView, ChainInfo } from "../api/types";
import { usd } from "../lib/format";
import { avatarStyle } from "../lib/hooks";

export const DOCS_URL = "https://github.com/argenestel/montions/blob/main/docs/ONCHAIN.md";

/** Floating top bar: wordmark, and a dark balance pill ("$18,233  +  avatar") in the centre. Everything else lives in the account sheet. */
export function Header(props: { info?: ChainInfo; account?: AccountView; walletKind?: string; onConnect: () => void; onAccount: () => void; onFaucet: () => void }) {
  const { info, account } = props;
  const faucet = info?.faucet !== false && info?.network !== "mainnet";
  return (
    <>
      {info?.mock && <div className="mockbar">DEV MOCK — simulated contracts, no chain. Deploy the contracts and set VITE_DEPLOYMENT to use the real onchain app.</div>}
      <div className="topbar">
        <a className="wordmark" href="/" aria-label="Montions"><img src="/mark.svg" alt="" width={24} height={24} /><span>montions</span></a>
        {account?.address ? (
          <div className="balpill">
            <span className="bal" title={`${info?.collateralSymbol ?? "USDC"} in wallet`}>{usd(account.usdc)}</span>
            {faucet && <button onClick={props.onFaucet} title={`Get test ${info?.collateralSymbol ?? "USDC"}`} aria-label="Get test collateral">+</button>}
            <button className="avatar" style={avatarStyle(account.address)} onClick={props.onAccount} title={account.address} data-address={account.address} aria-label="Account menu" />
          </div>
        ) : <button className="balpill connect" onClick={props.onConnect}>Connect</button>}
        <div className="right"><a className="toplink" href={DOCS_URL} target="_blank" rel="noreferrer">Docs</a></div>
      </div>
    </>
  );
}

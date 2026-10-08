import { useEffect, useState } from "react";
import { createPortal } from "react-dom";
import type { AccountView, Hex } from "../api/types";
import { usd, short } from "../lib/format";
import { useApi } from "../lib/hooks";
import { DOCS_URL } from "./Header";
import { InstallButton } from "./InstallButton";

type Row = { index: number; address: Hex; active: boolean; usdc?: number; native?: number };

/** Account menu. For passkey wallets it lists the accounts derived from the same passkey ("one passkey, many keys") and switches between them without a new passkey prompt. */
export function AccountSheet(props: { account?: AccountView; symbol: string; onChanged: () => void; onDisconnect: () => void; onClose: () => void; onFaucet?: () => Promise<void> }) {
  const api = useApi();
  const [rows, setRows] = useState<Row[]>(() => api.passkeyAccounts());
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string>();
  const [copied, setCopied] = useState<string>();
  useEffect(() => {
    let alive = true;
    (async () => {
      const base = api.passkeyAccounts();
      const withBal = await Promise.all(base.map(async (r) => ({ ...r, ...(await api.peek(r.address).catch(() => ({ usdc: undefined, native: undefined }))) })));
      if (alive) setRows(withBal);
    })();
    return () => { alive = false; };
  }, [api, props.account?.address]);

  const pick = async (index: number) => {
    setBusy(true); setErr(undefined);
    try { await api.switchPasskeyAccount(index); props.onChanged(); props.onClose(); }
    catch (e) { setErr(e instanceof Error ? e.message : String(e)); } finally { setBusy(false); }
  };
  const copy = async (a: string) => { try { await navigator.clipboard.writeText(a); setCopied(a); setTimeout(() => setCopied(undefined), 1200); } catch { /* clipboard blocked */ } };
  const me = props.account?.address;

  return createPortal(
    <div className="scrim" role="dialog" aria-modal="true" aria-label="Account" onMouseDown={(e) => { if (e.target === e.currentTarget && !busy) props.onClose(); }} onKeyDown={(e) => { if (e.key === "Escape" && !busy) props.onClose(); }}>
      <div className="card connect" style={{ maxWidth: 480, width: "100%", background: "#14122b" }}>
        <h1 className="page-title" style={{ fontSize: 26 }}>Account</h1>
        {rows.length > 0 ? (
          <div className="rows">
            {rows.map((r) => (
              <div key={r.index} className={`rowcard acct ${r.active ? "on" : ""}`}>
                <button className="acct-main" disabled={busy || r.active} onClick={() => pick(r.index)} aria-label={`Use account ${r.index + 1}`}>
                  <div className="ttl">Account {r.index + 1} {r.active && <span className="badge">active</span>}</div>
                  <div className="meta mono">{short(r.address)}{r.usdc !== undefined ? ` · ${usd(r.usdc)} ${props.symbol} · ${(r.native ?? 0).toFixed(2)} MON` : ""}</div>
                </button>
                <button className="btn ghost" onClick={() => copy(r.address)} aria-label={`Copy address of account ${r.index + 1}`}>{copied === r.address ? "Copied" : "Copy"}</button>
              </div>
            ))}
          </div>
        ) : (
          <div className="rowcard">
            <div><div className="ttl mono">{short(me)}</div></div>
            {me && <button className="btn ghost" onClick={() => copy(me)}>{copied === me ? "Copied" : "Copy"}</button>}
          </div>
        )}
        {err && <p className="warnline" role="alert" style={{ marginTop: 10 }}>{err}</p>}
        {props.onFaucet && <button className="btn" style={{ width: "100%", marginTop: 14 }} disabled={busy} onClick={async () => { setBusy(true); setErr(undefined); try { await props.onFaucet!(); props.onClose(); } catch (e) { setErr(e instanceof Error ? e.message : String(e)); } finally { setBusy(false); } }}>Get test {props.symbol}</button>}
        <a className="btn ghost" style={{ width: "100%", marginTop: 8, textAlign: "center", display: "block" }} href={DOCS_URL} target="_blank" rel="noreferrer">Docs · contracts and addresses</a>
        <InstallButton className="btn" style={{ width: "100%", marginTop: 8 }} />
        <button className="btn" style={{ width: "100%", marginTop: 8 }} disabled={busy} onClick={() => { props.onDisconnect(); props.onClose(); }}>Disconnect</button>
        <button className="btn ghost" style={{ width: "100%", marginTop: 8 }} disabled={busy} onClick={props.onClose}>Close</button>
      </div>
    </div>,
    document.body,
  );
}

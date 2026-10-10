import { useState } from "react";
import { createPortal } from "react-dom";
import type { ConnectKind } from "../api/types";
import { hasStoredPasskey, hostIsIpAddress } from "../lib/passkey";
import { InstallButton } from "./InstallButton";
import { isMobile, metamaskDeepLink } from "../lib/wallets";

const COPY: Record<Exclude<ConnectKind, "injected">, { icon: string; title: string; sub: string }> = {
  passkey: { icon: "🔑", title: "Sign in with passkey", sub: "Face ID or Touch ID" },
  "passkey-new": { icon: "✨", title: "Create passkey account", sub: "No wallet app, no seed phrase" },
  dev: { icon: "🧪", title: "Dev wallet", sub: "Local chain · fake money" },
};
type Row = { key: string; kind: ConnectKind; walletId?: string; icon: string; img?: string; title: string; sub: string };

export function ConnectSheet(props: { options: ConnectKind[]; wallets: { id: string; name: string; icon?: string }[]; onConnect: (k: ConnectKind, walletId?: string) => Promise<void>; onClose: () => void }) {
  const [busy, setBusy] = useState<string>();
  const [err, setErr] = useState<string>();
  const known = hasStoredPasskey();
  const has = (k: ConnectKind) => props.options.includes(k);

  const rows: Row[] = [];
  // Returning passkey users see "sign in" first; first-time visitors see "create".
  const passkeys: Row[] = (["passkey", "passkey-new"] as const).filter(has).map((k) => ({ key: k, kind: k, icon: COPY[k].icon, title: COPY[k].title, sub: COPY[k].sub }));
  if (!known) passkeys.sort((a) => (a.kind === "passkey-new" ? -1 : 1));
  rows.push(...passkeys);
  if (has("dev")) rows.unshift({ key: "dev", kind: "dev", icon: COPY.dev.icon, title: COPY.dev.title, sub: COPY.dev.sub });
  for (const w of props.wallets) rows.push({ key: `w:${w.id}`, kind: "injected", walletId: w.id, icon: "🦊", img: w.icon, title: w.name, sub: "Browser wallet" });

  const go = async (r: Row) => { setBusy(r.key); setErr(undefined); try { await props.onConnect(r.kind, r.walletId); } catch (e) { setErr(e instanceof Error ? e.message : String(e)); } finally { setBusy(undefined); } };
  const noWallet = props.wallets.length === 0;
  return createPortal(
    <div className="scrim" role="dialog" aria-modal="true" aria-label="Connect" onMouseDown={(e) => { if (e.target === e.currentTarget && !busy) props.onClose(); }} onKeyDown={(e) => { if (e.key === "Escape" && !busy) props.onClose(); }}>
      <div className="card connect">
        <h1 className="page-title" style={{ fontSize: 26 }}>Connect</h1>
        <div className="rows">
          {rows.map((r) => (
            <button key={r.key} className="rowcard optbtn" disabled={!!busy} onClick={() => go(r)}>
              <div className="wl">
                {r.img ? <img src={r.img} alt="" width={28} height={28} /> : <span className="wl-ic" aria-hidden="true">{r.icon}</span>}
                <div><div className="ttl">{r.title}{busy === r.key ? " …" : ""}</div><div className="meta">{r.sub}</div></div>
              </div>
              <span aria-hidden="true">→</span>
            </button>
          ))}
          {noWallet && (isMobile()
            ? <a className="rowcard optbtn" href={metamaskDeepLink()}><div className="wl"><span className="wl-ic" aria-hidden="true">🦊</span><div><div className="ttl">Open in MetaMask app</div><div className="meta">Use your wallet's in-app browser</div></div></div><span aria-hidden="true">→</span></a>
            : <a className="rowcard optbtn" href="https://metamask.io/download" target="_blank" rel="noreferrer"><div className="wl"><span className="wl-ic" aria-hidden="true">🦊</span><div><div className="ttl">No browser wallet found</div><div className="meta">Install MetaMask or Rabby, then reload</div></div></div><span aria-hidden="true">↗</span></a>)}
          {rows.length === 0 && !noWallet && <div className="empty">Nothing available here.</div>}
        </div>
        {hostIsIpAddress() && <p className="subnote" style={{ marginTop: 10 }}>Passkeys need <b>localhost</b> or https, not an IP.</p>}
        {err && <p className="warnline" role="alert" style={{ marginTop: 12 }}>{err}</p>}
        <InstallButton className="btn" style={{ width: "100%", marginTop: 12 }} />
        <button className="btn ghost" style={{ width: "100%", marginTop: 8 }} disabled={!!busy} onClick={props.onClose}>Close</button>
      </div>
    </div>,
    document.body,
  );
}

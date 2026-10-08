import { useState } from "react";
import { createPortal } from "react-dom";
import type { ConnectKind } from "../api/types";
import { hasStoredPasskey, hostIsIpAddress } from "../lib/passkey";

const COPY: Record<ConnectKind, { icon: string; title: string; sub: string }> = {
  passkey: { icon: "🔑", title: "Sign in with passkey", sub: "Face ID or Touch ID" },
  "passkey-new": { icon: "✨", title: "Create passkey account", sub: "No wallet app, no seed phrase" },
  injected: { icon: "🦊", title: "Browser wallet", sub: "MetaMask, Rabby…" },
  dev: { icon: "🧪", title: "Dev wallet", sub: "Local chain · fake money" },
};

export function ConnectSheet(props: { options: ConnectKind[]; onConnect: (k: ConnectKind) => Promise<void>; onClose: () => void }) {
  const [busy, setBusy] = useState<ConnectKind>();
  const [err, setErr] = useState<string>();
  const known = hasStoredPasskey();
  // First-time visitors see "create" first; returning ones see "sign in" first.
  const order: ConnectKind[] = ["dev", "passkey", "passkey-new", "injected"].filter((k) => props.options.includes(k as ConnectKind)) as ConnectKind[];
  if (!known) order.sort((a, b) => (a === "passkey-new" ? -1 : b === "passkey-new" ? 1 : 0));
  const go = async (k: ConnectKind) => { setBusy(k); setErr(undefined); try { await props.onConnect(k); } catch (e) { setErr(e instanceof Error ? e.message : String(e)); } finally { setBusy(undefined); } };
  return createPortal(
    <div className="scrim" role="dialog" aria-modal="true" aria-label="Connect" onMouseDown={(e) => { if (e.target === e.currentTarget && !busy) props.onClose(); }} onKeyDown={(e) => { if (e.key === "Escape" && !busy) props.onClose(); }}>
      <div className="card connect" style={{ maxWidth: 480, width: "100%", background: "#14122b" }}>
        <h1 className="page-title" style={{ fontSize: 26 }}>Connect</h1>
        <div className="rows">
          {order.length === 0 && <div className="empty">No sign-in method available here. Passkeys need https.</div>}
          {order.map((k) => (
            <button key={k} className="rowcard optbtn" disabled={!!busy} onClick={() => go(k)}>
              <div><div className="ttl">{COPY[k].icon} {COPY[k].title}{busy === k ? " …" : ""}</div><div className="meta">{COPY[k].sub}</div></div>
              <span aria-hidden="true">→</span>
            </button>
          ))}
        </div>
        {hostIsIpAddress() && <p className="subnote" style={{ marginTop: 10 }}>Passkeys need <b>localhost</b> or https, not an IP.</p>}
        {err && <p className="warnline" role="alert" style={{ marginTop: 12 }}>{err}</p>}
        <button className="btn ghost" style={{ width: "100%", marginTop: 8 }} disabled={!!busy} onClick={props.onClose}>Close</button>
      </div>
    </div>,
    document.body,
  );
}

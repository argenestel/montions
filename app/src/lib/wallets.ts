// Browser-wallet discovery via EIP-6963 (works with MetaMask, Rabby, Phantom, Coinbase, … side by side), with window.ethereum as the fallback.
export type Eip1193 = { request: (a: { method: string; params?: unknown[] }) => Promise<unknown>; on?: (ev: string, cb: (...a: unknown[]) => void) => void; removeListener?: (ev: string, cb: (...a: unknown[]) => void) => void };
export interface DiscoveredWallet { id: string; name: string; icon?: string; provider: Eip1193 }

const found = new Map<string, DiscoveredWallet>();
let started = false;

export function startWalletDiscovery() {
  if (started || typeof window === "undefined") return; started = true;
  window.addEventListener("eip6963:announceProvider", (ev) => {
    const d = (ev as CustomEvent<{ info?: { uuid: string; name: string; icon?: string; rdns?: string }; provider?: Eip1193 }>).detail;
    if (!d?.info || !d.provider) return;
    found.set(d.info.rdns || d.info.uuid, { id: d.info.rdns || d.info.uuid, name: d.info.name, icon: d.info.icon, provider: d.provider });
  });
  window.dispatchEvent(new Event("eip6963:requestProvider"));
}

const legacy = (): Eip1193 | undefined => (globalThis as unknown as { ethereum?: Eip1193 }).ethereum;

/** All wallets the page can see. If a wallet only injects window.ethereum, it is listed as "Browser wallet". */
export function listWallets(): DiscoveredWallet[] {
  startWalletDiscovery();
  const out = [...found.values()];
  const l = legacy();
  if (l && !out.some((w) => w.provider === l)) out.push({ id: "window.ethereum", name: "Browser wallet", provider: l });
  return out;
}
export const walletById = (id?: string): DiscoveredWallet | undefined => { const all = listWallets(); return all.find((w) => w.id === id) ?? all[0]; };

/** On a phone with no injected wallet, open the page inside the MetaMask app browser (where a wallet is injected). */
export const metamaskDeepLink = () => (typeof location === "undefined" ? "" : `https://metamask.app.link/dapp/${location.host}${location.pathname}`);
export const isMobile = () => typeof navigator !== "undefined" && /Android|iPhone|iPad|iPod/i.test(navigator.userAgent);

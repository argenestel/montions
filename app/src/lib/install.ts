// "Install app" support (PWA). Chrome/Edge/Android fire beforeinstallprompt; iOS Safari has no such event (use Share → Add to Home Screen).
type Prompt = Event & { prompt: () => Promise<void>; userChoice: Promise<{ outcome: string }> };
let deferred: Prompt | undefined;
const subs = new Set<() => void>();

export const isStandalone = () => typeof window !== "undefined" && (window.matchMedia?.("(display-mode: standalone)").matches || (navigator as unknown as { standalone?: boolean }).standalone === true);
export const canInstall = () => !!deferred && !isStandalone();
export const onInstallChange = (cb: () => void) => { subs.add(cb); return () => { subs.delete(cb); }; };
export async function install() { const d = deferred; if (!d) return; await d.prompt(); await d.userChoice.catch(() => undefined); deferred = undefined; subs.forEach((f) => f()); }

if (typeof window !== "undefined") {
  window.addEventListener("beforeinstallprompt", (e) => { e.preventDefault(); deferred = e as Prompt; subs.forEach((f) => f()); });
  window.addEventListener("appinstalled", () => { deferred = undefined; subs.forEach((f) => f()); });
}

export function registerServiceWorker() {
  if (!import.meta.env.PROD || typeof navigator === "undefined" || !("serviceWorker" in navigator)) return;
  window.addEventListener("load", () => { navigator.serviceWorker.register("/sw.js").catch(() => { /* optional: the app works without it */ }); });
}

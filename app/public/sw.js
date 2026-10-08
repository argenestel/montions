// Montions service worker: installable app shell + offline start. Never touches RPC calls, the deployment manifest or non-GET requests.
const VERSION = "montions-v1";
const SHELL = ["/", "/manifest.webmanifest", "/mark.svg", "/icon-192.png"];

// Precache the shell AND the hashed bundles it references, so the very first visit already works offline.
async function precache() {
  const cache = await caches.open(VERSION);
  const html = await (await fetch("/", { cache: "no-store" })).text();
  const assets = [...new Set([...html.matchAll(/["'(](\/assets\/[^"')\s]+)/g)].map((m) => m[1]))];
  await cache.addAll([...SHELL, ...assets]);
}
self.addEventListener("install", (e) => { e.waitUntil(precache().then(() => self.skipWaiting())); });
self.addEventListener("activate", (e) => {
  e.waitUntil(caches.keys().then((keys) => Promise.all(keys.filter((k) => k !== VERSION).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});

self.addEventListener("fetch", (e) => {
  const req = e.request; const url = new URL(req.url);
  if (req.method !== "GET" || url.origin !== self.location.origin) return;           // RPC, fonts, wallets: always network
  if (url.pathname.startsWith("/deployment") || url.pathname === "/sw.js") return;    // live config: never cached
  if (req.mode === "navigate") {                                                      // pages: network first, cached shell when offline
    e.respondWith(fetch(req).then((r) => { const copy = r.clone(); caches.open(VERSION).then((c) => c.put("/", copy)); return r; }).catch(() => caches.match("/", { ignoreVary: true })));
    return;
  }
  if (url.pathname.startsWith("/assets/") || /\.(png|svg|webmanifest)$/.test(url.pathname)) {   // hashed assets: cache first
    e.respondWith(caches.match(req, { ignoreVary: true }).then((hit) => hit || fetch(req).then((r) => { if (r.ok) { const copy = r.clone(); caches.open(VERSION).then((c) => c.put(req, copy)); } return r; })));
  }
});

export const usd = (n: number, dp = 0) =>
  n.toLocaleString("en-US", { style: "currency", currency: "USD", minimumFractionDigits: dp, maximumFractionDigits: dp });

export const price = (n: number) => {
  if (n >= 1000) return usd(n, 0);
  if (n >= 10) return usd(n, 2);
  return usd(n, n >= 1 ? 3 : 4);
};

export const pct = (p: number, dp = 0) => `${(p * 100).toFixed(dp)}%`;
export const cents = (tick: number) => `${tick}¢`;
export const short = (a?: string) => (a ? `${a.slice(0, 6)}…${a.slice(-4)}` : "—");

export function untilText(expiry: number, now = Date.now() / 1000): string {
  let s = Math.max(0, Math.floor(expiry - now));
  const d = Math.floor(s / 86400); s -= d * 86400;
  const h = Math.floor(s / 3600); s -= h * 3600;
  const m = Math.floor(s / 60); s -= m * 60;
  if (d > 0) return `${d}d ${h}h`;
  if (h > 0) return `${h}h ${m}m`;
  if (m > 0) return `${m}m ${s}s`;
  return `${s}s`;
}

export function whenText(expiry: number): string {
  const d = new Date(expiry * 1000);
  return d.toLocaleString("en-US", { weekday: "short", month: "short", day: "numeric", hour: "numeric", minute: "2-digit" });
}

/** Short date for the sentence pill: "Oct 16", or the time when it is less than a day away. */
export function dayText(expiry: number, now = Date.now() / 1000): string {
  const d = new Date(expiry * 1000);
  if (expiry - now < 20 * 3600) return d.toLocaleString("en-US", { hour: "numeric", minute: "2-digit" });
  return d.toLocaleString("en-US", { month: "short", day: "numeric" });
}

/** Full date for confirmations: "Oct 16, 2026". */
export const fullDate = (expiry: number) => new Date(expiry * 1000).toLocaleString("en-US", { month: "short", day: "numeric", year: "numeric" });

export const durationLabel = (expiry: number, now = Date.now() / 1000) => {
  const s = expiry - now;
  if (s < 3600) return "Minutes";
  if (s < 86400) return "Hourly";
  if (s < 3 * 86400) return "Daily";
  return "Weekly";
};

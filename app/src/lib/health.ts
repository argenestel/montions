import { explain } from "./errors";
import type { Api } from "../api/types";

export interface Health { failing: boolean; lastError?: string }
// Read-only methods whose repeated failure means the network/RPC is unhealthy (user-initiated writes are excluded).
const READS = new Set(["chainInfo", "assets", "seriesFor", "depth", "trades", "quoteBuy", "account", "positions", "orders", "vault", "wallet"]);

/** Wrap the API so 3 consecutive read failures flip a health flag the UI shows as a retry banner. */
export function withHealth(api: Api, notify: (h: Health) => void): Api {
  let fails = 0;
  return new Proxy(api, {
    get(target, key: string) {
      const value = (target as unknown as Record<string, unknown>)[key];
      if (typeof value !== "function") return value;
      return (...args: unknown[]) => {
        const out = (value as (...a: unknown[]) => unknown).apply(target, args);
        if (!READS.has(key) || !(out instanceof Promise)) return out;
        return out.then((r) => { if (fails >= 3) notify({ failing: false }); fails = 0; return r; }, (e) => { fails++; if (fails === 3) notify({ failing: true, lastError: explain(e) }); throw e; });
      };
    },
  }) as Api;
}

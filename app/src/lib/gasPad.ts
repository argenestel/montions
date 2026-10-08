import { custom, type Transport } from "viem";

/**
 * Monad charges the gas LIMIT you declare, not the gas used, and an orderbook's cost can shift between estimate and inclusion.
 * Local-key wallets (passkeys) send exactly the estimate, so pad `eth_estimateGas` by `pct`% (extra limit is NOT refunded as gas used,
 * but a too-tight limit would revert and still cost the fee).
 */
export function gasPadded(inner: Transport, pct = 125): Transport {
  return (opts) => {
    const base = inner(opts);
    return custom({
      async request({ method, params }: { method: string; params?: unknown }) {
        const out = await base.request({ method, params } as never);
        if (method === "eth_estimateGas" && typeof out === "string") return `0x${((BigInt(out) * BigInt(pct)) / 100n).toString(16)}`;
        return out;
      },
    })(opts);
  };
}

// Turn wallet / viem / contract errors into one short, human sentence. Never leak raw RPC payloads to users.
const CONTRACT: Record<string, string> = {
  Paused: "New trading is paused right now. You can still cancel orders, withdraw and redeem.",
  CollateralCapExceeded: "The launch deposit limit has been reached. Try a smaller amount or come back later.",
  SeriesCapExceeded: "This market has reached its launch size limit.",
  VaultCapExceeded: "The vault deposit limit has been reached.",
  Expired: "This market has expired and no longer accepts orders.",
  SeriesNotOpen: "This market is closed.",
  SeriesUnknown: "This market doesn't exist.",
  InsufficientCash: "Not enough balance to cover this order and its reserve.",
  InsufficientTokens: "You don't hold enough of that position.",
  WouldCross: "Your order would have matched immediately; try again.",
  BadTick: "That price is outside the allowed range.",
  BadQty: "That size is outside the allowed range.",
  ResolverNotAllowed: "This market type isn't enabled.",
  NotExpired: "This market hasn't expired yet.",
  OrderNotOpen: "That order is no longer open.",
  NotOrderOwner: "That order belongs to someone else.",
};

type Anyish = { name?: string; shortMessage?: string; message?: string; code?: number; cause?: unknown; data?: { errorName?: string }; details?: string; walk?: (fn: (e: unknown) => boolean) => unknown };

function findName(e: unknown): string | undefined {
  let cur = e as Anyish | undefined;
  for (let i = 0; i < 6 && cur; i++) {
    if (cur.data?.errorName) return cur.data.errorName;
    cur = cur.cause as Anyish | undefined;
  }
  return undefined;
}

export function isUserRejection(e: unknown): boolean {
  let cur = e as Anyish | undefined;
  for (let i = 0; i < 6 && cur; i++) {
    if (cur.code === 4001 || cur.name === "UserRejectedRequestError" || /user (rejected|denied)/i.test(cur.message ?? "")) return true;
    cur = cur.cause as Anyish | undefined;
  }
  return false;
}

export function explain(e: unknown): string {
  if (isUserRejection(e)) return "You cancelled the request in your wallet.";
  const name = findName(e);
  if (name && CONTRACT[name]) return CONTRACT[name];
  const msg = ((e as Anyish)?.shortMessage ?? (e as Anyish)?.message ?? String(e)).split("\n")[0];
  if (/insufficient funds/i.test(msg)) return "Not enough native gas token (MON) in your wallet to pay the network fee.";
  if (/chain|network/i.test(msg) && /mismatch|switch|wrong/i.test(msg)) return "Your wallet is on the wrong network. Switch networks and try again.";
  if (/timeout|timed out|fetch|network request failed|failed to fetch|429|rate/i.test(msg)) return "The network is slow or rate-limited right now. Please retry in a moment.";
  if (/nonce/i.test(msg)) return "Your wallet has a pending transaction. Wait for it to confirm, then retry.";
  if (/revert/i.test(msg)) return "The transaction was rejected by the contract. Refresh the price and try again.";
  return msg.length > 140 ? `${msg.slice(0, 137)}…` : msg;
}

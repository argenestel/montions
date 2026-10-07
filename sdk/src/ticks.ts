/**
 * Units used by Montions' USDC collateral and integer price ladder.
 *
 * A contract pays one USDC (`UNIT`) and one price tick is one cent
 * (`TICK_UNIT`).  Amounts and quantities stay as bigint throughout the SDK;
 * only ticks are represented as numbers because they are small enum-like
 * values on the wire.
 */

export const UNIT = 1_000_000n;
export const TICK_UNIT = 10_000n;
export const TICKS = 100;
export const MIN_TICK = 1;
export const MAX_TICK = TICKS - 1;
export const WAD = 1_000_000_000_000_000_000n;

export type Tick = number;
export type TickRounding = "down" | "up" | "nearest";
export type UsdcAmount = bigint;

/** Return `n / d`, rounded upward. Both arguments must be non-negative. */
export function ceilDiv(n: bigint, d: bigint): bigint {
  if (n < 0n || d <= 0n) throw new RangeError("ceilDiv expects n >= 0 and d > 0");
  return n === 0n ? 0n : (n - 1n) / d + 1n;
}

/** Validate a price tick. Tick zero is reserved for an empty book view. */
export function assertTick(tick: number, allowZero = false): Tick {
  const lower = allowZero ? 0 : MIN_TICK;
  if (!Number.isInteger(tick) || tick < lower || tick > MAX_TICK) {
    throw new RangeError(`tick must be an integer in [${lower}, ${MAX_TICK}]`);
  }
  return tick;
}

/** Clamp a candidate tick to the valid order-price range. */
export function clampTick(tick: number): Tick {
  if (!Number.isFinite(tick)) throw new RangeError("tick must be finite");
  return Math.max(MIN_TICK, Math.min(MAX_TICK, Math.round(tick)));
}

/** Price paid for `quantity` contracts at `tick`, in USDC base units. */
export function tickToUsdc(tick: number, quantity = 1n): UsdcAmount {
  assertTick(tick);
  if (quantity < 0n) throw new RangeError("quantity must be non-negative");
  return BigInt(tick) * TICK_UNIT * quantity;
}

/** Alias used by callers that think of ticks as a unit price. */
export const tickCost = tickToUsdc;
export const usdcForTick = tickToUsdc;

/** Convert an order tick to its exact USDC price per contract. */
export const tickToPrice = tickToUsdc;

/** Convert an order tick to a decimal USD string, such as `0.35`. */
export function tickToPriceUsd(tick: number): string {
  return formatUsdc(tickToUsdc(tick), { decimals: 2, symbol: "", trim: false });
}

/** Convert a tick to a WAD probability/price (35 ticks = 0.35e18). */
export function tickToWad(tick: number): bigint {
  assertTick(tick);
  return (BigInt(tick) * WAD) / BigInt(TICKS);
}

/**
 * Convert a USDC price to a tick.
 *
 * Bigints are already USDC base units. Numbers and strings are interpreted as
 * decimal USD (`"0.35"` and `0.35` are both 35 ticks). The result is not
 * clamped, so a zero or out-of-range price can be detected by the caller.
 */
export function priceToTick(price: bigint | number | string, rounding: TickRounding = "nearest"): Tick {
  const micro = typeof price === "bigint" ? price : parseUsdc(price);
  if (micro < 0n) throw new RangeError("price must be non-negative");
  const quotient = micro / TICK_UNIT;
  const remainder = micro % TICK_UNIT;
  let tick = quotient;
  if (rounding === "up" && remainder !== 0n) tick += 1n;
  if (rounding === "nearest" && remainder * 2n >= TICK_UNIT) tick += 1n;
  if (tick > BigInt(Number.MAX_SAFE_INTEGER)) throw new RangeError("price is too large");
  return Number(tick);
}

/** Parse decimal USD into exact USDC base units. */
export function parseUsdc(value: bigint | number | string): UsdcAmount {
  if (typeof value === "bigint") {
    if (value < 0n) throw new RangeError("USDC amount must be non-negative");
    return value;
  }

  let text = typeof value === "number" ? value.toString() : value.trim();
  if (typeof value === "number" && (!Number.isFinite(value) || value < 0)) {
    throw new RangeError("USDC amount must be a finite non-negative number");
  }
  if (text.startsWith("$")) text = text.slice(1);
  text = text.replaceAll(",", "");
  const match = /^(\d+)(?:\.(\d+))?$/.exec(text);
  if (!match) throw new TypeError(`invalid USDC amount: ${String(value)}`);
  const wholeText = match[1];
  if (wholeText === undefined) throw new TypeError(`invalid USDC amount: ${String(value)}`);
  const whole = BigInt(wholeText);
  const fraction = match[2] ?? "";
  if (fraction.length > 6) throw new RangeError("USDC supports at most 6 decimal places");
  return whole * UNIT + BigInt(fraction.padEnd(6, "0") || "0");
}

export interface FormatUsdcOptions {
  /** Number of fractional digits to show. Defaults to two for UI labels. */
  decimals?: number;
  /** Prefix to use; defaults to `$`. Pass an empty string for a bare value. */
  symbol?: string;
  /** Trim trailing fractional zeroes. Defaults to true. */
  trim?: boolean;
}

/** Format a USDC amount without converting the bigint through Number. */
export function formatUsdc(amount: UsdcAmount, options: FormatUsdcOptions = {}): string {
  if (amount < 0n) return `-${formatUsdc(-amount, options)}`;
  const decimals = options.decimals ?? 2;
  if (!Number.isInteger(decimals) || decimals < 0 || decimals > 6) {
    throw new RangeError("format decimals must be an integer from 0 to 6");
  }
  const symbol = options.symbol ?? "$";
  const trim = options.trim ?? true;
  const whole = amount / UNIT;
  const six = (amount % UNIT).toString().padStart(6, "0");
  let fraction = decimals === 0 ? "" : six.slice(0, decimals);
  if (trim && fraction) fraction = fraction.replace(/0+$/, "");
  return `${symbol}${whole}${fraction ? `.${fraction}` : ""}`;
}

/** Exact six-decimal formatter, useful for ledger/debug output. */
export function formatUsdcExact(amount: UsdcAmount, symbol = ""): string {
  return formatUsdc(amount, { decimals: 6, symbol, trim: true });
}

export const formatUSDC = formatUsdc;

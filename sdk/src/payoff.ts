import { UNIT, WAD, tickToUsdc } from "./ticks.js";

export type PositionSide = "YES" | "NO" | "yes" | "no";

export interface Position {
  /** Outcome token held by the user. Case is accepted for JSON/UI callers. */
  side: PositionSide;
  /** Whole outcome contracts. */
  quantity: bigint;
  /** Premium paid in USDC base units. */
  cost?: bigint;
  /** Alias for cost, useful when composing a quote result. */
  entryCost?: bigint;
  /** Optional entry tick used when cost was not already calculated. */
  entryTick?: number;
}

export interface PositionSettlement {
  side: "YES" | "NO";
  quantity: bigint;
  won: boolean;
  payout: bigint;
  cost: bigint;
  pnl: bigint;
}

export interface PortfolioSettlement {
  yes: PositionSettlement;
  no: PositionSettlement;
  payout: bigint;
  cost: bigint;
  pnl: bigint;
}

function normalizedSide(side: PositionSide): "YES" | "NO" {
  const upper = side.toUpperCase();
  if (upper !== "YES" && upper !== "NO") throw new RangeError("position side must be YES or NO");
  return upper;
}

function checkQuantity(quantity: bigint): bigint {
  if (quantity < 0n) throw new RangeError("position quantity must be non-negative");
  return quantity;
}

function positionCost(position: Position): bigint {
  if (position.cost !== undefined && position.entryCost !== undefined && position.cost !== position.entryCost) {
    throw new RangeError("cost and entryCost disagree");
  }
  const explicit = position.cost ?? position.entryCost;
  if (explicit !== undefined) {
    if (explicit < 0n) throw new RangeError("position cost must be non-negative");
    return explicit;
  }
  if (position.entryTick !== undefined) return tickToUsdc(position.entryTick, position.quantity);
  return 0n;
}

/** Whether a position wins for the resolved YES/NO outcome. */
export function positionWins(side: PositionSide, yesOutcome: boolean): boolean {
  return normalizedSide(side) === (yesOutcome ? "YES" : "NO");
}

/**
 * Settle one position at expiry. `yesOutcome` is the resolver's YES result;
 * a false value means the NO token wins.
 */
export function settlePosition(position: Position, yesOutcome: boolean): PositionSettlement {
  const side = normalizedSide(position.side);
  const quantity = checkQuantity(position.quantity);
  const cost = positionCost({ ...position, quantity });
  const won = positionWins(side, yesOutcome);
  const payout = won ? quantity * UNIT : 0n;
  return { side, quantity, won, payout, cost, pnl: payout - cost };
}

/** Gross expiry payout for a position, excluding the premium paid. */
export function payoffAtExpiry(position: Position, yesOutcome: boolean): bigint {
  return settlePosition(position, yesOutcome).payout;
}

/** Net expiry P&L for a position, including its premium. */
export function pnlAtExpiry(position: Position, yesOutcome: boolean): bigint {
  return settlePosition(position, yesOutcome).pnl;
}

/** Explicitly named alias for applications that prefer a verb over `pnlAtExpiry`. */
export const positionPnlAtExpiry = pnlAtExpiry;

/**
 * Settle a two-sided portfolio. Missing sides are treated as zero quantity and
 * zero cost, which makes this useful for a chart or a quote with one outcome.
 */
export function settlePortfolio(
  portfolio: { yes?: Partial<Position> & { quantity: bigint }; no?: Partial<Position> & { quantity: bigint } },
  yesOutcome: boolean,
): PortfolioSettlement {
  const yes = settlePosition({ ...(portfolio.yes ?? { quantity: 0n }), side: "YES" }, yesOutcome);
  const no = settlePosition({ ...(portfolio.no ?? { quantity: 0n }), side: "NO" }, yesOutcome);
  return {
    yes,
    no,
    payout: yes.payout + no.payout,
    cost: yes.cost + no.cost,
    pnl: yes.pnl + no.pnl,
  };
}

export interface PayoffCurveInput extends Position {
  /** Strike in 1e18-scaled USD, used as the x-axis threshold. */
  strikeWad: bigint;
  /** Lower x-axis bound. Defaults to zero. */
  lowerBoundWad?: bigint;
  /** Upper x-axis bound. Defaults to strike + $1. */
  upperBoundWad?: bigint;
}

export interface PayoffCurvePoint {
  /** Underlying price in WAD. */
  x: bigint;
  /** Net P&L in USDC base units. */
  y: bigint;
  priceWad: bigint;
  payout: bigint;
  pnl: bigint;
  /** Resolver interpretation at this x value (YES iff x >= strike). */
  yes: boolean;
}

function curvePoint(input: PayoffCurveInput, x: bigint): PayoffCurvePoint {
  const yes = x >= input.strikeWad; // resolver semantics are explicitly >= for YES.
  const settlement = settlePosition(input, yes);
  return { x, y: settlement.pnl, priceWad: x, payout: settlement.payout, pnl: settlement.pnl, yes };
}

/**
 * Build a small stepped curve suitable for a chart. The point at exactly the
 * strike is intentional: YES wins at equality (`price >= strike`), while NO
 * loses there. `x` and `priceWad` are aliases to make chart adapters simple.
 */
export function steppedPayoffCurve(input: PayoffCurveInput): PayoffCurvePoint[] {
  if (input.strikeWad < 0n) throw new RangeError("strikeWad must be non-negative");
  const lower = input.lowerBoundWad ?? 0n;
  const upper = input.upperBoundWad ?? input.strikeWad + WAD;
  if (lower < 0n || upper < lower) throw new RangeError("invalid payoff curve bounds");
  if (input.strikeWad < lower || input.strikeWad > upper) {
    throw new RangeError("strikeWad must lie within payoff curve bounds");
  }

  const before = input.strikeWad > lower ? input.strikeWad - 1n : lower;
  const xs = [lower, before, input.strikeWad, upper];
  const points: PayoffCurvePoint[] = [];
  for (const x of xs) {
    if (points.length === 0 || points[points.length - 1]?.x !== x) points.push(curvePoint(input, x));
  }
  return points;
}

/** Alias using the shorter name used by charting consumers. */
export const payoffCurve = steppedPayoffCurve;
export const payoffCurvePoints = steppedPayoffCurve;

/**
 * Convenience helper for the common one-sided chart API. `cost` is already in
 * USDC base units; use `entryTick` when the chart starts from an order tick.
 */
export function steppedPositionPayoffCurve(
  side: PositionSide,
  quantity: bigint,
  strikeWad: bigint,
  cost = 0n,
): PayoffCurvePoint[] {
  return steppedPayoffCurve({ side, quantity, strikeWad, cost });
}

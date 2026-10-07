/** One Ornstein-Uhlenbeck step in log-price space. `sigma` is annualized volatility. */
export function meanRevertingLogStep(
  logPrice: number,
  logAnchor: number,
  sigma: number,
  elapsedSeconds: number,
  normalShock: number,
  meanReversion = 0.08,
): number {
  if (![logPrice, logAnchor, sigma, elapsedSeconds, normalShock, meanReversion].every(Number.isFinite)) {
    throw new TypeError("price-walk inputs must be finite");
  }
  if (sigma < 0 || elapsedSeconds < 0 || meanReversion < 0) {
    throw new RangeError("volatility, elapsed time, and mean reversion must be non-negative");
  }
  const dt = elapsedSeconds / 31_536_000;
  const reversion = -meanReversion * (logPrice - logAnchor) * elapsedSeconds;
  const diffusion = sigma * Math.sqrt(dt) * normalShock;
  return logPrice + reversion + diffusion;
}

/** Box-Muller standard-normal sample using a caller-provided uniform source. */
export function standardNormal(random: () => number = Math.random): number {
  const u1 = Math.max(Number.EPSILON, Math.min(1 - Number.EPSILON, random()));
  const u2 = Math.max(Number.EPSILON, Math.min(1 - Number.EPSILON, random()));
  return Math.sqrt(-2 * Math.log(u1)) * Math.cos(2 * Math.PI * u2);
}

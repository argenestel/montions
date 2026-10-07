// Client-side mirror of the onchain fair-value model (PricingLib.digitalProbWad), used only for UI previews and the dev mock.
export function normCdf(x: number): number {
  // Abramowitz–Stegun 7.1.26 via erf
  const t = 1 / (1 + 0.3275911 * Math.abs(x / Math.SQRT2));
  const y = 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * Math.exp(-(x * x) / 2);
  return 0.5 * (1 + (x >= 0 ? y : -y));
}

/** P(S_T >= K) for a digital option, zero rate. */
export function digitalProb(spot: number, strike: number, vol: number, secondsToExpiry: number): number {
  if (secondsToExpiry <= 0) return spot >= strike ? 1 : 0;
  const T = secondsToExpiry / (365 * 24 * 3600);
  const sd = vol * Math.sqrt(T);
  if (sd === 0) return spot >= strike ? 1 : 0;
  const d2 = (Math.log(spot / strike) - (vol * vol * T) / 2) / sd;
  return normCdf(d2);
}

export const clampTick = (t: number) => Math.min(99, Math.max(1, Math.round(t)));

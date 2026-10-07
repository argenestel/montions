export const ROLLING_EXPIRIES_SECONDS = [
  15 * 60,
  60 * 60,
  4 * 60 * 60,
  24 * 60 * 60,
  3 * 24 * 60 * 60,
  7 * 24 * 60 * 60,
] as const;

export const STRIKE_MULTIPLIERS_BPS = [8_000, 9_000, 9_500, 10_000, 10_500, 11_000, 12_000, 13_500, 15_000] as const;
export const SERIES_WINDOW_SECONDS = 60;
export const EXPIRY_GRID_SECONDS = 5 * 60;

export interface LadderAsset {
  symbol: string;
  assetId: `0x${string}`;
  spotWad: bigint;
  strikeGridWad: bigint;
}

export interface PlannedSeries {
  symbol: string;
  assetId: `0x${string}`;
  strikeWad: bigint;
  expiry: bigint;
  above: true;
  window: number;
}

export function roundExpiryUp(timestampSeconds: bigint, gridSeconds = BigInt(EXPIRY_GRID_SECONDS)): bigint {
  if (timestampSeconds < 0n || gridSeconds <= 0n) throw new RangeError("invalid timestamp or grid");
  return ((timestampSeconds + gridSeconds - 1n) / gridSeconds) * gridSeconds;
}

export function roundToGrid(value: bigint, grid: bigint): bigint {
  if (value < 0n || grid <= 0n) throw new RangeError("invalid value or strike grid");
  return ((value + grid / 2n) / grid) * grid;
}

export function planSeriesLadder(nowSeconds: bigint, assets: readonly LadderAsset[]): PlannedSeries[] {
  const result: PlannedSeries[] = [];
  for (const asset of assets) {
    if (asset.spotWad <= 0n || asset.strikeGridWad <= 0n) {
      throw new RangeError(`${asset.symbol} spot and strike grid must be positive`);
    }
    const expiries = ROLLING_EXPIRIES_SECONDS.map((duration) =>
      roundExpiryUp(nowSeconds + BigInt(duration), BigInt(EXPIRY_GRID_SECONDS)),
    );
    for (const expiry of expiries) {
      for (const multiplierBps of STRIKE_MULTIPLIERS_BPS) {
        const strike = roundToGrid((asset.spotWad * BigInt(multiplierBps)) / 10_000n, asset.strikeGridWad);
        result.push({
          symbol: asset.symbol,
          assetId: asset.assetId,
          strikeWad: strike,
          expiry,
          above: true,
          window: SERIES_WINDOW_SECONDS,
        });
      }
    }
  }
  return result;
}

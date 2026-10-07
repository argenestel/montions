// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IPriceOracle
/// @notice Fully onchain price source. Implemented by OracleHub, which reads TWAP observations written by SpotPool swaps.
/// @dev All prices are USD per ONE WHOLE unit of the asset, scaled by 1e18 (1e18 == $1.00).
interface IPriceOracle {
    error UnknownAsset(bytes32 assetId);
    error HistoryUnavailable(bytes32 assetId, uint64 t);

    function assetExists(bytes32 assetId) external view returns (bool);

    /// @return priceWad spot price from the most recent observation (price after the last swap)
    /// @return updatedAt timestamp of that observation
    function latestPrice(bytes32 assetId) external view returns (uint256 priceWad, uint64 updatedAt);

    /// @notice time-weighted average price over (t - window, t]. `t` may be in the past.
    /// @dev Reverts HistoryUnavailable if the observation ring buffer no longer covers t - window.
    ///      For t beyond the last observation the last price is extrapolated.
    function twapAt(bytes32 assetId, uint64 t, uint32 window) external view returns (uint256 priceWad);

    /// @notice annualised realised volatility (1e18 == 100%) from TWAP samples of `step` seconds over the last `lookback` seconds.
    /// @dev view-only, intended for the Quoter/MakerVault. Returns 0 if history is insufficient (< 3 samples).
    function realizedVol(bytes32 assetId, uint32 lookback, uint32 step) external view returns (uint256 volWad);
}

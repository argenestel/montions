// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPriceOracle} from "../../interfaces/IPriceOracle.sol";
import {IPyth} from "./IPyth.sol";
import {Ownable} from "solady/auth/Ownable.sol";

/// @title PythOracle
/// @notice WAD-normalising IPriceOracle adapter for Pyth pull prices.
/// @dev TWAP history is unavailable: settlement uses the Pyth update published in the expiry window.
///      `volWad` is a static annualised operator input, not measured volatility; the operator must
///      review it regularly. `isHealthy` requires a fresh price and confidence no greater than 2%.
contract PythOracle is IPriceOracle, Ownable {
    uint256 private constant WAD = 1e18;
    uint256 private constant MAX_CONFIDENCE_BPS = 200;

    struct FeedConfig {
        bytes32 feedId;
        uint256 volWad;
        uint32 maxAge;
    }

    IPyth public immutable pyth;
    mapping(bytes32 assetId => FeedConfig config) public feedConfig;

    error ZeroAddress();
    error InvalidVolatility(uint256 volWad);
    error InvalidMaxAge(uint32 maxAge);
    error ZeroFeedId();
    error UnknownFeed(bytes32 feedId);
    error InvalidPrice(int64 price);
    error InvalidExponent(int32 expo);
    error TimestampOverflow(uint256 timestamp);

    event FeedSet(bytes32 indexed assetId, bytes32 indexed feedId, uint256 volWad, uint32 maxAge);

    /// @notice Deploy the adapter and initialise Solady two-step ownership.
    /// @param pyth_ Pyth core contract.
    /// @param owner_ Initial configuration owner.
    constructor(address pyth_, address owner_) {
        if (pyth_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        pyth = IPyth(pyth_);
        _initializeOwner(owner_);
    }

    /// @notice Configure the Pyth feed and static annualised volatility for an asset.
    /// @dev `volWad` must be 20%-500%; `maxAge` must be 10-3600 seconds.
    function setFeed(bytes32 assetId, bytes32 feedId, uint256 volWad, uint32 maxAge) external onlyOwner {
        if (feedId == bytes32(0)) revert ZeroFeedId();
        if (volWad < 0.2e18 || volWad > 5e18) revert InvalidVolatility(volWad);
        if (maxAge < 10 || maxAge > 3600) revert InvalidMaxAge(maxAge);
        if (!pyth.priceFeedExists(feedId)) revert UnknownFeed(feedId);
        feedConfig[assetId] = FeedConfig({feedId: feedId, volWad: volWad, maxAge: maxAge});
        emit FeedSet(assetId, feedId, volWad, maxAge);
    }

    /// @notice Return the Pyth feed id configured for `assetId`.
    function feedIdOf(bytes32 assetId) external view returns (bytes32) {
        return _config(assetId).feedId;
    }

    /// @inheritdoc IPriceOracle
    function assetExists(bytes32 assetId) external view override returns (bool) {
        return feedConfig[assetId].feedId != bytes32(0);
    }

    /// @inheritdoc IPriceOracle
    function latestPrice(bytes32 assetId) external view override returns (uint256 priceWad, uint64 updatedAt) {
        FeedConfig memory config = _config(assetId);
        IPyth.Price memory price = pyth.getPriceNoOlderThan(config.feedId, config.maxAge);
        if (price.publishTime > type(uint64).max) revert TimestampOverflow(price.publishTime);
        return (_normalise(price.price, price.expo), uint64(price.publishTime));
    }

    /// @inheritdoc IPriceOracle
    /// @notice Always reverts: Pyth settlement has no historical TWAP interface.
    function twapAt(bytes32 assetId, uint64 t, uint32) external pure override returns (uint256) {
        revert HistoryUnavailable(assetId, t);
    }

    /// @inheritdoc IPriceOracle
    /// @notice Returns the configured static annualised volatility; it is not measured from price history.
    /// @dev Operators must review this parameter regularly. `lookback` and `step` are unused by this adapter.
    function realizedVol(bytes32 assetId, uint32, uint32) external view override returns (uint256 volWad) {
        return _config(assetId).volWad;
    }

    /// @notice Whether this configured feed currently has a fresh price with confidence at most 2%.
    function isHealthy(bytes32 assetId) external view returns (bool) {
        FeedConfig memory config = feedConfig[assetId];
        if (config.feedId == bytes32(0) || !pyth.priceFeedExists(config.feedId)) return false;
        try pyth.getPriceNoOlderThan(config.feedId, config.maxAge) returns (IPyth.Price memory price) {
            if (price.price <= 0 || price.expo < -18 || price.expo > 0) return false;
            return uint256(price.conf) * 10_000 <= uint256(uint64(price.price)) * MAX_CONFIDENCE_BPS;
        } catch {
            return false;
        }
    }

    function _config(bytes32 assetId) private view returns (FeedConfig memory config) {
        config = feedConfig[assetId];
        if (config.feedId == bytes32(0)) revert UnknownAsset(assetId);
    }

    function _normalise(int64 rawPrice, int32 expo) private pure returns (uint256) {
        if (rawPrice <= 0) revert InvalidPrice(rawPrice);
        if (expo < -18 || expo > 0) revert InvalidExponent(expo);
        return uint256(uint64(rawPrice)) * (10 ** uint32(int32(18) + expo));
    }
}

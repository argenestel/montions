// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPyth} from "../../../src/oracle/pyth/IPyth.sol";

/// @notice Deterministic Pyth test double with a current price and ordered historical feed updates.
/// @dev Update blobs are `abi.encode(IPyth.PriceFeed)`. Unique parsing returns the earliest matching
///      update in the inclusive time range, and rejects a supplied later update if history contains
///      an earlier update in that range. This models the selection property required by settlement.
contract MockPyth is IPyth {
    error PriceFeedNotFoundWithinRange();
    error PriceFeedNotFound();
    error StalePrice();
    error InsufficientFee();
    error AmbiguousPriceUpdate();

    mapping(bytes32 feedId => bool exists) private _exists;
    mapping(bytes32 feedId => Price current) private _current;
    mapping(bytes32 feedId => PriceFeed[] updates) private _history;
    uint256 public feePerUpdate;

    /// @notice Set the fee charged per opaque update blob. Empty update lists always cost zero.
    function setFee(uint256 feePerUpdate_) external {
        feePerUpdate = feePerUpdate_;
    }

    /// @notice Set the current unsafe price and append it to the historical updates for `feedId`.
    function setPrice(bytes32 feedId, int64 price, uint64 conf, int32 expo, uint256 publishTime) external {
        Price memory value = Price({price: price, conf: conf, expo: expo, publishTime: publishTime});
        _append(feedId, value, value);
    }

    /// @notice Append a historical update and advance the unsafe price if this update is newest.
    function addPriceFeedUpdate(
        bytes32 feedId,
        int64 price,
        uint64 conf,
        int32 expo,
        uint256 publishTime,
        int64 emaPrice,
        uint64 emaConf,
        int32 emaExpo,
        uint256 emaPublishTime
    ) external {
        Price memory value = Price({price: price, conf: conf, expo: expo, publishTime: publishTime});
        Price memory ema = Price({price: emaPrice, conf: emaConf, expo: emaExpo, publishTime: emaPublishTime});
        _append(feedId, value, ema);
    }

    /// @notice Whether this test double has an update for the requested feed.
    function priceFeedExists(bytes32 id) external view override returns (bool) {
        return _exists[id];
    }

    /// @notice Return the latest configured price without freshness validation.
    function getPriceUnsafe(bytes32 id) external view override returns (Price memory price) {
        if (!_exists[id]) revert PriceFeedNotFound();
        return _current[id];
    }

    /// @notice Return the current price only if it is not future-dated or older than `age`.
    function getPriceNoOlderThan(bytes32 id, uint256 age) external view override returns (Price memory price) {
        if (!_exists[id]) revert PriceFeedNotFound();
        price = _current[id];
        if (price.publishTime > block.timestamp || block.timestamp - price.publishTime > age) revert StalePrice();
    }

    /// @notice Fee is the configured per-blob fee; an empty update list has zero fee.
    function getUpdateFee(bytes[] calldata updateData) external view override returns (uint256 feeAmount) {
        return feePerUpdate * updateData.length;
    }

    /// @notice Return the first historical update per feed in [minPublishTime,maxPublishTime].
    /// @dev Caller must include that earliest update blob; passing a later update while history contains an
    ///      earlier one reverts, preventing callers from cherry-picking within a settlement window.
    function parsePriceFeedUpdatesUnique(
        bytes[] calldata updateData,
        bytes32[] calldata priceIds,
        uint64 minPublishTime,
        uint64 maxPublishTime
    ) external payable override returns (PriceFeed[] memory priceFeeds) {
        if (msg.value < feePerUpdate * updateData.length) revert InsufficientFee();
        priceFeeds = new PriceFeed[](priceIds.length);

        for (uint256 i; i < priceIds.length; ++i) {
            bytes32 id = priceIds[i];
            bool found;
            PriceFeed memory first;
            for (uint256 j; j < updateData.length; ++j) {
                PriceFeed memory candidate = abi.decode(updateData[j], (PriceFeed));
                if (candidate.id != id || !_inRange(candidate.price.publishTime, minPublishTime, maxPublishTime)) {
                    continue;
                }
                if (!found || candidate.price.publishTime < first.price.publishTime) {
                    first = candidate;
                    found = true;
                } else if (candidate.price.publishTime == first.price.publishTime && !_sameFeedPrice(candidate, first))
                {
                    revert AmbiguousPriceUpdate();
                }
            }
            if (!found) revert PriceFeedNotFoundWithinRange();

            bool historicalFound;
            uint256 earliest;
            PriceFeed memory historicalFirst;
            PriceFeed[] storage history = _history[id];
            for (uint256 j; j < history.length; ++j) {
                uint256 publishTime = history[j].price.publishTime;
                if (!_inRange(publishTime, minPublishTime, maxPublishTime)) continue;
                if (!historicalFound || publishTime < earliest) {
                    earliest = publishTime;
                    historicalFirst = history[j];
                    historicalFound = true;
                } else if (publishTime == earliest && !_sameFeedPrice(history[j], historicalFirst)) {
                    revert AmbiguousPriceUpdate();
                }
            }
            if (!historicalFound || first.price.publishTime != earliest || !_sameFeedPrice(first, historicalFirst)) {
                revert PriceFeedNotFoundWithinRange();
            }
            priceFeeds[i] = first;
        }
    }

    /// @notice Number of historical updates recorded for a feed.
    function historyLength(bytes32 feedId) external view returns (uint256) {
        return _history[feedId].length;
    }

    /// @notice Read a historical update by insertion index.
    function historyAt(bytes32 feedId, uint256 index) external view returns (PriceFeed memory) {
        return _history[feedId][index];
    }

    /// @notice Encode a historical update blob suitable for `parsePriceFeedUpdatesUnique`.
    function updateDataAt(bytes32 feedId, uint256 index) external view returns (bytes memory) {
        return abi.encode(_history[feedId][index]);
    }

    /// @notice Encode a Pyth-style update blob for tests that need to compose payload arrays.
    function encodeUpdate(PriceFeed calldata feed) external pure returns (bytes memory) {
        return abi.encode(feed);
    }

    function _append(bytes32 feedId, Price memory price, Price memory emaPrice) private {
        _exists[feedId] = true;
        PriceFeed memory feed = PriceFeed({id: feedId, price: price, emaPrice: emaPrice});
        _history[feedId].push(feed);
        if (price.publishTime >= _current[feedId].publishTime) _current[feedId] = price;
    }

    function _inRange(uint256 publishTime, uint64 minPublishTime, uint64 maxPublishTime) private pure returns (bool) {
        return publishTime >= minPublishTime && publishTime <= maxPublishTime;
    }

    function _sameFeedPrice(PriceFeed memory a, PriceFeed memory b) private pure returns (bool) {
        return a.id == b.id && _samePrice(a.price, b.price) && _samePrice(a.emaPrice, b.emaPrice);
    }

    function _samePrice(Price memory a, Price memory b) private pure returns (bool) {
        return a.price == b.price && a.conf == b.conf && a.expo == b.expo && a.publishTime == b.publishTime;
    }
}

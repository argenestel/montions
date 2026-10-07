// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IMontionsBook} from "../../../src/interfaces/IMontionsBook.sol";

/// @notice Small, deterministic Book double for Quoter tests.
/// @dev This deliberately implements only the read surface consumed by Quoter.
///      Depth is kept in the same best-first order promised by IMontionsBook:
///      bids descending, asks ascending.
contract MockBook {
    error UnknownSeries();
    error IndexOutOfBounds();
    error BadDepthLengths();
    error ForcedRevert();

    struct BookSeries {
        IMontionsBook.SeriesInfo info;
        IMontionsBook.Level[] bids;
        IMontionsBook.Level[] asks;
        uint8 lastTradeTick;
        bool exists;
    }

    mapping(bytes32 => BookSeries) private _series;
    bytes32[] private _ids;

    bool public revertSeriesInfo;
    bool public revertBestBidAsk;
    bool public revertDepth;
    bool public revertLastTradeTick;

    function setSeries(
        bytes32 seriesId,
        address resolver,
        bytes calldata data,
        uint64 expiry,
        IMontionsBook.Status status,
        bool yes,
        uint256 yesId,
        uint256 noId,
        uint64 createdAt
    ) external {
        BookSeries storage s = _series[seriesId];
        if (!s.exists) {
            s.exists = true;
            _ids.push(seriesId);
        }
        s.info.resolver = resolver;
        s.info.data = data;
        s.info.expiry = expiry;
        s.info.status = status;
        s.info.yes = yes;
        s.info.yesId = yesId;
        s.info.noId = noId;
        s.info.createdAt = createdAt;
    }

    function setDepth(bytes32 seriesId, IMontionsBook.Side side, uint8[] calldata ticks, uint64[] calldata quantities)
        external
    {
        if (ticks.length != quantities.length) revert BadDepthLengths();
        BookSeries storage s = _series[seriesId];
        if (!s.exists) revert UnknownSeries();
        if (side == IMontionsBook.Side.Bid) {
            delete s.bids;
            for (uint256 i; i < ticks.length; ++i) {
                s.bids.push(IMontionsBook.Level({tick: ticks[i], qty: quantities[i]}));
            }
            _sort(s.bids, true);
        } else {
            delete s.asks;
            for (uint256 i; i < ticks.length; ++i) {
                s.asks.push(IMontionsBook.Level({tick: ticks[i], qty: quantities[i]}));
            }
            _sort(s.asks, false);
        }
    }

    function clearDepth(bytes32 seriesId, IMontionsBook.Side side) external {
        BookSeries storage s = _series[seriesId];
        if (!s.exists) revert UnknownSeries();
        if (side == IMontionsBook.Side.Bid) delete s.bids;
        else delete s.asks;
    }

    function setLastTradeTick(bytes32 seriesId, uint8 tick) external {
        BookSeries storage s = _series[seriesId];
        if (!s.exists) revert UnknownSeries();
        s.lastTradeTick = tick;
    }

    function setReverts(bool seriesInfo_, bool bestBidAsk_, bool depth_, bool lastTradeTick_) external {
        revertSeriesInfo = seriesInfo_;
        revertBestBidAsk = bestBidAsk_;
        revertDepth = depth_;
        revertLastTradeTick = lastTradeTick_;
    }

    function seriesCount() external view returns (uint256) {
        return _ids.length;
    }

    function seriesIdAt(uint256 index) external view returns (bytes32) {
        if (index >= _ids.length) revert IndexOutOfBounds();
        return _ids[index];
    }

    function seriesIds(uint256 offset, uint256 limit) external view returns (bytes32[] memory result) {
        if (offset >= _ids.length) return new bytes32[](0);
        uint256 n = limit;
        if (n > _ids.length - offset) n = _ids.length - offset;
        result = new bytes32[](n);
        for (uint256 i; i < n; ++i) {
            result[i] = _ids[offset + i];
        }
    }

    function seriesInfo(bytes32 seriesId) external view returns (IMontionsBook.SeriesInfo memory) {
        if (revertSeriesInfo) revert ForcedRevert();
        BookSeries storage s = _series[seriesId];
        if (!s.exists) revert UnknownSeries();
        return s.info;
    }

    function bestBidAsk(bytes32 seriesId)
        external
        view
        returns (uint8 bidTick, uint64 bidQty, uint8 askTick, uint64 askQty)
    {
        if (revertBestBidAsk) revert ForcedRevert();
        BookSeries storage s = _series[seriesId];
        if (!s.exists) revert UnknownSeries();
        if (s.bids.length != 0) {
            bidTick = s.bids[0].tick;
            bidQty = s.bids[0].qty;
        }
        if (s.asks.length != 0) {
            askTick = s.asks[0].tick;
            askQty = s.asks[0].qty;
        }
    }

    function depth(bytes32 seriesId, IMontionsBook.Side side, uint8 maxLevels)
        external
        view
        returns (IMontionsBook.Level[] memory result)
    {
        if (revertDepth) revert ForcedRevert();
        BookSeries storage s = _series[seriesId];
        if (!s.exists) revert UnknownSeries();
        IMontionsBook.Level[] storage levels = side == IMontionsBook.Side.Bid ? s.bids : s.asks;
        uint256 n = levels.length;
        if (n > maxLevels) n = maxLevels;
        result = new IMontionsBook.Level[](n);
        for (uint256 i; i < n; ++i) {
            result[i] = levels[i];
        }
    }

    function lastTradeTick(bytes32 seriesId) external view returns (uint8) {
        if (revertLastTradeTick) revert ForcedRevert();
        BookSeries storage s = _series[seriesId];
        if (!s.exists) revert UnknownSeries();
        return s.lastTradeTick;
    }

    function _sort(IMontionsBook.Level[] storage levels, bool descending) private {
        for (uint256 i = 1; i < levels.length; ++i) {
            IMontionsBook.Level memory item = levels[i];
            uint256 j = i;
            while (j != 0) {
                uint8 prior = levels[j - 1].tick;
                if (descending ? prior >= item.tick : prior <= item.tick) break;
                levels[j] = levels[j - 1];
                --j;
            }
            levels[j] = item;
        }
    }
}

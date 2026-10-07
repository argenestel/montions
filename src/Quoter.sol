// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IQuoter} from "./interfaces/IQuoter.sol";
import {IMontionsBook} from "./interfaces/IMontionsBook.sol";
import {IPriceOracle} from "./interfaces/IPriceOracle.sol";
import {IResolver} from "./interfaces/IResolver.sol";
import {TwapThresholdResolver} from "./resolvers/TwapThresholdResolver.sol";
import {PricingLib} from "./pricing/PricingLib.sol";

/// @title Quoter
/// @notice Read-only outcome quotes and digital-option model for Montions.
/// @dev Quotes exclude fees and assume depth can be consumed without self-trade cancellation
///      or an order's maxFills bound. Pool-based model inputs are manipulable at low liquidity;
///      the demo relies on deep seeded pools, not a manipulation-resistant oracle.
///      Moving a pool during the last seconds of an idle window can influence its TWAP;
///      pool depth and longer windows mitigate this risk but do not eliminate it.
contract Quoter is IQuoter {
    error OnlySelf();
    /// @notice Book supplying series metadata and aggregated depth.
    IMontionsBook public immutable book;
    /// @notice Only this resolver's open series receive a model valuation.
    address public immutable twapResolver;

    /// @notice Configure the Book and supported price resolver.
    constructor(address book_, address twapResolver_) {
        book = IMontionsBook(book_);
        twapResolver = twapResolver_;
    }

    /// @inheritdoc IQuoter
    function fair(bytes32 seriesId)
        public
        view
        override
        returns (uint8 fairTick, uint256 probWad, uint256 volWad, uint256 spotWad)
    {
        // A separate call boundary also catches malformed ABI return data, whose
        // decoding failures occur outside Solidity's ordinary external-call catch.
        try this.modelFair(seriesId) returns (uint8 tick, uint256 probability, uint256 vol, uint256 spot) {
            return (tick, probability, vol, spot);
        } catch {
            return (0, 0, 0, 0);
        }
    }

    /// @notice Self-call boundary for fail-soft model evaluation; use fair for public reads.
    /// @dev Restricting this helper to self-calls ensures callers use the never-revert wrapper.
    function modelFair(bytes32 seriesId)
        external
        view
        returns (uint8 fairTick, uint256 probWad, uint256 volWad, uint256 spotWad)
    {
        if (msg.sender != address(this)) revert OnlySelf();
        try book.seriesInfo(seriesId) returns (IMontionsBook.SeriesInfo memory info) {
            return _fair(info);
        } catch {
            return (0, 0, 0, 0);
        }
    }

    function _fair(IMontionsBook.SeriesInfo memory info)
        private
        view
        returns (uint8 fairTick, uint256 probWad, uint256 volWad, uint256 spotWad)
    {
        if (info.status != IMontionsBook.Status.Open || info.resolver != twapResolver) return (0, 0, 0, 0);
        try TwapThresholdResolver(twapResolver).decode(info.data) returns (
            address oracle, bytes32 assetId, uint256 strike, bool above, uint32
        ) {
            try IPriceOracle(oracle).latestPrice(assetId) returns (uint256 spot, uint64) {
                spotWad = spot;
            } catch {
                return (0, 0, 0, 0);
            }
            try IPriceOracle(oracle).realizedVol(assetId, 6 hours, 5 minutes) returns (uint256 vol) {
                volWad = vol == 0 ? 0.8e18 : vol;
                if (volWad < 0.3e18) volWad = 0.3e18;
                if (volWad > 4e18) volWad = 4e18;
            } catch {
                return (0, 0, 0, 0);
            }
            uint256 remaining = info.expiry > block.timestamp ? info.expiry - block.timestamp : 0;
            probWad = PricingLib.digitalProbWad(spotWad, strike, volWad, remaining, above);
            fairTick = PricingLib.probToTick(probWad);
        } catch {
            return (0, 0, 0, 0);
        }
    }

    /// @inheritdoc IQuoter
    /// @dev Buying NO writes YES: an Ask at YES limit 100 - maxTick consumes Bids.
    function quoteBuy(bytes32 seriesId, bool yes, uint64 qty, uint8 maxTick)
        external
        view
        override
        returns (Quote memory)
    {
        return _quote(seriesId, yes, qty, maxTick, true);
    }

    /// @inheritdoc IQuoter
    /// @dev Selling held NO places a close-NO Bid, consuming Asks at proceeds 100 - askTick.
    ///      `cost` reports gross proceeds for sells, before fees.
    function quoteSell(bytes32 seriesId, bool yes, uint64 qty, uint8 minTick)
        external
        view
        override
        returns (Quote memory)
    {
        return _quote(seriesId, yes, qty, minTick, false);
    }

    function _quote(bytes32 seriesId, bool yes, uint64 qty, uint8 limit, bool buy)
        private
        view
        returns (Quote memory q)
    {
        q.complete = qty == 0;
        if (q.complete) return q;
        IMontionsBook.Side side = yes == buy ? IMontionsBook.Side.Ask : IMontionsBook.Side.Bid;
        IMontionsBook.Level[] memory levels = book.depth(seriesId, side, 99);
        uint256 weightedTicks;
        for (uint256 i; i < levels.length && q.filled < qty; ++i) {
            uint8 price = yes ? levels[i].tick : 100 - levels[i].tick;
            // Depth is best-first: once a level exceeds the bound all later levels do too.
            if (buy ? price > limit : price < limit) break;
            uint64 take = levels[i].qty;
            uint64 remaining = qty - q.filled;
            if (take > remaining) take = remaining;
            if (take == 0) continue;
            q.filled += take;
            weightedTicks += uint256(take) * price;
            q.worstTick = price;
        }
        q.cost = weightedTicks * 10_000;
        if (q.filled != 0) {
            // Weighted prices stay within 1..99, and round-half-up in outcome ticks.
            // forge-lint: disable-next-line(unsafe-typecast)
            q.avgTick = uint8((weightedTicks + q.filled / 2) / q.filled);
        }
        q.complete = q.filled == qty;
    }

    /// @inheritdoc IQuoter
    function snapshot(bytes32 seriesId) public view override returns (Snapshot memory s) {
        s.seriesId = seriesId;
        try book.seriesInfo(seriesId) returns (IMontionsBook.SeriesInfo memory info) {
            s.info = info;
            (s.fairTick, s.probWad, s.volWad, s.spotWad) = fair(seriesId);
            if (info.resolver.code.length != 0) {
                try IResolver(info.resolver).describe(info.data, info.expiry) returns (string memory title) {
                    s.title = title;
                } catch {}
            }
        } catch {}
        try book.bestBidAsk(seriesId) returns (uint8 bid, uint64 bidQty, uint8 ask, uint64 askQty) {
            s.bidTick = bid;
            s.bidQty = bidQty;
            s.askTick = ask;
            s.askQty = askQty;
        } catch {}
        try book.lastTradeTick(seriesId) returns (uint8 tick) {
            s.lastTick = tick;
        } catch {}
    }

    /// @inheritdoc IQuoter
    /// @notice Pages at most 50 series; an offset past the end returns an empty array.
    function snapshots(uint256 offset, uint256 limit) external view override returns (Snapshot[] memory result) {
        uint256 count;
        try book.seriesCount() returns (uint256 n) {
            count = n;
        } catch {
            return new Snapshot[](0);
        }
        if (offset >= count) return new Snapshot[](0);
        if (limit > 50) limit = 50;
        if (limit > count - offset) limit = count - offset;
        result = new Snapshot[](limit);
        for (uint256 i; i < limit; ++i) {
            try book.seriesIdAt(offset + i) returns (bytes32 id) {
                result[i] = snapshot(id);
            } catch {}
        }
    }
}

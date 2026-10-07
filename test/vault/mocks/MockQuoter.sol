// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IQuoter} from "../../../src/interfaces/IQuoter.sol";
import {IMontionsBook} from "../../../src/interfaces/IMontionsBook.sol";

/// @title MockQuoter
/// @notice Test IQuoter with settable fair ticks. Unset series report fairTick = 0.
contract MockQuoter is IQuoter {
    IMontionsBook public immutable book;

    mapping(bytes32 seriesId => uint8 tick) public fairTickOf;
    mapping(bytes32 seriesId => uint256 wad) public probWadOf;
    mapping(bytes32 seriesId => uint256 wad) public volWadOf;
    mapping(bytes32 seriesId => uint256 wad) public spotWadOf;

    constructor(address book_) {
        book = IMontionsBook(book_);
    }

    /// @notice Sets the fair YES tick (0 = unsupported) and a matching probability.
    function setFair(bytes32 seriesId, uint8 fairTick) external {
        fairTickOf[seriesId] = fairTick;
        probWadOf[seriesId] = uint256(fairTick) * 1e16;
    }

    /// @notice Sets fair tick plus optional model extras.
    function setFairFull(bytes32 seriesId, uint8 fairTick, uint256 probWad, uint256 volWad, uint256 spotWad)
        external
    {
        fairTickOf[seriesId] = fairTick;
        probWadOf[seriesId] = probWad;
        volWadOf[seriesId] = volWad;
        spotWadOf[seriesId] = spotWad;
    }

    /// @inheritdoc IQuoter
    function fair(bytes32 seriesId)
        external
        view
        override
        returns (uint8 fairTick, uint256 probWad, uint256 volWad, uint256 spotWad)
    {
        return (fairTickOf[seriesId], probWadOf[seriesId], volWadOf[seriesId], spotWadOf[seriesId]);
    }

    /// @inheritdoc IQuoter
    function quoteBuy(bytes32, bool, uint64, uint8) external pure override returns (Quote memory q) {
        return q;
    }

    /// @inheritdoc IQuoter
    function quoteSell(bytes32, bool, uint64, uint8) external pure override returns (Quote memory q) {
        return q;
    }

    /// @inheritdoc IQuoter
    function snapshot(bytes32 seriesId) external view override returns (Snapshot memory snap) {
        snap.seriesId = seriesId;
        snap.fairTick = fairTickOf[seriesId];
        snap.probWad = probWadOf[seriesId];
        snap.volWad = volWadOf[seriesId];
        snap.spotWad = spotWadOf[seriesId];
        try book.seriesInfo(seriesId) returns (IMontionsBook.SeriesInfo memory info) {
            snap.info = info;
            (snap.bidTick, snap.bidQty, snap.askTick, snap.askQty) = book.bestBidAsk(seriesId);
            snap.lastTick = book.lastTradeTick(seriesId);
        } catch {}
    }

    /// @inheritdoc IQuoter
    function snapshots(uint256 offset, uint256 limit) external view override returns (Snapshot[] memory out) {
        uint256 n = book.seriesCount();
        if (offset >= n || limit == 0) return out;
        uint256 len = n - offset;
        if (len > limit) len = limit;
        out = new Snapshot[](len);
        for (uint256 i; i < len; ++i) {
            out[i] = this.snapshot(book.seriesIdAt(offset + i));
        }
    }
}

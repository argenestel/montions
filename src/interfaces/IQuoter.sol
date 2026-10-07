// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMontionsBook} from "./IMontionsBook.sol";

/// @title IQuoter
/// @notice Read-only pricing + order-walking helpers. Drives the "outcome-first" UX and the MakerVault.
interface IQuoter {
    struct Quote {
        uint64 filled;        // contracts that can be bought right now (<= requested)
        uint256 cost;         // USDC units to pay for `filled` contracts (excluding fee)
        uint8 avgTick;        // rounded average price in ticks
        uint8 worstTick;      // worst price touched
        bool complete;        // filled == requested
    }

    struct Snapshot {
        bytes32 seriesId;
        IMontionsBook.SeriesInfo info;
        uint8 bidTick; uint64 bidQty;
        uint8 askTick; uint64 askQty;
        uint8 lastTick;
        uint8 fairTick;       // 0 if no model for this resolver
        uint256 probWad;      // model P(YES), 1e18
        uint256 volWad;       // vol input used
        uint256 spotWad;      // underlying spot (0 if not a price series)
        string title;
    }

    /// @notice model fair value for price series (digital option, r = 0). fairTick == 0 and probWad == 0 if unsupported.
    function fair(bytes32 seriesId) external view returns (uint8 fairTick, uint256 probWad, uint256 volWad, uint256 spotWad);

    /// @notice cost to BUY `qty` of YES (yes=true) or NO (yes=false) by walking the book, not paying above `maxTick` (in that outcome's own price).
    function quoteBuy(bytes32 seriesId, bool yes, uint64 qty, uint8 maxTick) external view returns (Quote memory);

    /// @notice proceeds from SELLING `qty` held tokens of the given outcome into resting bids/asks, not below `minTick`.
    function quoteSell(bytes32 seriesId, bool yes, uint64 qty, uint8 minTick) external view returns (Quote memory);

    function snapshot(bytes32 seriesId) external view returns (Snapshot memory);
    function snapshots(uint256 offset, uint256 limit) external view returns (Snapshot[] memory);
}

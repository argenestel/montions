// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title TickBitmap
/// @notice Compact occupancy bitmap for the Book's price ticks.
/// @dev Bit zero is deliberately unused. Bits 1 through 99 represent the
///      valid Book ticks; bits outside that range are ignored by the lookup
///      helpers and removed by `set`/`unset`.
library TickBitmap {
    /// @notice A tick outside the Book's 1..99 range was supplied.
    error InvalidTick();

    uint8 internal constant MIN_TICK = 1;
    uint8 internal constant MAX_TICK = 99;
    uint128 internal constant VALID_MASK = uint128((uint256(1) << 100) - 2);

    /// @notice Sets the occupancy bit for `tick`.
    /// @param bitmap Existing occupancy bitmap.
    /// @param tick Book price tick in the inclusive range 1..99.
    /// @return updated Bitmap with `tick` occupied.
    function set(uint128 bitmap, uint8 tick) internal pure returns (uint128 updated) {
        _checkTick(tick);
        updated = (bitmap & VALID_MASK) | (uint128(1) << tick);
    }

    /// @notice Clears the occupancy bit for `tick`.
    /// @param bitmap Existing occupancy bitmap.
    /// @param tick Book price tick in the inclusive range 1..99.
    /// @return updated Bitmap with `tick` unoccupied.
    function unset(uint128 bitmap, uint8 tick) internal pure returns (uint128 updated) {
        _checkTick(tick);
        updated = (bitmap & VALID_MASK) & ~(uint128(1) << tick);
    }

    /// @notice Returns the lowest occupied valid tick.
    /// @param bitmap Occupancy bitmap.
    /// @return tick Lowest set bit in 1..99, or zero when no valid bit is set.
    function lowestSetBit(uint128 bitmap) internal pure returns (uint8 tick) {
        uint128 masked = bitmap & VALID_MASK;
        if (masked == 0) return 0;

        tick = MIN_TICK;
        while ((masked & (uint128(1) << tick)) == 0) {
            unchecked {
                ++tick;
            }
        }
    }

    /// @notice Returns the highest occupied valid tick.
    /// @param bitmap Occupancy bitmap.
    /// @return tick Highest set bit in 1..99, or zero when no valid bit is set.
    function highestSetBit(uint128 bitmap) internal pure returns (uint8 tick) {
        uint128 masked = bitmap & VALID_MASK;
        if (masked == 0) return 0;

        tick = MAX_TICK;
        while ((masked & (uint128(1) << tick)) == 0) {
            unchecked {
                --tick;
            }
        }
    }

    function _checkTick(uint8 tick) private pure {
        if (tick < MIN_TICK || tick > MAX_TICK) revert InvalidTick();
    }
}

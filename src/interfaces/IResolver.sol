// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IResolver
/// @notice Decides the outcome of a binary series entirely from onchain facts.
/// @dev Resolvers are whitelisted by the Book owner. `resolve` MUST be a deterministic, side-effect-free view that is
///      cheap (< 300k gas); the Book calls it with a gas cap and treats a revert as "not ready".
interface IResolver {
    /// @notice Revert if `data`/`expiry` are not a valid, well-formed market for this resolver.
    function validate(bytes calldata data, uint64 expiry) external view;

    /// @param data resolver-specific market definition (opaque to the Book)
    /// @param expiry unix seconds after which the series may be resolved
    /// @return ready false if the outcome cannot be determined yet (Book retries later; voids after the grace period)
    /// @return yes   the YES outcome; only meaningful when `ready`
    function resolve(bytes calldata data, uint64 expiry) external view returns (bool ready, bool yes);

    /// @notice Short human-readable title for UIs, e.g. "MON >= $1.50 at 2026-10-20 12:00 UTC (60s TWAP)".
    function describe(bytes calldata data, uint64 expiry) external view returns (string memory);
}

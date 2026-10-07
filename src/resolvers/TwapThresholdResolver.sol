// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IResolver} from "../interfaces/IResolver.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {LibString} from "solady/utils/LibString.sol";
import {ResolverFormat} from "./ResolverFormat.sol";

/// @title TwapThresholdResolver
/// @notice Resolves "TWAP of asset over the `window` seconds ending at `expiry` is >= (or <) strike".
/// @dev data = abi.encode(address oracle, bytes32 assetId, uint256 strikeWad, bool above, uint32 window).
///      YES iff above ? twap >= strike : twap < strike (so the two directions are exact complements).
///      Ready strictly after `expiry`. If the oracle reverts (e.g. HistoryUnavailable) the market is "not ready";
///      the Book retries and eventually voids after its grace period.
///      HONESTY: the price comes from the demo pool-TWAP oracle, which is manipulable at low liquidity. The demo uses
///      deep seeded pools; this is not a manipulation-resistant oracle.
///      The owner only controls the cosmetic `symbolOf` registry used by `describe`; it cannot affect resolution.
contract TwapThresholdResolver is IResolver, Ownable {
    error InvalidData();
    error InvalidStrike();
    error InvalidWindow(uint32 window);
    error InvalidExpiry(uint64 expiry);
    error ZeroOracle();

    uint32 public constant MIN_WINDOW = 30;
    uint32 public constant MAX_WINDOW = 3600;

    /// @notice assetId => display symbol (cosmetic, used only by `describe`).
    mapping(bytes32 => string) public symbolOf;

    event SymbolSet(bytes32 indexed assetId, string symbol);

    constructor() {
        _initializeOwner(msg.sender);
    }

    /// @notice Set the display symbol for an assetId (owner only; cosmetic).
    function setSymbol(bytes32 assetId, string calldata symbol) external onlyOwner {
        symbolOf[assetId] = symbol;
        emit SymbolSet(assetId, symbol);
    }

    /// @notice abi-encode market data.
    function encode(address oracle, bytes32 assetId, uint256 strikeWad, bool above, uint32 window)
        external
        pure
        returns (bytes memory)
    {
        return abi.encode(oracle, assetId, strikeWad, above, window);
    }

    /// @notice Decode market data. Wrong-length input reverts with InvalidData;
    ///         malformed ABI words also revert during Solidity decoding.
    function decode(bytes calldata data)
        public
        pure
        returns (address oracle, bytes32 assetId, uint256 strikeWad, bool above, uint32 window)
    {
        if (data.length != 160) revert InvalidData();
        (oracle, assetId, strikeWad, above, window) = abi.decode(data, (address, bytes32, uint256, bool, uint32));
    }

    /// @inheritdoc IResolver
    function validate(bytes calldata data, uint64 expiry) external view {
        (address oracle, bytes32 assetId, uint256 strikeWad,, uint32 window) = decode(data);
        if (oracle == address(0)) revert ZeroOracle();
        if (strikeWad == 0) revert InvalidStrike();
        if (window < MIN_WINDOW || window > MAX_WINDOW) revert InvalidWindow(window);
        // The Book performs its own duration bounds, while the resolver must at
        // least reject an already-expired market and timestamps too small for a
        // subtraction by the oracle's TWAP implementation.
        if (uint256(expiry) <= block.timestamp || expiry < window) revert InvalidExpiry(expiry);
        if (!IPriceOracle(oracle).assetExists(assetId)) revert IPriceOracle.UnknownAsset(assetId);
    }

    /// @inheritdoc IResolver
    function resolve(bytes calldata data, uint64 expiry) external view returns (bool ready, bool yes) {
        if (block.timestamp <= expiry) return (false, false);
        (address oracle, bytes32 assetId, uint256 strikeWad, bool above, uint32 window) = decode(data);
        // History may be unavailable until the pool has accumulated enough
        // observations. Treat every oracle revert as "not ready" so the Book
        // can retry and eventually apply its void grace period.
        try IPriceOracle(oracle).twapAt(assetId, expiry, window) returns (uint256 price) {
            return (true, above ? price >= strikeWad : price < strikeWad);
        } catch {
            return (false, false);
        }
    }

    /// @inheritdoc IResolver
    function describe(bytes calldata data, uint64 expiry) external view returns (string memory) {
        (, bytes32 assetId, uint256 strikeWad, bool above, uint32 window) = decode(data);
        string memory sym = symbolOf[assetId];
        if (bytes(sym).length == 0) sym = LibString.toHexString(uint256(assetId), 32);
        return string.concat(
            sym,
            above ? " >= " : " < ",
            ResolverFormat.usd(strikeWad),
            " at ",
            ResolverFormat.utc(expiry),
            " (",
            LibString.toString(window),
            "s TWAP)"
        );
    }
}

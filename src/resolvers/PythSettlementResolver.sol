// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IResolver} from "../interfaces/IResolver.sol";
import {IPriceOracle} from "../interfaces/IPriceOracle.sol";
import {IPyth} from "../oracle/pyth/IPyth.sol";
import {PythOracle} from "../oracle/pyth/PythOracle.sol";
import {Ownable} from "solady/auth/Ownable.sol";
import {ReentrancyGuard} from "solady/utils/ReentrancyGuard.sol";
import {LibString} from "solady/utils/LibString.sol";
import {ResolverFormat} from "./ResolverFormat.sol";

/// @title PythSettlementResolver
/// @notice Permissionlessly settles price-threshold series using a Pyth update in a fixed post-expiry window.
/// @dev data = abi.encode(address oracle, bytes32 assetId, uint256 strikeWad, bool above, uint32 maxDelay).
///      `maxDelay` is required to equal MAX_SETTLE_DELAY (300 seconds), matching the single settlement key
///      `(assetId, expiry)`. The Pyth parser's unique-first rule prevents callers selecting a later update.
///      Confidence is stored in Pyth's raw feed units; price is normalised to WAD. A bad/negative price or
///      confidence above 2% is persisted as invalid, so the Book voids after its normal grace period.
contract PythSettlementResolver is IResolver, Ownable, ReentrancyGuard {
    uint32 public constant MAX_SETTLE_DELAY = 300;
    uint32 public constant MIN_SETTLE_DELAY = 30;
    uint32 public constant MAX_ALLOWED_SETTLE_DELAY = 3600;

    struct Settlement {
        int256 priceWad;
        uint64 publishTime;
        uint64 conf; // Raw Pyth confidence units (same scale as Price.price).
        bool valid;
    }

    IPyth public immutable pyth;
    PythOracle public immutable oracle;
    mapping(bytes32 assetId => mapping(uint64 expiry => Settlement settlement)) public settlements;
    mapping(bytes32 assetId => mapping(uint64 expiry => bool exists)) public isSettled;
    mapping(bytes32 assetId => string symbol) public symbolOf;

    error ZeroAddress();
    error InvalidData();
    error InvalidStrike();
    error InvalidMaxDelay(uint32 maxDelay);
    error InvalidExpiry(uint64 expiry);
    error UntrustedOracle();
    error AlreadySettled(bytes32 assetId, uint64 expiry);
    error NotExpired(uint64 expiry);
    error InsufficientFee(uint256 required, uint256 supplied);
    error SettlementWindowOverflow(uint64 expiry);
    error InvalidPythResponse();
    error RefundFailed(address recipient, uint256 amount);

    event SettlementStored(
        bytes32 indexed assetId, uint64 indexed expiry, int256 priceWad, uint64 publishTime, uint64 conf, bool valid
    );
    event SymbolSet(bytes32 indexed assetId, string symbol);

    /// @notice Bind settlement to one Pyth contract and one PythOracle adapter.
    constructor(address pyth_, address oracle_, address owner_) {
        if (pyth_ == address(0) || oracle_ == address(0) || owner_ == address(0)) revert ZeroAddress();
        pyth = IPyth(pyth_);
        oracle = PythOracle(oracle_);
        _initializeOwner(owner_);
    }

    /// @notice Set the display symbol used by `describe`; it does not affect validation or outcomes.
    function setSymbol(bytes32 assetId, string calldata symbol) external onlyOwner {
        symbolOf[assetId] = symbol;
        emit SymbolSet(assetId, symbol);
    }

    /// @notice ABI-encode resolver data using the shared price-series layout.
    function encode(address oracle_, bytes32 assetId, uint256 strikeWad, bool above, uint32 maxDelay)
        external
        pure
        returns (bytes memory)
    {
        return abi.encode(oracle_, assetId, strikeWad, above, maxDelay);
    }

    /// @notice Decode the shared price-series ABI layout.
    function decode(bytes calldata data)
        public
        pure
        returns (address oracle_, bytes32 assetId, uint256 strikeWad, bool above, uint32 maxDelay)
    {
        if (data.length != 160) revert InvalidData();
        return abi.decode(data, (address, bytes32, uint256, bool, uint32));
    }

    /// @inheritdoc IResolver
    function validate(bytes calldata data, uint64 expiry) external view override {
        if (data.length > 512) revert InvalidData();
        (address oracle_, bytes32 assetId, uint256 strikeWad,, uint32 maxDelay) = decode(data);
        if (oracle_ != address(oracle)) revert UntrustedOracle();
        if (strikeWad == 0) revert InvalidStrike();
        if (maxDelay < MIN_SETTLE_DELAY || maxDelay > MAX_ALLOWED_SETTLE_DELAY) {
            revert InvalidMaxDelay(maxDelay);
        }
        // All series sharing (assetId, expiry) must use the identical onchain update window.
        if (maxDelay != MAX_SETTLE_DELAY) revert InvalidMaxDelay(maxDelay);
        if (uint256(expiry) <= block.timestamp) revert InvalidExpiry(expiry);
        if (!oracle.assetExists(assetId)) revert IPriceOracle.UnknownAsset(assetId);
    }

    /// @notice Settle once with the first Pyth update in the inclusive [expiry, expiry + 300] publish-time window.
    /// @dev Caller pays Pyth's exact update fee; excess ETH is safely refunded. Stored invalid settlements remain
    ///      not-ready so the Book can void after VOID_GRACE. `nonReentrant` also protects the refund interaction.
    function settle(bytes32 assetId, uint64 expiry, bytes[] calldata updateData) external payable nonReentrant {
        if (isSettled[assetId][expiry]) revert AlreadySettled(assetId, expiry);
        if (block.timestamp <= expiry) revert NotExpired(expiry);
        uint256 maxPublish = uint256(expiry) + MAX_SETTLE_DELAY;
        if (maxPublish > type(uint64).max) revert SettlementWindowOverflow(expiry);

        (IPyth.Price memory update, uint256 fee) = _parseUpdate(assetId, expiry, uint64(maxPublish), updateData);
        _storeSettlement(assetId, expiry, update);

        uint256 refund = msg.value - fee;
        if (refund != 0) {
            (bool ok,) = payable(msg.sender).call{value: refund}("");
            if (!ok) revert RefundFailed(msg.sender, refund);
        }
    }

    /// @inheritdoc IResolver
    function resolve(bytes calldata data, uint64 expiry) external view override returns (bool ready, bool yes) {
        if (block.timestamp <= expiry || data.length != 160) return (false, false);
        (address oracle_, bytes32 assetId, uint256 strikeWad, bool above,) = decode(data);
        if (oracle_ != address(oracle)) return (false, false);
        if (!isSettled[assetId][expiry]) return (false, false);
        Settlement memory result = settlements[assetId][expiry];
        if (!result.valid) return (false, false);
        return (true, above ? uint256(result.priceWad) >= strikeWad : uint256(result.priceWad) < strikeWad);
    }

    /// @inheritdoc IResolver
    function describe(bytes calldata data, uint64 expiry) external view override returns (string memory) {
        (, bytes32 assetId, uint256 strikeWad, bool above, uint32 maxDelay) = decode(data);
        string memory symbol = symbolOf[assetId];
        if (bytes(symbol).length == 0) symbol = LibString.toHexString(uint256(assetId), 32);
        return string.concat(
            symbol,
            above ? " >= " : " < ",
            ResolverFormat.usd(strikeWad),
            " at ",
            ResolverFormat.utc(expiry),
            " (Pyth update within ",
            LibString.toString(maxDelay),
            "s)"
        );
    }

    function _parseUpdate(bytes32 assetId, uint64 expiry, uint64 maxPublish, bytes[] calldata updateData)
        private
        returns (IPyth.Price memory update, uint256 fee)
    {
        bytes32 feedId = oracle.feedIdOf(assetId);
        fee = pyth.getUpdateFee(updateData);
        if (msg.value < fee) revert InsufficientFee(fee, msg.value);
        bytes32[] memory priceIds = new bytes32[](1);
        priceIds[0] = feedId;
        IPyth.PriceFeed[] memory feeds =
            pyth.parsePriceFeedUpdatesUnique{value: fee}(updateData, priceIds, expiry, maxPublish);
        if (feeds.length != 1 || feeds[0].id != feedId) revert InvalidPythResponse();
        update = feeds[0].price;
        uint256 maxPublishTime = uint256(maxPublish);
        if (update.publishTime < expiry || update.publishTime > maxPublishTime || update.publishTime > type(uint64).max)
        {
            revert InvalidPythResponse();
        }
    }

    function _storeSettlement(bytes32 assetId, uint64 expiry, IPyth.Price memory update) private {
        (int256 normalised, bool exponentSupported) = _normalise(update.price, update.expo);
        bool valid =
            exponentSupported && update.price > 0 && uint256(update.conf) * 100 <= uint256(uint64(update.price)) * 2;
        int256 priceWad = normalised;
        Settlement memory result =
            Settlement({priceWad: priceWad, publishTime: uint64(update.publishTime), conf: update.conf, valid: valid});
        settlements[assetId][expiry] = result;
        isSettled[assetId][expiry] = true;
        emit SettlementStored(assetId, expiry, result.priceWad, result.publishTime, result.conf, result.valid);
    }

    function _normalise(int64 rawPrice, int32 expo) private pure returns (int256 value, bool supported) {
        if (expo < -18 || expo > 0) return (0, false);
        value = int256(rawPrice) * int256(10 ** uint32(int32(18) + expo));
        return (value, true);
    }
}

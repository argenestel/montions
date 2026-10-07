// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPriceOracle} from "../../../src/interfaces/IPriceOracle.sol";

/// @dev Test-only oracle with configurable asset existence, TWAP result, and
///      failure paths. It intentionally has no production behavior.
contract MockOracle is IPriceOracle {
    error TwapFailed();

    mapping(bytes32 => bool) private _assets;
    mapping(bytes32 => uint256) private _prices;
    mapping(bytes32 => uint64) private _updatedAt;
    bool public twapFails;
    bool public assetExistsFails;

    function setAsset(bytes32 assetId, bool exists) external {
        _assets[assetId] = exists;
    }

    function setPrice(bytes32 assetId, uint256 priceWad) external {
        _prices[assetId] = priceWad;
        _updatedAt[assetId] = uint64(block.timestamp);
    }

    function setTwapFails(bool fails) external {
        twapFails = fails;
    }

    function setAssetExistsFails(bool fails) external {
        assetExistsFails = fails;
    }

    function assetExists(bytes32 assetId) external view override returns (bool) {
        if (assetExistsFails) revert TwapFailed();
        return _assets[assetId];
    }

    function latestPrice(bytes32 assetId) external view override returns (uint256 priceWad, uint64 updatedAt) {
        if (!_assets[assetId]) revert UnknownAsset(assetId);
        return (_prices[assetId], _updatedAt[assetId]);
    }

    function twapAt(bytes32 assetId, uint64, uint32) external view override returns (uint256 priceWad) {
        if (twapFails) revert TwapFailed();
        if (!_assets[assetId]) revert UnknownAsset(assetId);
        return _prices[assetId];
    }

    function realizedVol(bytes32 assetId, uint32, uint32) external view override returns (uint256 volWad) {
        if (!_assets[assetId]) revert UnknownAsset(assetId);
        return 0;
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IPriceOracle} from "../../../src/interfaces/IPriceOracle.sol";

/// @dev Configurable test oracle. It intentionally models only deterministic
///      view responses and explicit failure switches used by Quoter tests.
contract MockPriceOracle is IPriceOracle {
    error ForcedRevert();

    mapping(bytes32 => bool) private _exists;
    mapping(bytes32 => uint256) private _price;
    mapping(bytes32 => uint256) private _vol;
    mapping(bytes32 => uint64) private _updatedAt;
    bool public revertLatest;
    bool public revertVol;

    function setAsset(bytes32 assetId, bool exists_) external {
        _exists[assetId] = exists_;
    }

    function setPrice(bytes32 assetId, uint256 priceWad) external {
        _price[assetId] = priceWad;
        _updatedAt[assetId] = uint64(block.timestamp);
    }

    function setVol(bytes32 assetId, uint256 volWad) external {
        _vol[assetId] = volWad;
    }

    function setFailures(bool latest_, bool vol_) external {
        revertLatest = latest_;
        revertVol = vol_;
    }

    function assetExists(bytes32 assetId) external view returns (bool) {
        return _exists[assetId];
    }

    function latestPrice(bytes32 assetId) external view returns (uint256 priceWad, uint64 updatedAt) {
        if (revertLatest || !_exists[assetId]) revert ForcedRevert();
        return (_price[assetId], _updatedAt[assetId]);
    }

    function twapAt(bytes32 assetId, uint64, uint32) external view returns (uint256 priceWad) {
        if (!_exists[assetId]) revert ForcedRevert();
        return _price[assetId];
    }

    function realizedVol(bytes32 assetId, uint32, uint32) external view returns (uint256 volWad) {
        if (revertVol || !_exists[assetId]) revert ForcedRevert();
        return _vol[assetId];
    }
}

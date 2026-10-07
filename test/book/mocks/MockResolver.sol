// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IResolver} from "../../../src/interfaces/IResolver.sol";

/// @title MockResolver
/// @notice Configurable resolver used by Book tests.
contract MockResolver is IResolver {
    bool public ready;
    bool public yes;
    bool public validationReverts;
    bool public resolutionReverts;
    bool public consumeGas;

    error ValidationReverted();
    error ResolutionReverted();

    /// @notice Updates the result returned by `resolve`.
    /// @param ready_ Whether the result is currently ready.
    /// @param yes_ The YES/NO result when ready.
    function setResult(bool ready_, bool yes_) external {
        ready = ready_;
        yes = yes_;
    }

    /// @notice Configures validation and resolution to revert for failure-path tests.
    /// @param validation Whether `validate` should revert.
    /// @param resolution Whether `resolve` should revert.
    function setReverts(bool validation, bool resolution) external {
        validationReverts = validation;
        resolutionReverts = resolution;
    }

    /// @notice Makes resolution consume its entire caller gas stipend.
    /// @param enabled Whether to enter the gas-burning loop.
    function setConsumeGas(bool enabled) external {
        consumeGas = enabled;
    }

    /// @inheritdoc IResolver
    function validate(bytes calldata, uint64) external view override {
        if (validationReverts) revert ValidationReverted();
    }

    /// @inheritdoc IResolver
    function resolve(bytes calldata, uint64) external view override returns (bool, bool) {
        if (resolutionReverts) revert ResolutionReverted();
        if (consumeGas) {
            assembly {
                for {} 1 {} {}
            }
        }
        return (ready, yes);
    }

    /// @inheritdoc IResolver
    function describe(bytes calldata, uint64) external pure override returns (string memory) {
        return "Mock resolver";
    }
}

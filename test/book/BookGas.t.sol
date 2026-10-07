// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {BookTestBase} from "./BookTestBase.sol";
import {IMontionsBook} from "../../src/interfaces/IMontionsBook.sol";

/// @notice Focused `gasleft` measurements for the requested matching depths.
contract BookGasTest is BookTestBase {
    function testGasPlaceOrder0Fills() public {
        _deposit(ALICE, 2_000_000);
        IMontionsBook.PlaceParams memory params =
            _params(series, IMontionsBook.Side.Bid, 30, 1, false, IMontionsBook.TIF.GTC, 0);
        vm.prank(ALICE);
        uint256 beforeGas = gasleft();
        book.placeOrder(params);
        emit log_named_uint("placeOrder 0 fills gas", beforeGas - gasleft());
    }

    function testGasPlaceOrder1Fill() public {
        _deposit(ALICE, 2_000_000);
        _deposit(BOB, 2_000_000);
        _place(ALICE, IMontionsBook.Side.Ask, 40, 1, false, IMontionsBook.TIF.GTC, 0);
        IMontionsBook.PlaceParams memory params =
            _params(series, IMontionsBook.Side.Bid, 50, 1, false, IMontionsBook.TIF.GTC, 0);
        vm.prank(BOB);
        uint256 beforeGas = gasleft();
        book.placeOrder(params);
        emit log_named_uint("placeOrder 1 fill gas", beforeGas - gasleft());
    }

    function testGasPlaceOrder10Fills() public {
        _deposit(ALICE, 20_000_000);
        _deposit(BOB, 20_000_000);
        for (uint256 i; i < 10; ++i) {
            _place(ALICE, IMontionsBook.Side.Ask, 40, 1, false, IMontionsBook.TIF.GTC, 0);
        }
        IMontionsBook.PlaceParams memory params =
            _params(series, IMontionsBook.Side.Bid, 50, 10, false, IMontionsBook.TIF.GTC, 10);
        vm.prank(BOB);
        uint256 beforeGas = gasleft();
        book.placeOrder(params);
        emit log_named_uint("placeOrder 10 fills gas", beforeGas - gasleft());
    }
}

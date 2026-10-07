// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IMontionsBook} from "../../src/interfaces/IMontionsBook.sol";
import {MontionsBook} from "../../src/MontionsBook.sol";
import {TestUSDC} from "./mocks/TestUSDC.sol";
import {MockResolver} from "./mocks/MockResolver.sol";

/// @notice Shared fixtures and small helpers for the Book unit tests.
/// @dev Keep setup intentionally boring: the behavioural tests should exercise
///      the public interface rather than reach into implementation storage.
abstract contract BookTestBase is Test {
    uint256 internal constant UNIT = 1_000_000;
    uint256 internal constant TICK_UNIT = 10_000;

    address internal constant BOOK_OWNER = address(0xB00C);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant CAROL = address(0xCA801);
    address internal constant DAVE = address(0xDA0E);

    TestUSDC internal usdc;
    MockResolver internal resolver;
    MontionsBook internal book;
    bytes32 internal series;
    uint64 internal expiry;

    function setUp() public virtual {
        usdc = new TestUSDC(address(this));
        resolver = new MockResolver();
        book = new MontionsBook(address(usdc), BOOK_OWNER);

        vm.prank(BOOK_OWNER);
        book.setResolverAllowed(address(resolver), true);

        _fund(ALICE, 1_000_000_000);
        _fund(BOB, 1_000_000_000);
        _fund(CAROL, 1_000_000_000);
        _fund(DAVE, 1_000_000_000);
        _approve(ALICE);
        _approve(BOB);
        _approve(CAROL);
        _approve(DAVE);

        expiry = uint64(block.timestamp + book.MIN_DURATION() + 1 days);
        series = _createSeries(expiry);
    }

    function _fund(address user, uint256 amount) internal {
        usdc.mint(user, amount);
    }

    function _approve(address user) internal {
        vm.prank(user);
        usdc.approve(address(book), type(uint256).max);
    }

    function _deposit(address user, uint256 amount) internal {
        vm.prank(user);
        book.deposit(amount);
    }

    function _depositAll(address user) internal {
        _deposit(user, usdc.balanceOf(user));
    }

    function _createSeries(uint64 expiresAt) internal returns (bytes32 id) {
        vm.prank(ALICE);
        id = book.createSeries(address(resolver), bytes("fixture"), expiresAt);
    }

    function _newSeries(uint64 expiresAt) internal returns (bytes32 id) {
        id = _createSeries(expiresAt);
    }

    function _params(
        bytes32 id,
        IMontionsBook.Side side,
        uint8 tick,
        uint64 qty,
        bool fromHeld,
        IMontionsBook.TIF tif,
        uint16 maxFills
    ) internal pure returns (IMontionsBook.PlaceParams memory p) {
        p = IMontionsBook.PlaceParams({
            seriesId: id, side: side, tick: tick, qty: qty, fromHeld: fromHeld, tif: tif, maxFills: maxFills
        });
    }

    function _place(
        address user,
        IMontionsBook.Side side,
        uint8 tick,
        uint64 qty,
        bool fromHeld,
        IMontionsBook.TIF tif,
        uint16 maxFills
    ) internal returns (uint64 orderId, uint64 filled, uint64 resting) {
        IMontionsBook.PlaceParams memory p = _params(series, side, tick, qty, fromHeld, tif, maxFills);
        vm.prank(user);
        return book.placeOrder(p);
    }

    function _placeOn(
        address user,
        bytes32 id,
        IMontionsBook.Side side,
        uint8 tick,
        uint64 qty,
        bool fromHeld,
        IMontionsBook.TIF tif,
        uint16 maxFills
    ) internal returns (uint64 orderId, uint64 filled, uint64 resting) {
        IMontionsBook.PlaceParams memory p = _params(id, side, tick, qty, fromHeld, tif, maxFills);
        vm.prank(user);
        return book.placeOrder(p);
    }

    function _split(address user, uint64 qty) internal {
        vm.prank(user);
        book.split(series, qty);
    }

    function _merge(address user, uint64 qty) internal {
        vm.prank(user);
        book.merge(series, qty);
    }

    function _balance(address user) internal view returns (uint256) {
        return usdc.balanceOf(user);
    }

    function _yesId() internal view returns (uint256) {
        return book.seriesInfo(series).yesId;
    }

    function _noId() internal view returns (uint256) {
        return book.seriesInfo(series).noId;
    }

    function _warpExpired() internal {
        vm.warp(expiry);
    }

    function _warpVoidable() internal {
        vm.warp(uint256(expiry) + book.VOID_GRACE());
    }

    function _assertSolvent() internal view {
        uint256 liabilities = book.protocolFees() + book.pool(series);
        liabilities += book.cash(ALICE) + book.lockedCash(ALICE);
        liabilities += book.cash(BOB) + book.lockedCash(BOB);
        liabilities += book.cash(CAROL) + book.lockedCash(CAROL);
        liabilities += book.cash(DAVE) + book.lockedCash(DAVE);
        assertEq(book.totalCollateral(), liabilities);
        assertEq(usdc.balanceOf(address(book)), book.totalCollateral());
    }
}

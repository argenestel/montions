// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IMontionsBook} from "../../src/interfaces/IMontionsBook.sol";
import {MontionsBook} from "../../src/MontionsBook.sol";
import {TestUSDC} from "../../src/mocks/TestUSDC.sol";
import {MakerVault} from "../../src/MakerVault.sol";
import {MockQuoter} from "./mocks/MockQuoter.sol";
import {MockResolver} from "../book/mocks/MockResolver.sol";

/// @notice Shared fixtures for MakerVault tests.
abstract contract VaultTestBase is Test {
    uint256 internal constant UNIT = 1_000_000;
    uint256 internal constant TICK_UNIT = 10_000;

    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    address internal constant TAKER = address(0x7A4E);
    address internal constant KEEPER = address(0x4EE9);
    address internal constant ATTACKER = address(0xA77);

    TestUSDC internal usdc;
    MockResolver internal resolver;
    MontionsBook internal book;
    MockQuoter internal quoter;
    MakerVault internal vault;

    bytes32 internal series;
    uint64 internal expiry;

    function setUp() public virtual {
        usdc = new TestUSDC(address(this));
        resolver = new MockResolver();
        book = new MontionsBook(address(usdc), address(this));
        book.setResolverAllowed(address(resolver), true);

        quoter = new MockQuoter(address(book));
        vault = new MakerVault(address(book), address(quoter), address(this));
        vault.setTrustedResolver(address(resolver));
        vault.setKeeper(KEEPER);

        expiry = uint64(block.timestamp + 1 days);
        series = _createSeries(bytes("vault-series"), expiry);
        quoter.setFair(series, 50);

        _fund(ALICE, 1_000_000e6);
        _fund(BOB, 1_000_000e6);
        _fund(TAKER, 1_000_000e6);
        _fund(ATTACKER, 1_000_000e6);
        _approveAll(ALICE);
        _approveAll(BOB);
        _approveAll(TAKER);
        _approveAll(ATTACKER);
    }

    function _fund(address user, uint256 amount) internal {
        usdc.mint(user, amount);
    }

    function _approveAll(address user) internal {
        vm.startPrank(user);
        usdc.approve(address(vault), type(uint256).max);
        usdc.approve(address(book), type(uint256).max);
        vm.stopPrank();
    }

    function _createSeries(bytes memory data, uint64 expiresAt) internal returns (bytes32 id) {
        id = book.createSeries(address(resolver), data, expiresAt);
    }

    function _depositVault(address user, uint256 assets) internal returns (uint256 shares) {
        vm.prank(user);
        shares = vault.deposit(assets, user);
    }

    function _refresh() internal {
        vm.prank(KEEPER);
        vault.refresh(series);
    }

    function _openOrders() internal view returns (IMontionsBook.OrderView[] memory open_) {
        uint64[] memory ids = vault.trackedOrders(series);
        uint256 n;
        IMontionsBook.OrderView[] memory tmp = new IMontionsBook.OrderView[](ids.length);
        for (uint256 i; i < ids.length; ++i) {
            IMontionsBook.OrderView memory ov = book.orderInfo(ids[i]);
            if (ov.open) {
                tmp[n] = ov;
                unchecked {
                    ++n;
                }
            }
        }
        open_ = new IMontionsBook.OrderView[](n);
        for (uint256 i; i < n; ++i) {
            open_[i] = tmp[i];
        }
    }

    function _expectedQty(uint256 nav, uint256 tickWeight) internal view returns (uint64) {
        uint256 seriesCap = nav * vault.maxSeriesExposureBps() / 10_000;
        uint256 globalCap = nav * vault.maxGlobalExposureBps() / 10_000;
        uint256 minFree = nav * vault.minFreeCashBps() / 10_000;
        uint256 free = book.cash(address(vault));
        uint256 budget = seriesCap;
        if (globalCap < budget) budget = globalCap;
        if (free > minFree) {
            uint256 freeRoom = free - minFree;
            if (freeRoom < budget) budget = freeRoom;
        } else {
            budget = 0;
        }
        if (tickWeight == 0 || budget == 0) return 0;
        uint256 raw = budget / (tickWeight * TICK_UNIT);
        if (raw > type(uint64).max) raw = type(uint64).max;
        return uint64(raw);
    }

    function _tickWeight(uint8[] memory bids, uint8[] memory asks) internal pure returns (uint256 w) {
        for (uint256 i; i < bids.length; ++i) {
            w += bids[i];
        }
        for (uint256 i; i < asks.length; ++i) {
            w += (100 - asks[i]);
        }
    }

    function _placeTaker(
        address user,
        IMontionsBook.Side side,
        uint8 tick,
        uint64 qty,
        bool fromHeld,
        IMontionsBook.TIF tif
    ) internal returns (uint64 orderId, uint64 filled, uint64 resting) {
        IMontionsBook.PlaceParams memory p = IMontionsBook.PlaceParams({
            seriesId: series, side: side, tick: tick, qty: qty, fromHeld: fromHeld, tif: tif, maxFills: 32
        });
        vm.prank(user);
        return book.placeOrder(p);
    }
}

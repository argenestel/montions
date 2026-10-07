// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IPyth} from "../../src/oracle/pyth/IPyth.sol";
import {PythOracle} from "../../src/oracle/pyth/PythOracle.sol";
import {PythSettlementResolver} from "../../src/resolvers/PythSettlementResolver.sol";
import {MontionsBook} from "../../src/MontionsBook.sol";
import {IMontionsBook} from "../../src/interfaces/IMontionsBook.sol";
import {TestUSDC} from "../book/mocks/TestUSDC.sol";
import {MockPyth} from "./mocks/MockPyth.sol";

abstract contract PythTestBase is Test {
    uint256 internal constant START = 1_700_000_000;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant UNIT = 1e6;
    uint256 internal constant TICK_UNIT = 10_000;
    bytes32 internal constant ASSET = keccak256("MON");
    bytes32 internal constant FEED = bytes32(uint256(0x31491744));
    address internal constant BOOK_OWNER = address(0xB00C);
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);

    MockPyth internal pyth;
    PythOracle internal oracle;
    PythSettlementResolver internal resolver;
    TestUSDC internal usdc;
    MontionsBook internal book;

    function setUp() public virtual {
        _deployOracleStack();
    }

    function _deployOracleStack() internal {
        vm.warp(START);
        pyth = new MockPyth();
        pyth.setPrice(FEED, 100_000_000, 100_000, -8, block.timestamp);
        pyth.setFee(100);
        oracle = new PythOracle(address(pyth), address(this));
        oracle.setFeed(ASSET, FEED, 0.8e18, 60);
        resolver = new PythSettlementResolver(address(pyth), address(oracle), address(this));
    }

    function _deployBook() internal {
        usdc = new TestUSDC(address(this));
        book = new MontionsBook(address(usdc), BOOK_OWNER);
        vm.prank(BOOK_OWNER);
        book.setResolverAllowed(address(resolver), true);
        usdc.mint(ALICE, 10 * UNIT);
        usdc.mint(BOB, 10 * UNIT);
        vm.prank(ALICE);
        usdc.approve(address(book), type(uint256).max);
        vm.prank(BOB);
        usdc.approve(address(book), type(uint256).max);
    }

    function _update(bytes32 feedId, int64 rawPrice, uint64 conf, int32 expo, uint256 publishTime)
        internal
        returns (bytes[] memory data)
    {
        pyth.addPriceFeedUpdate(feedId, rawPrice, conf, expo, publishTime, rawPrice, conf, expo, publishTime);
        data = new bytes[](1);
        data[0] = pyth.updateDataAt(feedId, pyth.historyLength(feedId) - 1);
    }

    function _data(uint256 strike, bool above, uint64 maxDelay) internal view returns (bytes memory) {
        return abi.encode(address(oracle), ASSET, strike, above, maxDelay);
    }

    function _createSeries(uint64 expiry, uint256 strike, bool above) internal returns (bytes32 seriesId) {
        seriesId = book.createSeries(address(resolver), _data(strike, above, resolver.MAX_SETTLE_DELAY()), expiry);
    }

    function _bookPlace(address user, bytes32 seriesId, IMontionsBook.Side side, uint8 tick, uint64 qty)
        internal
        returns (uint64 orderId, uint64 filled, uint64 resting)
    {
        IMontionsBook.PlaceParams memory params = IMontionsBook.PlaceParams({
            seriesId: seriesId,
            side: side,
            tick: tick,
            qty: qty,
            fromHeld: false,
            tif: IMontionsBook.TIF.GTC,
            maxFills: 0
        });
        vm.prank(user);
        return book.placeOrder(params);
    }
}

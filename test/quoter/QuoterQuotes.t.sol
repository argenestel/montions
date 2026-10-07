// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {Quoter} from "../../src/Quoter.sol";
import {IQuoter} from "../../src/interfaces/IQuoter.sol";
import {IMontionsBook} from "../../src/interfaces/IMontionsBook.sol";
import {MockBook} from "./mocks/MockBook.sol";

contract QuoterQuotesTest is Test {
    MockBook internal book;
    Quoter internal quoter;
    bytes32 internal constant ID = keccak256("quotes");

    function setUp() public {
        book = new MockBook();
        quoter = new Quoter(address(book), address(0x1234));
        book.setSeries(ID, address(0x1234), "", 1_000_000, IMontionsBook.Status.Open, false, 1, 2, 1);
        _depth(IMontionsBook.Side.Ask, 40, 50, 60);
        _depth(IMontionsBook.Side.Bid, 60, 50, 40);
    }

    function _depth(IMontionsBook.Side side, uint8 a, uint8 b, uint8 c) internal {
        uint8[] memory ticks = new uint8[](3);
        uint64[] memory quantities = new uint64[](3);
        ticks[0] = a;
        ticks[1] = b;
        ticks[2] = c;
        quantities[0] = 2;
        quantities[1] = 3;
        quantities[2] = 4;
        book.setDepth(ID, side, ticks, quantities);
    }

    function _assertQuote(IQuoter.Quote memory q, uint64 filled, uint256 ticks, uint8 avg, uint8 worst, bool complete)
        internal
        pure
    {
        assertEq(q.filled, filled);
        assertEq(q.cost, ticks * 10_000);
        assertEq(q.avgTick, avg);
        assertEq(q.worstTick, worst);
        assertEq(q.complete, complete);
    }

    function testBuyYesAndNoCompleteWithPartialLastLevel() public view {
        _assertQuote(quoter.quoteBuy(ID, true, 6, 60), 6, 290, 48, 60, true);
        _assertQuote(quoter.quoteBuy(ID, false, 6, 60), 6, 290, 48, 60, true);
    }

    function testSellYesAndCloseNoCompleteWithPartialLastLevel() public view {
        _assertQuote(quoter.quoteSell(ID, true, 6, 40), 6, 310, 52, 40, true);
        _assertQuote(quoter.quoteSell(ID, false, 6, 40), 6, 310, 52, 40, true);
    }

    function testBuyBoundsAreInclusiveInOutcomePrice() public view {
        for (uint256 i; i < 2; ++i) {
            bool yes = i == 0;
            _assertQuote(quoter.quoteBuy(ID, yes, 9, 50), 5, 230, 46, 50, false);
            _assertQuote(quoter.quoteBuy(ID, yes, 9, 49), 2, 80, 40, 40, false);
            _assertQuote(quoter.quoteBuy(ID, yes, 9, 39), 0, 0, 0, 0, false);
        }
    }

    function testSellBoundsAreInclusiveInOutcomePrice() public view {
        for (uint256 i; i < 2; ++i) {
            bool yes = i == 0;
            _assertQuote(quoter.quoteSell(ID, yes, 9, 50), 5, 270, 54, 50, false);
            _assertQuote(quoter.quoteSell(ID, yes, 9, 51), 2, 120, 60, 60, false);
            _assertQuote(quoter.quoteSell(ID, yes, 9, 61), 0, 0, 0, 0, false);
        }
    }

    function testInsufficientDepthEmptyBooksAndZeroQty() public {
        for (uint256 i; i < 2; ++i) {
            bool yes = i == 0;
            _assertQuote(quoter.quoteBuy(ID, yes, 10, 99), 9, 470, 52, 60, false);
            _assertQuote(quoter.quoteSell(ID, yes, 10, 1), 9, 430, 48, 40, false);
        }
        book.clearDepth(ID, IMontionsBook.Side.Ask);
        book.clearDepth(ID, IMontionsBook.Side.Bid);
        for (uint256 i; i < 2; ++i) {
            bool yes = i == 0;
            _assertQuote(quoter.quoteBuy(ID, yes, 1, 99), 0, 0, 0, 0, false);
            _assertQuote(quoter.quoteSell(ID, yes, 1, 1), 0, 0, 0, 0, false);
            _assertQuote(quoter.quoteBuy(ID, yes, 0, 99), 0, 0, 0, 0, true);
            _assertQuote(quoter.quoteSell(ID, yes, 0, 1), 0, 0, 0, 0, true);
        }
    }

    function testHalfUpRoundingAndZeroQuantityLevels() public {
        uint8[] memory ticks = new uint8[](3);
        uint64[] memory quantities = new uint64[](3);
        ticks[0] = 40;
        ticks[1] = 41;
        ticks[2] = 42;
        quantities[0] = 0;
        quantities[1] = 1;
        quantities[2] = 1;
        book.setDepth(ID, IMontionsBook.Side.Ask, ticks, quantities);
        _assertQuote(quoter.quoteBuy(ID, true, 2, 99), 2, 83, 42, 42, true);
        _assertQuote(quoter.quoteSell(ID, false, 2, 1), 2, 117, 59, 58, true);
    }

    function testDepthRequestsAll99Levels() public {
        uint8[] memory ticks = new uint8[](99);
        uint64[] memory quantities = new uint64[](99);
        for (uint8 i; i < 99; ++i) {
            ticks[i] = i + 1;
            quantities[i] = 1;
        }
        book.setDepth(ID, IMontionsBook.Side.Ask, ticks, quantities);
        book.setDepth(ID, IMontionsBook.Side.Bid, ticks, quantities);
        _assertQuote(quoter.quoteBuy(ID, true, 99, 99), 99, 4950, 50, 99, true);
        _assertQuote(quoter.quoteBuy(ID, false, 99, 99), 99, 4950, 50, 99, true);
        _assertQuote(quoter.quoteSell(ID, true, 99, 1), 99, 4950, 50, 1, true);
        _assertQuote(quoter.quoteSell(ID, false, 99, 1), 99, 4950, 50, 1, true);
    }

    function testFuzzSingleLevelOutcomePrice(bool yes, bool buy, uint8 tick, uint64 qty, uint64 available, uint8 limit)
        public
    {
        tick = uint8(bound(tick, 1, 99));
        uint8[] memory ticks = new uint8[](1);
        uint64[] memory quantities = new uint64[](1);
        ticks[0] = tick;
        quantities[0] = available;
        book.setDepth(ID, yes == buy ? IMontionsBook.Side.Ask : IMontionsBook.Side.Bid, ticks, quantities);
        uint8 price = yes ? tick : 100 - tick;
        uint64 expected = (buy ? price <= limit : price >= limit) ? (qty < available ? qty : available) : 0;
        IQuoter.Quote memory q = buy ? quoter.quoteBuy(ID, yes, qty, limit) : quoter.quoteSell(ID, yes, qty, limit);
        _assertQuote(
            q,
            expected,
            uint256(expected) * price,
            expected == 0 ? 0 : price,
            expected == 0 ? 0 : price,
            expected == qty
        );
    }

    function testGasQuoteBuyTenLevels() public {
        uint8[] memory ticks = new uint8[](10);
        uint64[] memory quantities = new uint64[](10);
        for (uint8 i; i < 10; ++i) {
            ticks[i] = 40 + i;
            quantities[i] = 1;
        }
        book.setDepth(ID, IMontionsBook.Side.Ask, ticks, quantities);
        uint256 beforeGas = gasleft();
        IQuoter.Quote memory q = quoter.quoteBuy(ID, true, 10, 99);
        uint256 used = beforeGas - gasleft();
        emit log_named_uint("quoteBuy ten levels gas (warm mock storage)", used);
        _assertQuote(q, 10, 445, 45, 49, true);
        assertLt(used, 100_000);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IMontionsBook} from "../../src/interfaces/IMontionsBook.sol";
import {MockCollateral} from "./mocks/MockCollateral.sol";
import {MockResolver} from "./mocks/MockResolver.sol";

/// @notice Replays Python reference-model vectors against MontionsBook when its artifact is present.
contract DiffReplay is Test {
    error ReplayMismatch(string scenario, uint256 opIndex, string detail);

    struct ReplayEnv {
        MockCollateral usdc;
        MockResolver resolver;
        IMontionsBook book;
        address[] users;
        bytes32[] seriesIds;
    }

    // Separate test cases keep each long replay within Foundry's per-test gas budget.
    function testReplayScenario00() public { _replayIfAvailable(0); }
    function testReplayScenario01() public { _replayIfAvailable(1); }
    function testReplayScenario02() public { _replayIfAvailable(2); }
    function testReplayScenario03() public { _replayIfAvailable(3); }
    function testReplayScenario04() public { _replayIfAvailable(4); }
    function testReplayScenario05() public { _replayIfAvailable(5); }
    function testReplayScenario06() public { _replayIfAvailable(6); }
    function testReplayScenario07() public { _replayIfAvailable(7); }
    function testReplayScenario08() public { _replayIfAvailable(8); }
    function testReplayScenario09() public { _replayIfAvailable(9); }
    function testReplayScenario10() public { _replayIfAvailable(10); }
    function testReplayScenario11() public { _replayIfAvailable(11); }

    function _replayIfAvailable(uint256 index) internal {
        // This suite is intentionally buildable before the separately-owned Book lands.
        try this.bookCreationCode() returns (bytes memory code) {
            if (code.length == 0) {
                vm.skip(true, "MontionsBook artifact is not present in this sandbox");
                return;
            }
        } catch {
            vm.skip(true, "MontionsBook artifact is not present in this sandbox");
            return;
        }
        _replay(index, _isV02());
    }

    /// @dev External wrapper detects a missing artifact without compile-time imports.
    function bookCreationCode() external view returns (bytes memory) {
        return vm.getCode("MontionsBook.sol:MontionsBook");
    }

    function _replay(uint256 scenarioIndex, bool v02) internal {
        string memory suffix = v02 ? "_v02.json" : ".json";
        string memory scenario = string.concat("scenario_", _twoDigits(scenarioIndex), suffix);
        string memory json = vm.readFile(string.concat("test/diff/vectors/", scenario));
        uint256 userCount = vm.parseJsonUint(json, ".userCount");
        uint256 seriesCount = vm.parseJsonUint(json, ".seriesCount");
        uint256 opCount = vm.parseJsonUint(json, ".opCount");
        uint256 checkpointCount = vm.parseJsonUint(json, ".checkpointCount");
        ReplayEnv memory env = _setup(json, userCount, seriesCount);

        uint256 checkpointCursor;
        for (uint256 i; i < opCount; ++i) {
            _runOp(json, scenario, i, env);
            if (checkpointCursor < checkpointCount) {
                string memory cp = string.concat(".checkpoints[", _toString(checkpointCursor), "]");
                if (vm.parseJsonUint(json, string.concat(cp, ".opIndex")) == i) {
                    _assertState(json, string.concat(cp, ".state"), scenario, i, env);
                    ++checkpointCursor;
                }
            }
        }
        _assertEq(scenario, opCount, checkpointCursor, checkpointCount, "checkpoint count");
        _assertState(json, ".end", scenario, opCount, env);
    }

    function _setup(string memory json, uint256 userCount, uint256 seriesCount)
        internal returns (ReplayEnv memory env)
    {
        vm.warp(vm.parseJsonUint(json, ".baseTimestamp"));
        env.usdc = new MockCollateral();
        env.resolver = new MockResolver();
        address deployed = deployCode(
            "MontionsBook.sol:MontionsBook", abi.encode(address(env.usdc), address(this))
        );
        env.book = IMontionsBook(deployed);
        env.book.setResolverAllowed(address(env.resolver), true);
        env.book.setFee(uint16(vm.parseJsonUint(json, ".feeBps")), address(this));
        env.users = new address[](userCount);
        for (uint256 u; u < userCount; ++u) {
            env.users[u] = address(uint160(0x10000 + u));
            env.usdc.mint(env.users[u], 100_000 * 1_000_000);
            vm.prank(env.users[u]);
            env.usdc.approve(deployed, type(uint256).max);
        }
        env.seriesIds = new bytes32[](seriesCount);
    }

    function _runOp(string memory json, string memory scenario, uint256 i, ReplayEnv memory env) internal {
        string memory p = string.concat(".ops[", _toString(i), "]");
        string memory kind = vm.parseJsonString(json, string.concat(p, ".kind"));
        vm.warp(vm.parseJsonUint(json, string.concat(p, ".at")));
        if (_eq(kind, "create")) return _create(json, p, scenario, i, env);
        if (_eq(kind, "deposit")) return _deposit(json, p, scenario, i, env);
        if (_eq(kind, "split")) return _split(json, p, scenario, i, env);
        if (_eq(kind, "merge")) return _merge(json, p, scenario, i, env);
        if (_eq(kind, "place")) return _place(json, p, scenario, i, env);
        if (_eq(kind, "cancel")) return _cancel(json, p, scenario, i, env);
        if (_eq(kind, "resolve")) return _resolve(json, p, scenario, i, env);
        if (_eq(kind, "redeem")) return _redeem(json, p, scenario, i, env);
        revert ReplayMismatch(scenario, i, string.concat("unknown operation kind: ", kind));
    }

    function _create(string memory json, string memory p, string memory scenario, uint256 i, ReplayEnv memory env)
        internal
    {
        uint256 sid = vm.parseJsonUint(json, string.concat(p, ".series"));
        uint256 outcome = vm.parseJsonUint(json, string.concat(p, ".outcome"));
        uint64 expiry = uint64(vm.parseJsonUint(json, string.concat(p, ".expiry")));
        bytes memory data = vm.keyExistsJson(json, string.concat(p, ".readyAtExpiry"))
            && vm.parseJsonBool(json, string.concat(p, ".readyAtExpiry"))
            ? abi.encode(outcome, true)
            : abi.encode(outcome);
        if (vm.keyExistsJson(json, string.concat(p, ".dataLength"))) {
            uint256 dataLength = vm.parseJsonUint(json, string.concat(p, ".dataLength"));
            if (dataLength != 32) data = new bytes(dataLength);
        }
        (bool ok, bytes memory ret) = address(env.book).call(abi.encodeCall(
            IMontionsBook.createSeries, (address(env.resolver), data, expiry)
        ));
        _checkFromJson(json, p, scenario, i, ok, ret);
        if (ok && sid < env.seriesIds.length) env.seriesIds[sid] = abi.decode(ret, (bytes32));
    }

    function _deposit(string memory json, string memory p, string memory scenario, uint256 i, ReplayEnv memory env)
        internal
    {
        uint256 u = vm.parseJsonUint(json, string.concat(p, ".user"));
        uint256 amount = vm.parseJsonUint(json, string.concat(p, ".amount"));
        vm.prank(env.users[u]);
        (bool ok, bytes memory ret) = address(env.book).call(abi.encodeCall(IMontionsBook.deposit, (amount)));
        _checkFromJson(json, p, scenario, i, ok, ret);
    }

    function _split(string memory json, string memory p, string memory scenario, uint256 i, ReplayEnv memory env)
        internal
    {
        uint256 u = vm.parseJsonUint(json, string.concat(p, ".user"));
        uint256 s = vm.parseJsonUint(json, string.concat(p, ".series"));
        uint64 qty = uint64(vm.parseJsonUint(json, string.concat(p, ".qty")));
        vm.prank(env.users[u]);
        (bool ok, bytes memory ret) = address(env.book).call(abi.encodeCall(IMontionsBook.split, (env.seriesIds[s], qty)));
        _checkFromJson(json, p, scenario, i, ok, ret);
    }

    function _merge(string memory json, string memory p, string memory scenario, uint256 i, ReplayEnv memory env)
        internal
    {
        uint256 u = vm.parseJsonUint(json, string.concat(p, ".user"));
        uint256 s = vm.parseJsonUint(json, string.concat(p, ".series"));
        uint64 qty = uint64(vm.parseJsonUint(json, string.concat(p, ".qty")));
        vm.prank(env.users[u]);
        (bool ok, bytes memory ret) = address(env.book).call(abi.encodeCall(IMontionsBook.merge, (env.seriesIds[s], qty)));
        _checkFromJson(json, p, scenario, i, ok, ret);
    }

    function _place(string memory json, string memory p, string memory scenario, uint256 i, ReplayEnv memory env)
        internal
    {
        (bool ok, bytes memory ret) = _invokePlace(json, p, env);
        _checkFromJson(json, p, scenario, i, ok, ret);
        if (ok) _assertPlaceReturn(json, p, scenario, i, ret);
    }

    function _invokePlace(string memory json, string memory p, ReplayEnv memory env)
        internal returns (bool ok, bytes memory ret)
    {
        uint256 u = vm.parseJsonUint(json, string.concat(p, ".user"));
        uint256 s = vm.parseJsonUint(json, string.concat(p, ".series"));
        IMontionsBook.PlaceParams memory params;
        params.seriesId = env.seriesIds[s];
        params.side = _eq(vm.parseJsonString(json, string.concat(p, ".side")), "Bid")
            ? IMontionsBook.Side.Bid : IMontionsBook.Side.Ask;
        params.tick = uint8(vm.parseJsonUint(json, string.concat(p, ".tick")));
        params.qty = uint64(vm.parseJsonUint(json, string.concat(p, ".qty")));
        params.fromHeld = vm.parseJsonBool(json, string.concat(p, ".fromHeld"));
        params.tif = _tif(vm.parseJsonString(json, string.concat(p, ".tif")));
        params.maxFills = uint16(vm.parseJsonUint(json, string.concat(p, ".maxFills")));
        vm.prank(env.users[u]);
        return address(env.book).call(abi.encodeCall(IMontionsBook.placeOrder, (params)));
    }

    function _assertPlaceReturn(string memory json, string memory p, string memory scenario, uint256 i, bytes memory ret)
        internal view
    {
        (uint64 orderId, uint64 filled, uint64 resting) = abi.decode(ret, (uint64, uint64, uint64));
        _assertEq(scenario, i, orderId, vm.parseJsonUint(json, string.concat(p, ".orderId")), "orderId");
        _assertEq(scenario, i, filled, vm.parseJsonUint(json, string.concat(p, ".filled")), "filled");
        _assertEq(scenario, i, resting, vm.parseJsonUint(json, string.concat(p, ".resting")), "resting");
    }

    function _cancel(string memory json, string memory p, string memory scenario, uint256 i, ReplayEnv memory env)
        internal
    {
        uint256 u = vm.parseJsonUint(json, string.concat(p, ".user"));
        uint64 orderId = uint64(vm.parseJsonUint(json, string.concat(p, ".orderId")));
        bool expectedOk = vm.parseJsonBool(json, string.concat(p, ".ok"));
        if (orderId == 0) revert ReplayMismatch(scenario, i, "cancel target orderId must be nonzero");
        if (expectedOk) {
            IMontionsBook.OrderView memory target = env.book.orderInfo(orderId);
            if (!target.open || target.maker != env.users[u]) {
                revert ReplayMismatch(scenario, i, "cancel target is not an open order owned by user");
            }
        }
        vm.prank(env.users[u]);
        (bool ok, bytes memory ret) = address(env.book).call(abi.encodeCall(IMontionsBook.cancelOrder, (orderId)));
        _checkFromJson(json, p, scenario, i, ok, ret);
    }

    function _resolve(string memory json, string memory p, string memory scenario, uint256 i, ReplayEnv memory env)
        internal
    {
        uint256 s = vm.parseJsonUint(json, string.concat(p, ".series"));
        (bool ok, bytes memory ret) = address(env.book).call(abi.encodeCall(IMontionsBook.resolve, (env.seriesIds[s])));
        _checkFromJson(json, p, scenario, i, ok, ret);
    }

    function _redeem(string memory json, string memory p, string memory scenario, uint256 i, ReplayEnv memory env)
        internal
    {
        uint256 u = vm.parseJsonUint(json, string.concat(p, ".user"));
        uint256 s = vm.parseJsonUint(json, string.concat(p, ".series"));
        uint256 yesQty = vm.parseJsonUint(json, string.concat(p, ".yesQty"));
        uint256 noQty = vm.parseJsonUint(json, string.concat(p, ".noQty"));
        vm.prank(env.users[u]);
        (bool ok, bytes memory ret) = address(env.book).call(abi.encodeCall(
            IMontionsBook.redeem, (env.seriesIds[s], yesQty, noQty)
        ));
        _checkFromJson(json, p, scenario, i, ok, ret);
        if (ok) _assertRedeemReturn(json, p, scenario, i, ret);
    }

    function _assertRedeemReturn(string memory json, string memory p, string memory scenario, uint256 i, bytes memory ret)
        internal view
    {
        _assertEq(scenario, i, abi.decode(ret, (uint256)),
            vm.parseJsonUint(json, string.concat(p, ".payout")), "payout");
    }

    function _checkFromJson(
        string memory json, string memory p, string memory scenario, uint256 i, bool ok, bytes memory ret
    ) internal pure {
        bool expectedOk = vm.parseJsonBool(json, string.concat(p, ".ok"));
        string memory errorName = vm.parseJsonString(json, string.concat(p, ".error"));
        if (expectedOk) {
            if (!ok) revert ReplayMismatch(scenario, i, "unexpected revert");
            return;
        }
        if (ok) {
            revert ReplayMismatch(
                scenario, i, string.concat("expected ", errorName, " revert, call succeeded")
            );
        }
        if (vm.parseJsonBool(json, string.concat(p, ".anyRevert"))) return;
        bytes4 actual;
        if (ret.length >= 4) assembly ("memory-safe") { actual := mload(add(ret, 32)) }
        if (actual != _errorSelector(errorName)) {
            revert ReplayMismatch(scenario, i, "custom error selector mismatch");
        }
    }

    function _errorSelector(string memory name) internal pure returns (bytes4) {
        if (_eq(name, "BadTick")) return IMontionsBook.BadTick.selector;
        if (_eq(name, "BadQty")) return IMontionsBook.BadQty.selector;
        if (_eq(name, "SeriesNotOpen")) return IMontionsBook.SeriesNotOpen.selector;
        if (_eq(name, "SeriesExists")) return IMontionsBook.SeriesExists.selector;
        if (_eq(name, "SeriesUnknown")) return IMontionsBook.SeriesUnknown.selector;
        if (_eq(name, "ResolverNotAllowed")) return IMontionsBook.ResolverNotAllowed.selector;
        if (_eq(name, "BadExpiry")) return IMontionsBook.BadExpiry.selector;
        if (_eq(name, "NotExpired")) return IMontionsBook.NotExpired.selector;
        if (_eq(name, "AlreadySettled")) return IMontionsBook.AlreadySettled.selector;
        if (_eq(name, "NotOrderOwner")) return IMontionsBook.NotOrderOwner.selector;
        if (_eq(name, "OrderNotOpen")) return IMontionsBook.OrderNotOpen.selector;
        if (_eq(name, "InsufficientCash")) return IMontionsBook.InsufficientCash.selector;
        if (_eq(name, "InsufficientTokens")) return IMontionsBook.InsufficientTokens.selector;
        if (_eq(name, "WouldCross")) return IMontionsBook.WouldCross.selector;
        if (_eq(name, "Expired")) return IMontionsBook.Expired.selector;
        if (_eq(name, "FeeTooHigh")) return IMontionsBook.FeeTooHigh.selector;
        revert(string.concat("unmapped expected custom error: ", name));
    }

    function _assertState(
        string memory json, string memory prefix, string memory scenario, uint256 opIndex, ReplayEnv memory env
    ) internal view {
        uint256 fees = vm.parseJsonUint(json, string.concat(prefix, ".protocolFees"));
        _assertEq(scenario, opIndex, env.book.protocolFees(), fees, "protocolFees");
        uint256 expectedCollateral = fees + _assertUsers(json, prefix, scenario, opIndex, env);
        expectedCollateral += _assertSeries(json, prefix, scenario, opIndex, env);
        _assertEq(scenario, opIndex, env.usdc.balanceOf(address(env.book)), expectedCollateral, "collateral conservation");
    }

    function _assertUsers(
        string memory json, string memory prefix, string memory scenario, uint256 opIndex, ReplayEnv memory env
    ) internal view returns (uint256 expectedCollateral) {
        for (uint256 u; u < env.users.length; ++u) {
            expectedCollateral += _assertOneUser(json, prefix, scenario, opIndex, env, u);
        }
    }

    function _assertOneUser(
        string memory json, string memory prefix, string memory scenario, uint256 opIndex, ReplayEnv memory env,
        uint256 u
    ) internal view returns (uint256) {
        string memory up = string.concat(prefix, ".users[", _toString(u), "]");
        uint256 cash = vm.parseJsonUint(json, string.concat(up, ".cash"));
        uint256 locked = vm.parseJsonUint(json, string.concat(up, ".locked"));
        _assertEq(scenario, opIndex, env.book.cash(env.users[u]), cash, "cash");
        _assertEq(scenario, opIndex, env.book.lockedCash(env.users[u]), locked, "lockedCash");
        for (uint256 s; s < env.seriesIds.length; ++s) {
            _assertUserTokens(json, up, scenario, opIndex, env, u, s);
        }
        return cash + locked;
    }

    function _assertUserTokens(
        string memory json, string memory up, string memory scenario, uint256 opIndex, ReplayEnv memory env,
        uint256 u, uint256 s
    ) internal view {
        IMontionsBook.SeriesInfo memory info = env.book.seriesInfo(env.seriesIds[s]);
        uint256 yes = vm.parseJsonUint(json, string.concat(up, ".yes[", _toString(s), "]"));
        uint256 no = vm.parseJsonUint(json, string.concat(up, ".no[", _toString(s), "]"));
        _assertEq(scenario, opIndex, env.book.balanceOf(env.users[u], info.yesId), yes, "YES balance");
        _assertEq(scenario, opIndex, env.book.balanceOf(env.users[u], info.noId), no, "NO balance");
    }

    function _assertSeries(
        string memory json, string memory prefix, string memory scenario, uint256 opIndex, ReplayEnv memory env
    ) internal view returns (uint256 expectedPools) {
        for (uint256 s; s < env.seriesIds.length; ++s) {
            expectedPools += _assertOneSeries(json, string.concat(prefix, ".series[", _toString(s), "]"),
                scenario, opIndex, env, s);
        }
    }

    function _assertOneSeries(
        string memory json, string memory sp, string memory scenario, uint256 opIndex, ReplayEnv memory env, uint256 s
    ) internal view returns (uint256 expectedPool) {
        IMontionsBook.SeriesInfo memory info = env.book.seriesInfo(env.seriesIds[s]);
        string memory statusName = vm.parseJsonString(json, string.concat(sp, ".status"));
        uint8 status = _eq(statusName, "Open") ? uint8(IMontionsBook.Status.Open)
            : _eq(statusName, "Resolved") ? uint8(IMontionsBook.Status.Resolved)
            : uint8(IMontionsBook.Status.Void);
        _assertEq(scenario, opIndex, uint8(info.status), status, "series status");
        if (info.status == IMontionsBook.Status.Resolved
            && info.yes != vm.parseJsonBool(json, string.concat(sp, ".yes"))) {
            revert ReplayMismatch(scenario, opIndex, "resolved outcome mismatch");
        }
        expectedPool = vm.parseJsonUint(json, string.concat(sp, ".pool"));
        _assertEq(scenario, opIndex, env.book.pool(env.seriesIds[s]), expectedPool, "pool");
        _assertEq(scenario, opIndex, env.book.totalSupply(info.yesId),
            vm.parseJsonUint(json, string.concat(sp, ".yesSupply")), "YES supply");
        _assertEq(scenario, opIndex, env.book.totalSupply(info.noId),
            vm.parseJsonUint(json, string.concat(sp, ".noSupply")), "NO supply");
        _assertBestDepth(json, sp, scenario, opIndex, env, s);
        _assertEq(scenario, opIndex, env.book.lastTradeTick(env.seriesIds[s]),
            vm.parseJsonUint(json, string.concat(sp, ".lastTradeTick")), "lastTradeTick");
        _assertEq(scenario, opIndex, env.book.volumeOf(env.seriesIds[s]),
            vm.parseJsonUint(json, string.concat(sp, ".volume")), "volume");
        _assertTrades(json, sp, scenario, opIndex, env, s);
    }

    function _assertBestDepth(
        string memory json, string memory sp, string memory scenario, uint256 opIndex, ReplayEnv memory env, uint256 s
    ) internal view {
        string memory bp = string.concat(sp, ".bestBidAsk");
        (uint8 bt, uint64 bq, uint8 at, uint64 aq) = env.book.bestBidAsk(env.seriesIds[s]);
        _assertJsonEq(json, string.concat(bp, ".bidTick"), scenario, opIndex, bt, "best bid tick");
        _assertJsonEq(json, string.concat(bp, ".bidQty"), scenario, opIndex, bq, "best bid qty");
        _assertJsonEq(json, string.concat(bp, ".askTick"), scenario, opIndex, at, "best ask tick");
        _assertJsonEq(json, string.concat(bp, ".askQty"), scenario, opIndex, aq, "best ask qty");
        _assertDepth(json, string.concat(sp, ".depthBid"), "depthBidCount", sp, scenario, opIndex,
            env.book, env.seriesIds[s], IMontionsBook.Side.Bid);
        _assertDepth(json, string.concat(sp, ".depthAsk"), "depthAskCount", sp, scenario, opIndex,
            env.book, env.seriesIds[s], IMontionsBook.Side.Ask);
    }

    function _assertDepth(
        string memory json, string memory depthPath, string memory countKey, string memory seriesPath,
        string memory scenario, uint256 opIndex, IMontionsBook book, bytes32 sid, IMontionsBook.Side side
    ) internal view {
        uint256 expectedCount = vm.parseJsonUint(json, string.concat(seriesPath, ".", countKey));
        IMontionsBook.Level[] memory actual = book.depth(sid, side, 10);
        _assertEq(scenario, opIndex, actual.length, expectedCount, countKey);
        for (uint256 i; i < expectedCount; ++i) {
            _assertDepthEntry(json, depthPath, scenario, opIndex, actual[i], i);
        }
    }

    function _assertDepthEntry(
        string memory json, string memory depthPath, string memory scenario, uint256 opIndex,
        IMontionsBook.Level memory level, uint256 i
    ) internal view {
        string memory lp = string.concat(depthPath, "[", _toString(i), "]");
        _assertJsonEq(json, string.concat(lp, ".tick"), scenario, opIndex, level.tick, "depth tick");
        _assertJsonEq(json, string.concat(lp, ".qty"), scenario, opIndex, level.qty, "depth qty");
    }

    function _assertTrades(
        string memory json, string memory sp, string memory scenario, uint256 opIndex, ReplayEnv memory env, uint256 s
    ) internal view {
        uint256 count = vm.parseJsonUint(json, string.concat(sp, ".tradeCount"));
        IMontionsBook.TradeView[] memory actual = env.book.recentTrades(env.seriesIds[s], 64);
        _assertEq(scenario, opIndex, actual.length, count, "recent trade count");
        for (uint256 t; t < count; ++t) {
            string memory tp = string.concat(sp, ".trades[", _toString(t), "]");
            _assertEq(scenario, opIndex, actual[t].ts, vm.parseJsonUint(json, string.concat(tp, ".ts")), "trade timestamp");
            _assertEq(scenario, opIndex, actual[t].tick, vm.parseJsonUint(json, string.concat(tp, ".tick")), "trade tick");
            _assertEq(scenario, opIndex, actual[t].qty, vm.parseJsonUint(json, string.concat(tp, ".qty")), "trade qty");
            if (actual[t].takerIsBuyer != vm.parseJsonBool(json, string.concat(tp, ".takerIsBuyer"))) {
                revert ReplayMismatch(scenario, opIndex, "trade takerIsBuyer mismatch");
            }
        }
    }

    function _assertJsonEq(
        string memory json, string memory path, string memory scenario, uint256 opIndex,
        uint256 actual, string memory what
    ) internal view {
        _assertEq(scenario, opIndex, actual, vm.parseJsonUint(json, path), what);
    }

    function _assertEq(
        string memory scenario, uint256 opIndex, uint256 actual, uint256 expected, string memory what
    ) internal pure {
        if (actual != expected) {
            revert ReplayMismatch(
                scenario,
                opIndex,
                string.concat(
                    what, " mismatch: actual=", _toString(actual), ", expected=", _toString(expected)
                )
            );
        }
    }

    function _isV02() internal view returns (bool) {
        string memory mode = vm.envOr("DIFF_MODE", string("v02"));
        if (_eq(mode, "v02")) return true;
        if (_eq(mode, "v01")) return false;
        revert(string.concat("unsupported DIFF_MODE: ", mode));
    }

    function _tif(string memory name) internal pure returns (IMontionsBook.TIF) {
        if (_eq(name, "GTC")) return IMontionsBook.TIF.GTC;
        if (_eq(name, "IOC")) return IMontionsBook.TIF.IOC;
        return IMontionsBook.TIF.POST_ONLY;
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function _twoDigits(uint256 value) internal pure returns (string memory) {
        return value < 10 ? string.concat("0", _toString(value)) : _toString(value);
    }

    function _toString(uint256 value) internal pure returns (string memory) {
        if (value == 0) return "0";
        uint256 temp = value;
        uint256 digits;
        while (temp != 0) { ++digits; temp /= 10; }
        bytes memory buffer = new bytes(digits);
        while (value != 0) {
            --digits;
            buffer[digits] = bytes1(uint8(48 + value % 10));
            value /= 10;
        }
        return string(buffer);
    }
}

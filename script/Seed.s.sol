// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IMontionsBook} from "../src/interfaces/IMontionsBook.sol";
import {IQuoter} from "../src/interfaces/IQuoter.sol";
import {TestUSDC} from "../src/mocks/TestUSDC.sol";
import {SpotPool} from "../src/oracle/SpotPool.sol";
import {OracleHub} from "../src/oracle/OracleHub.sol";
import {TwapThresholdResolver} from "../src/resolvers/TwapThresholdResolver.sol";

interface ISeedVault {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function refresh(bytes32 seriesId) external;
}

/// @notice Seeds the rolling demo ladder, maker liquidity, and optional vault.
/// @dev Price-series outcomes read the MOCK/DEMO pool TWAP. The oracle is manipulable;
///      deep reserves and the configured TWAP window mitigate but never eliminate that risk.
contract Seed is Script {
    using stdJson for string;

    uint64 private constant _WINDOW = 60;
    uint64 private constant _MAKER_QTY = 10;
    uint256 private constant _MARKET_MAKER_CASH = 2_000e6;
    uint256 private constant _CREATE_BATCH_SIZE = 12;
    uint256[6] private _durations = [uint256(15 minutes), 1 hours, 4 hours, 1 days, 3 days, 7 days];
    uint16[9] private _strikeBps = [uint16(8_000), 9_000, 9_500, 10_000, 10_500, 11_000, 12_000, 13_500, 15_000];

    struct SeedContracts {
        IMontionsBook book;
        IQuoter quoter;
        TestUSDC collateral;
        OracleHub hub;
        TwapThresholdResolver resolver;
        address vault;
        address[2] tokens;
    }

    struct LadderConfig {
        SeedContracts contracts_;
        bytes32[2] assetIds;
        uint64[6] expiries;
        uint256[2] grids;
    }

    function run() external {
        uint256 deployerKey = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        address deployer = deployerKey == 0
            ? vm.envOr("DEPLOYER_ADDRESS", msg.sender)
            : vm.addr(deployerKey);
        if (deployerKey == 0) vm.startBroadcast();
        else vm.startBroadcast(deployerKey);

        string memory path = vm.envOr(
            "DEPLOYMENT",
            string.concat("./deployments/", vm.toString(block.chainid), ".json")
        );
        SeedContracts memory c = _loadContracts(vm.readFile(path));
        LadderConfig memory config;
        config.contracts_ = c;
        config.assetIds = [keccak256("MON"), keccak256("NVDA")];
        config.grids = [uint256(5e16), uint256(25e17)]; // $0.05 MON / $2.50 NVDA.
        for (uint256 i; i < _durations.length; ++i) {
            config.expiries[i] = _roundExpiry(uint64(block.timestamp + _durations[i]));
        }

        uint256 created = _createLadder(config);
        _seedMakerMarkets(config, deployer);
        // Vault seeding (deposit + a refresh per series) is far too heavy for one forge simulation; by default the keeper
        // refreshes series one transaction at a time. Set SEED_VAULT=1 to force it here (e.g. on a tiny ladder).
        if (c.vault != address(0) && vm.envOr("SEED_VAULT", uint256(0)) == 1) _seedVault(c, deployer);
        vm.stopBroadcast();
        emit LadderSeeded(108, created, c.vault);
    }

    function _loadContracts(string memory manifest) private view returns (SeedContracts memory c) {
        c.book = IMontionsBook(manifest.readAddress(".contracts.book"));
        c.quoter = IQuoter(manifest.readAddress(".contracts.quoter"));
        c.collateral = TestUSDC(manifest.readAddress(".contracts.collateral"));
        c.hub = OracleHub(manifest.readAddress(".contracts.oracleHub"));
        c.resolver = TwapThresholdResolver(manifest.readAddress(".contracts.twapResolver"));
        c.vault = manifest.readAddressOr(".contracts.vault", address(0));
        c.tokens = [manifest.readAddress(".contracts.monToken"), manifest.readAddress(".contracts.nvdaToken")];
    }

    function _createLadder(LadderConfig memory config) private returns (uint256 created) {
        bytes[] memory calls = new bytes[](108);
        for (uint256 asset; asset < 2; ++asset) {
            created = _appendAssetCalls(config, asset, calls, created);
        }
        for (uint256 offset; offset < created; offset += _CREATE_BATCH_SIZE) {
            uint256 length = created - offset;
            if (length > _CREATE_BATCH_SIZE) length = _CREATE_BATCH_SIZE;
            config.contracts_.book.multicall(_slice(calls, offset, length));
        }
    }

    function _appendAssetCalls(LadderConfig memory config, uint256 asset, bytes[] memory calls, uint256 count)
        private
        view
        returns (uint256)
    {
        uint256 spot = SpotPool(config.contracts_.hub.poolOf(config.assetIds[asset])).priceWad();
        for (uint256 expiryIndex; expiryIndex < 6; ++expiryIndex) {
            for (uint256 strikeIndex; strikeIndex < _strikeBps.length; ++strikeIndex) {
                uint256 rawStrike = (spot * _strikeBps[strikeIndex]) / 10_000;
                uint256 strike = _roundToGrid(rawStrike, config.grids[asset]);
                bytes memory data = abi.encode(
                    address(config.contracts_.hub), config.assetIds[asset], strike, true, uint32(_WINDOW)
                );
                bytes32 id = config.contracts_.book.seriesIdOf(
                    address(config.contracts_.resolver), data, config.expiries[expiryIndex]
                );
                if (!_seriesExists(config.contracts_.book, id)) {
                    calls[count++] = abi.encodeCall(
                        IMontionsBook.createSeries,
                        (address(config.contracts_.resolver), data, config.expiries[expiryIndex])
                    );
                }
            }
        }
        return count;
    }

    function _seriesExists(IMontionsBook book, bytes32 id) private view returns (bool) {
        try book.seriesInfo(id) returns (IMontionsBook.SeriesInfo memory info) {
            return info.status != IMontionsBook.Status.None;
        } catch {
            return false;
        }
    }

    function _seedMakerMarkets(LadderConfig memory config, address maker) private {
        SeedContracts memory c = config.contracts_;
        c.collateral.mint(maker, _MARKET_MAKER_CASH);
        c.collateral.approve(address(c.book), type(uint256).max);
        c.book.deposit(_MARKET_MAKER_CASH);
        for (uint256 asset; asset < 2; ++asset) {
            uint256 spot = SpotPool(c.hub.poolOf(config.assetIds[asset])).priceWad();
            uint256 strike = _roundToGrid(spot, config.grids[asset]);
            bytes memory data = abi.encode(address(c.hub), config.assetIds[asset], strike, true, uint32(_WINDOW));
            bytes32 id = c.book.seriesIdOf(address(c.resolver), data, config.expiries[0]);
            (uint8 fairTick,,,) = c.quoter.fair(id);
            if (fairTick == 0) fairTick = 50;
            uint8 bidTick = fairTick > 4 ? fairTick - 4 : 1;
            uint8 askTick = fairTick < 95 ? fairTick + 4 : 99;
            c.book.placeOrder(_order(id, IMontionsBook.Side.Bid, bidTick));
            c.book.placeOrder(_order(id, IMontionsBook.Side.Ask, askTick));
            emit SeededMarket(asset == 0 ? "MON" : "NVDA", id, fairTick, bidTick, askTick);
        }
    }

    function _seedVault(SeedContracts memory c, address depositor) private {
        c.collateral.approve(c.vault, type(uint256).max);
        ISeedVault(c.vault).deposit(_MARKET_MAKER_CASH, depositor);
        uint256 count = c.book.seriesCount();
        for (uint256 i; i < count; ++i) {
            bytes32 id = c.book.seriesIdAt(i);
            try c.book.seriesInfo(id) returns (IMontionsBook.SeriesInfo memory info) {
                if (info.status == IMontionsBook.Status.Open) ISeedVault(c.vault).refresh(id);
            } catch {}
        }
    }

    function _order(bytes32 id, IMontionsBook.Side side, uint8 tick)
        private
        pure
        returns (IMontionsBook.PlaceParams memory)
    {
        return IMontionsBook.PlaceParams({
            seriesId: id,
            side: side,
            tick: tick,
            qty: _MAKER_QTY,
            fromHeld: false,
            tif: IMontionsBook.TIF.GTC,
            maxFills: 0
        });
    }

    function _roundExpiry(uint64 timestamp) private pure returns (uint64) {
        return uint64(((uint256(timestamp) + 299) / 300) * 300);
    }

    function _roundToGrid(uint256 value, uint256 grid) private pure returns (uint256) {
        return ((value + grid / 2) / grid) * grid;
    }

    function _slice(bytes[] memory values, uint256 offset, uint256 length)
        private
        pure
        returns (bytes[] memory result)
    {
        result = new bytes[](length);
        for (uint256 i; i < length; ++i) result[i] = values[offset + i];
    }

    event SeededMarket(string symbol, bytes32 indexed seriesId, uint8 fairTick, uint8 bidTick, uint8 askTick);
    event LadderSeeded(uint256 planned, uint256 created, address vault);
}

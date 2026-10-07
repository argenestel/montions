// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {stdJson} from "forge-std/StdJson.sol";
import {IMontionsBook} from "../src/interfaces/IMontionsBook.sol";
import {IQuoter} from "../src/interfaces/IQuoter.sol";
import {TestUSDC} from "../src/mocks/TestUSDC.sol";

interface ISeedVault {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function refresh(bytes32 seriesId) external;
}

/// @notice Seeds maker cash (and optional vault). The canonical series ladder is created by
///         `pnpm --dir bots exec tsx src/seed-ladder.ts` so expiries stay UTC-aligned and idempotent.
/// @dev Price-series outcomes read the MOCK/DEMO pool TWAP. The oracle is manipulable;
///      deep reserves and the configured TWAP window mitigate but never eliminate that risk.
contract Seed is Script {
    using stdJson for string;

    uint64 private constant _MAKER_QTY = 10;
    uint256 private constant _MARKET_MAKER_CASH = 2_000e6;
    uint256 private constant _MAX_SEEDED_MARKETS = 2;

    struct SeedContracts {
        IMontionsBook book;
        IQuoter quoter;
        TestUSDC collateral;
        address vault;
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
        uint256 markets = _seedMakerMarkets(c, deployer);
        // Vault seeding (deposit + a refresh per series) is far too heavy for one forge simulation; by default the keeper
        // refreshes series one transaction at a time. Set SEED_VAULT=1 to force it here (e.g. on a tiny ladder).
        if (c.vault != address(0) && vm.envOr("SEED_VAULT", uint256(0)) == 1) _seedVault(c, deployer);
        vm.stopBroadcast();
        emit MakerSeeded(markets, c.vault);
    }

    function _loadContracts(string memory manifest) private view returns (SeedContracts memory c) {
        c.book = IMontionsBook(manifest.readAddress(".contracts.book"));
        c.quoter = IQuoter(manifest.readAddress(".contracts.quoter"));
        c.collateral = TestUSDC(manifest.readAddress(".contracts.collateral"));
        c.vault = manifest.readAddressOr(".contracts.vault", address(0));
    }

    function _seedMakerMarkets(SeedContracts memory c, address maker) private returns (uint256 seeded) {
        c.collateral.mint(maker, _MARKET_MAKER_CASH);
        c.collateral.approve(address(c.book), type(uint256).max);
        c.book.deposit(_MARKET_MAKER_CASH);
        uint256 count = c.book.seriesCount();
        for (uint256 i; i < count && seeded < _MAX_SEEDED_MARKETS; ++i) {
            bytes32 id = c.book.seriesIdAt(i);
            IMontionsBook.SeriesInfo memory info = c.book.seriesInfo(id);
            if (info.status != IMontionsBook.Status.Open) continue;
            (uint8 fairTick,,,) = c.quoter.fair(id);
            if (fairTick == 0) fairTick = 50;
            uint8 bidTick = fairTick > 4 ? fairTick - 4 : 1;
            uint8 askTick = fairTick < 95 ? fairTick + 4 : 99;
            c.book.placeOrder(_order(id, IMontionsBook.Side.Bid, bidTick));
            c.book.placeOrder(_order(id, IMontionsBook.Side.Ask, askTick));
            emit SeededMarket("series", id, fairTick, bidTick, askTick);
            unchecked {
                ++seeded;
            }
        }
    }

    function _seedVault(SeedContracts memory c, address depositor) private {
        c.collateral.mint(depositor, _MARKET_MAKER_CASH);
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

    event SeededMarket(string symbol, bytes32 indexed seriesId, uint8 fairTick, uint8 bidTick, uint8 askTick);
    event MakerSeeded(uint256 markets, address vault);
}

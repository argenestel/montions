// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {TestUSDC} from "../src/mocks/TestUSDC.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {SpotPool} from "../src/oracle/SpotPool.sol";
import {OracleHub} from "../src/oracle/OracleHub.sol";
import {TwapThresholdResolver} from "../src/resolvers/TwapThresholdResolver.sol";

/// @notice TESTNET/DEMO ONLY: adds demo assets (stocks, crypto, ...) to an existing demo deployment (token + TWAP pool + hub + resolver registration).
/// @dev PRICES_E6 are USD prices in 1e-6 USD. They come from config/*.json: real Pyth values for crypto, approximate levels for stocks.
///   Pool depth is a fixed 5M test USDC per asset, with the base side sized to match the price. TIERS (optional, comma list, default "stock") sets the manifest tier.
///   Writes the manifest asset entries to OUT as a JSON array.
///   HUB=<OracleHub> RESOLVER=<TwapThresholdResolver> COLLATERAL=<TestUSDC> SYMBOLS=AAPL,TSLA PRICES_E6=230000000,330000000 \
///   OUT=deployments/new-assets.json forge script script/AddStocks.s.sol --rpc-url $RPC --broadcast --slow --keystore ...
contract AddStocks is Script {
    uint256 internal constant _QUOTE_DEPTH = 5_000_000e6;  // test USDC per pool; base side = depth / price
    uint256 internal constant _MIN_QUOTE_RESERVE = 50_000e6;
    uint256 internal constant _MAX_ASSETS = 40;

    function run() external {
        require(block.chainid != 143, "demo script: refuses Monad mainnet");
        OracleHub hub = OracleHub(vm.envAddress("HUB"));
        TwapThresholdResolver resolver = TwapThresholdResolver(vm.envAddress("RESOLVER"));
        TestUSDC usdc = TestUSDC(vm.envAddress("COLLATERAL"));
        string[] memory syms = vm.envString("SYMBOLS", ",");
        uint256[] memory prices = vm.envUint("PRICES_E6", ",");
        string[] memory tiers = vm.envOr("TIERS", ",", new string[](0));
        require(syms.length != 0 && syms.length == prices.length && syms.length <= _MAX_ASSETS, "SYMBOLS/PRICES_E6 mismatch");
        require(tiers.length == 0 || tiers.length == syms.length, "TIERS length mismatch");

        uint256 deployerKey = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        address owner_ = deployerKey == 0 ? vm.envOr("DEPLOYER_ADDRESS", msg.sender) : vm.addr(deployerKey);
        if (deployerKey == 0) vm.startBroadcast();
        else vm.startBroadcast(deployerKey);

        string memory out = "[";
        for (uint256 i; i < syms.length; ++i) {
            bytes32 id = keccak256(bytes(syms[i]));
            require(!hub.assetExists(id), string.concat("already registered: ", syms[i]));
            MockERC20 token = new MockERC20(string.concat("Mock ", syms[i]), string.concat("t", syms[i]), 18, owner_);
            SpotPool pool = new SpotPool(address(token), address(usdc), owner_);
            require(prices[i] >= 1_000, "price too small");
            uint256 quote = _QUOTE_DEPTH;
            uint256 base = (quote * 1e18) / prices[i];       // tokens (18 dec) worth `quote` at the given price
            usdc.mint(owner_, quote);
            token.mint(owner_, base);
            usdc.approve(address(pool), quote);
            token.approve(address(pool), base);
            pool.addLiquidity(base, quote);
            hub.registerAsset(id, address(pool), _MIN_QUOTE_RESERVE);
            resolver.setSymbol(id, syms[i]);
            out = string.concat(
                out, i == 0 ? "" : ",",
                '{"symbol":"', syms[i], '","assetId":"', vm.toString(id), '","pool":"', vm.toString(address(pool)),
                '","token":"', vm.toString(address(token)), '","decimals":18,"tier":"', tiers.length == 0 ? "stock" : tiers[i], '"}'
            );
            console2.log(syms[i], address(pool));
        }
        vm.stopBroadcast();
        out = string.concat(out, "]");
        vm.writeFile(vm.envOr("OUT", string("deployments/new-assets.json")), out);
    }
}

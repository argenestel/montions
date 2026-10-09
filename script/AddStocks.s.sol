// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {TestUSDC} from "../src/mocks/TestUSDC.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {SpotPool} from "../src/oracle/SpotPool.sol";
import {OracleHub} from "../src/oracle/OracleHub.sol";
import {TwapThresholdResolver} from "../src/resolvers/TwapThresholdResolver.sol";

/// @notice TESTNET/DEMO ONLY: adds demo "stock" assets to an existing demo deployment (token + TWAP pool + hub + resolver registration).
/// @dev Prices are approximate DEMO levels, not live quotes. Writes the manifest asset entries to OUT as a JSON array.
///   HUB=<OracleHub> RESOLVER=<TwapThresholdResolver> COLLATERAL=<TestUSDC> SYMBOLS=AAPL,TSLA PRICES_CENTS=23000,33000 \
///   OUT=deployments/new-assets.json forge script script/AddStocks.s.sol --rpc-url $RPC --broadcast --slow --keystore ...
contract AddStocks is Script {
    uint256 internal constant _BASE = 100_000e18;          // pool depth in tokens; quote side = price × 100k test USDC
    uint256 internal constant _MIN_QUOTE_RESERVE = 50_000e6;
    uint256 internal constant _MAX_ASSETS = 40;

    function run() external {
        require(block.chainid != 143, "demo script: refuses Monad mainnet");
        OracleHub hub = OracleHub(vm.envAddress("HUB"));
        TwapThresholdResolver resolver = TwapThresholdResolver(vm.envAddress("RESOLVER"));
        TestUSDC usdc = TestUSDC(vm.envAddress("COLLATERAL"));
        string[] memory syms = vm.envString("SYMBOLS", ",");
        uint256[] memory cents = vm.envUint("PRICES_CENTS", ",");
        require(syms.length != 0 && syms.length == cents.length && syms.length <= _MAX_ASSETS, "SYMBOLS/PRICES_CENTS mismatch");

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
            uint256 quote = (cents[i] * _BASE) / 100e12;   // cents × 1e-2 USD × 1e6 USDC decimals × 100k tokens (18 dec → /1e12 after ×1e18)
            usdc.mint(owner_, quote);
            token.mint(owner_, _BASE);
            usdc.approve(address(pool), quote);
            token.approve(address(pool), _BASE);
            pool.addLiquidity(_BASE, quote);
            hub.registerAsset(id, address(pool), _MIN_QUOTE_RESERVE);
            resolver.setSymbol(id, syms[i]);
            out = string.concat(
                out, i == 0 ? "" : ",",
                '{"symbol":"', syms[i], '","assetId":"', vm.toString(id), '","pool":"', vm.toString(address(pool)),
                '","token":"', vm.toString(address(token)), '","decimals":18,"tier":"stock"}'
            );
            console2.log(syms[i], address(pool));
        }
        vm.stopBroadcast();
        out = string.concat(out, "]");
        vm.writeFile(vm.envOr("OUT", string("deployments/new-assets.json")), out);
    }
}

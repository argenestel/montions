// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {TestUSDC} from "../src/mocks/TestUSDC.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {SpotPool} from "../src/oracle/SpotPool.sol";
import {OracleHub} from "../src/oracle/OracleHub.sol";
import {TwapThresholdResolver} from "../src/resolvers/TwapThresholdResolver.sol";
import {TimelockOpResolver} from "../src/resolvers/TimelockOpResolver.sol";
import {MontionsBook} from "../src/MontionsBook.sol";
import {Quoter} from "../src/Quoter.sol";

/// @notice Deploys the MOCK/DEMO Montions stack and writes its chain manifest.
/// @dev The SpotPool TWAP is manipulable, especially at low liquidity. The demo seeds deep
///      pools; this mitigates but never eliminates manipulation risk. Vault deployment is
///      opt-in and omitted when its artifact is unavailable.
contract Deploy is Script {
    uint256 internal constant _MON_BASE = 2_000_000e18;
    uint256 internal constant _MON_QUOTE = 2_000_000e6;
    uint256 internal constant _NVDA_BASE = 100_000e18;
    uint256 internal constant _NVDA_QUOTE = 18_000_000e6;
    uint256 internal constant _MIN_QUOTE_RESERVE = 50_000e6;
    uint256 internal constant _BOT_USDC = 1_000_000e6;
    uint256 internal constant _BOT_BASE = 1_000e18;
    string internal constant _VAULT_ARTIFACT = "MakerVault.sol:MakerVault";

    struct DeploymentContracts {
        address collateral;
        address monToken;
        address nvdaToken;
        address monPool;
        address nvdaPool;
        address oracleHub;
        address twapResolver;
        address timelockResolver;
        address book;
        address quoter;
        address vault;
    }

    function run() external {
        uint256 deployerKey = vm.envOr("DEPLOYER_PRIVATE_KEY", uint256(0));
        address deployer = deployerKey == 0
            ? vm.envOr("DEPLOYER_ADDRESS", msg.sender)
            : vm.addr(deployerKey);
        if (deployerKey == 0) vm.startBroadcast();
        else vm.startBroadcast(deployerKey);

        DeploymentContracts memory deployed = _deployContracts(deployer);
        _seedPools(deployed, deployer);
        _fundBot(deployed, deployer);
        deployed.vault = _deployOptionalVault(deployed, deployer);

        uint256 chainId = block.chainid;
        string memory rpc = vm.envOr(
            "RPC_URL",
            chainId == 10143 ? "https://testnet-rpc.monad.xyz" : "http://127.0.0.1:8545"
        );
        uint256 startBlock = vm.envOr("START_BLOCK", vm.getBlockNumber() + 1);
        vm.stopBroadcast();

        _writeManifest(chainId, rpc, startBlock, deployed);
        console2.log("DEPLOYED chainId", chainId);
        console2.log("Book", deployed.book);
        console2.log("Quoter", deployed.quoter);
        console2.log("OracleHub", deployed.oracleHub);
        if (deployed.vault != address(0)) console2.log("MakerVault", deployed.vault);
    }

    function _deployContracts(address owner_) private returns (DeploymentContracts memory c) {
        c.collateral = address(new TestUSDC(owner_));
        c.monToken = address(new MockERC20("Mock Monad", "tMON", 18, owner_));
        c.nvdaToken = address(new MockERC20("Mock NVIDIA", "tNVDA", 18, owner_));
        c.monPool = address(new SpotPool(c.monToken, c.collateral, owner_));
        c.nvdaPool = address(new SpotPool(c.nvdaToken, c.collateral, owner_));
        c.oracleHub = address(new OracleHub(owner_));
        c.twapResolver = address(new TwapThresholdResolver(c.oracleHub, owner_));
        c.timelockResolver = address(new TimelockOpResolver(owner_));
        c.book = address(new MontionsBook(c.collateral, owner_));
        c.quoter = address(new Quoter(c.book, c.twapResolver));

        bytes32 monId = keccak256("MON");
        bytes32 nvdaId = keccak256("NVDA");
        OracleHub(c.oracleHub).registerAsset(monId, c.monPool, _MIN_QUOTE_RESERVE);
        OracleHub(c.oracleHub).registerAsset(nvdaId, c.nvdaPool, _MIN_QUOTE_RESERVE);
        TwapThresholdResolver(c.twapResolver).setSymbol(monId, "MON");
        TwapThresholdResolver(c.twapResolver).setSymbol(nvdaId, "NVDA");
        MontionsBook(c.book).setResolverAllowed(c.twapResolver, true);
        MontionsBook(c.book).setResolverAllowed(c.timelockResolver, true);
    }

    function _seedPools(DeploymentContracts memory c, address owner_) private {
        TestUSDC collateral = TestUSDC(c.collateral);
        MockERC20 mon = MockERC20(c.monToken);
        MockERC20 nvda = MockERC20(c.nvdaToken);
        collateral.mint(owner_, _MON_QUOTE + _NVDA_QUOTE + 5_000e6);
        mon.mint(owner_, _MON_BASE + _BOT_BASE);
        nvda.mint(owner_, _NVDA_BASE + _BOT_BASE);
        collateral.approve(c.monPool, type(uint256).max);
        collateral.approve(c.nvdaPool, type(uint256).max);
        mon.approve(c.monPool, type(uint256).max);
        nvda.approve(c.nvdaPool, type(uint256).max);
        SpotPool(c.monPool).addLiquidity(_MON_BASE, _MON_QUOTE);
        SpotPool(c.nvdaPool).addLiquidity(_NVDA_BASE, _NVDA_QUOTE);
    }

    function _fundBot(DeploymentContracts memory c, address owner_) private {
        uint256 botKey = vm.envOr("BOT_PRIVATE_KEY", uint256(0));
        address bot = botKey == 0 ? vm.envOr("BOT_ADDRESS", owner_) : vm.addr(botKey);
        if (bot == owner_) {
            TestUSDC(c.collateral).mint(owner_, _BOT_USDC);
            MockERC20(c.monToken).mint(owner_, _BOT_BASE);
            MockERC20(c.nvdaToken).mint(owner_, _BOT_BASE);
        } else {
            TestUSDC(c.collateral).mint(bot, _BOT_USDC);
            MockERC20(c.monToken).mint(bot, _BOT_BASE);
            MockERC20(c.nvdaToken).mint(bot, _BOT_BASE);
        }
    }

    function _deployOptionalVault(DeploymentContracts memory c, address owner_) private returns (address vault) {
        if (vm.envOr("DEPLOY_VAULT", uint256(0)) != 1) return address(0);
        try vm.getCode(_VAULT_ARTIFACT) returns (bytes memory creationCode) {
            if (creationCode.length != 0) {
                vault = vm.deployCode(_VAULT_ARTIFACT, abi.encode(c.book, c.quoter, owner_));
            }
        } catch {
            // MakerVault is developed independently and is intentionally optional.
        }
    }

    function _writeManifest(
        uint256 chainId,
        string memory rpc,
        uint256 startBlock,
        DeploymentContracts memory c
    ) private {
        string memory contracts = vm.serializeAddress("contracts", "book", c.book);
        contracts = vm.serializeAddress("contracts", "quoter", c.quoter);
        contracts = vm.serializeAddress("contracts", "collateral", c.collateral);
        contracts = vm.serializeAddress("contracts", "oracleHub", c.oracleHub);
        contracts = vm.serializeAddress("contracts", "twapResolver", c.twapResolver);
        contracts = vm.serializeAddress("contracts", "timelockResolver", c.timelockResolver);
        contracts = vm.serializeAddress("contracts", "monToken", c.monToken);
        contracts = vm.serializeAddress("contracts", "nvdaToken", c.nvdaToken);
        contracts = vm.serializeAddress("contracts", "monPool", c.monPool);
        contracts = vm.serializeAddress("contracts", "nvdaPool", c.nvdaPool);
        if (c.vault != address(0)) contracts = vm.serializeAddress("contracts", "vault", c.vault);

        string memory monAsset = vm.serializeString("assetMON", "symbol", "MON");
        monAsset = vm.serializeBytes32("assetMON", "assetId", keccak256("MON"));
        monAsset = vm.serializeAddress("assetMON", "pool", c.monPool);
        monAsset = vm.serializeAddress("assetMON", "token", c.monToken);
        monAsset = vm.serializeUint("assetMON", "decimals", 18);

        string memory nvdaAsset = vm.serializeString("assetNVDA", "symbol", "NVDA");
        nvdaAsset = vm.serializeBytes32("assetNVDA", "assetId", keccak256("NVDA"));
        nvdaAsset = vm.serializeAddress("assetNVDA", "pool", c.nvdaPool);
        nvdaAsset = vm.serializeAddress("assetNVDA", "token", c.nvdaToken);
        nvdaAsset = vm.serializeUint("assetNVDA", "decimals", 18);

        string memory root = string.concat(
            "{\"chainId\":", vm.toString(chainId),
            ",\"rpc\":\"", rpc,
            "\",\"contracts\":", contracts,
            ",\"assets\":[", monAsset, ",", nvdaAsset, "]",
            ",\"startBlock\":", vm.toString(startBlock), "}"
        );
        string memory path = string.concat("./deployments/", vm.toString(chainId), ".json");
        vm.writeJson(root, path);
    }
}

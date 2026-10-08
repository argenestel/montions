// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {MontionsBook} from "../src/MontionsBook.sol";
import {Quoter} from "../src/Quoter.sol";
import {MakerVault} from "../src/MakerVault.sol";
import {PythOracle} from "../src/oracle/pyth/PythOracle.sol";
import {PythSettlementResolver} from "../src/resolvers/PythSettlementResolver.sol";
import {TimelockOpResolver} from "../src/resolvers/TimelockOpResolver.sol";

interface IERC20Meta { function decimals() external view returns (uint8); function symbol() external view returns (string memory); }
interface IPythCheck { function getValidTimePeriod() external view returns (uint256); function priceFeedExists(bytes32) external view returns (bool); }

/// @notice Production deployment (Pyth-priced, real USDC): Monad MAINNET (143) and any chain where Pyth + USDC exist.
/// @dev SAFETY MODEL
///  - Refuses to run on chain 143 unless CONFIRM_MAINNET=I_UNDERSTAND_THIS_IS_UNAUDITED_AND_USES_REAL_FUNDS.
///  - Requires explicit launch caps (COLLATERAL_CAP_USDC, SERIES_POOL_CAP_USDC, VAULT_CAP_USDC) — there is no "unlimited" default.
///  - Deploys the Book PAUSED. Unpause is a separate, deliberate step by the owner after `scripts/verify-deployment.sh` passes.
///  - Sanity-checks the collateral token (6 decimals) and the Pyth contract/feeds on-chain before deploying anything.
///  - The deployer is only a temporary owner: finish with `HandoverOwnership.s.sol` (two-step) to the Safe multisig.
///  Run (dry run first, no --broadcast):
///   forge script script/DeployProd.s.sol:DeployProd --rpc-url $RPC --account <keystore> --sender <addr>
contract DeployProd is Script {
    // Verified on Monad mainnet (143) on 2026-10-07 by direct eth_call; re-verify before every launch.
    address internal constant MAINNET_USDC = 0x754704Bc059F8C67012fEd69BC8A327a5aafb603;
    address internal constant MAINNET_PYTH = 0x2880aB155794e7179c9eE2e38200202908C17B43;
    bytes32 internal constant FEED_MON_USD = 0x31491744e2dbf6df7fcf4ac0820d18a609b49076d45066d3568424e62f686cd1;
    bytes32 internal constant FEED_BTC_USD = 0xe62df6c8b4a85fe1a67db44dc12de5db330f7ac66b72dc658afedf0f4a415b43;
    bytes32 internal constant FEED_ETH_USD = 0xff61491a931112ddf1bd8147cd1b641375f79f5825126d665480874634fd0ace;
    uint256 internal constant MONAD_MAINNET = 143;

    string[] internal symbols;

    struct Out {
        MontionsBook book; Quoter quoter; PythOracle oracle; PythSettlementResolver resolver; TimelockOpResolver timelock; MakerVault vault;
        address usdc; address pyth; address owner;
    }

    function run() external {
        if (block.chainid == MONAD_MAINNET) {
            require(
                keccak256(bytes(vm.envOr("CONFIRM_MAINNET", string("")))) == keccak256("I_UNDERSTAND_THIS_IS_UNAUDITED_AND_USES_REAL_FUNDS"),
                "mainnet: set CONFIRM_MAINNET to the exact acknowledgement string"
            );
        }
        address usdc = vm.envOr("USDC", block.chainid == MONAD_MAINNET ? MAINNET_USDC : address(0));
        address pyth = vm.envOr("PYTH", block.chainid == MONAD_MAINNET ? MAINNET_PYTH : address(0));
        require(usdc != address(0) && pyth != address(0), "set USDC and PYTH for this chain");
        address safe = vm.envAddress("OWNER_SAFE"); // final owner; must be a multisig on mainnet
        require(safe != address(0), "OWNER_SAFE required");
        uint256 collateralCap = vm.envUint("COLLATERAL_CAP_USDC") * 1e6;
        uint256 seriesCap = vm.envUint("SERIES_POOL_CAP_USDC") * 1e6;
        require(collateralCap > 0 && seriesCap > 0 && seriesCap <= collateralCap, "caps: need 0 < series <= collateral");
        bool withVault = vm.envOr("DEPLOY_VAULT", uint256(0)) == 1;
        uint256 vaultCap = withVault ? vm.envUint("VAULT_CAP_USDC") * 1e6 : 0;

        // ── pre-flight (read-only): refuse to deploy against the wrong token/oracle
        require(IERC20Meta(usdc).decimals() == 6, "collateral must have 6 decimals");
        console2.log("collateral symbol", IERC20Meta(usdc).symbol());
        require(IPythCheck(pyth).getValidTimePeriod() > 0, "pyth: not a Pyth core contract");
        require(IPythCheck(pyth).priceFeedExists(FEED_MON_USD), "pyth: MON/USD feed missing");

        Out memory o;
        o.usdc = usdc; o.pyth = pyth; o.owner = msg.sender;
        vm.startBroadcast();
        o.owner = msg.sender;
        o.book = new MontionsBook(usdc, msg.sender);
        o.oracle = new PythOracle(pyth, msg.sender);
        // maxAge: the sponsored push feeds on Monad have a 1h heartbeat and 0.02-0.05% deviation trigger, so a pushed price is never
        // more than ~0.05% off, but can be up to an hour old when the market is quiet. 3900s (heartbeat + 5 min) avoids false "unhealthy".
        // It only affects quoting/display; settlement uses fresh signed data at expiry.
        uint32 maxAge = uint32(vm.envOr("PYTH_MAX_AGE", uint256(3900)));
        string memory cfg = vm.readFile(string.concat(vm.projectRoot(), "/config/pyth-feeds.json"));
        uint256 registered;
        for (uint256 i; vm.keyExistsJson(cfg, string.concat(".feeds[", vm.toString(i), "].symbol")); ++i) {
            string memory k = string.concat(".feeds[", vm.toString(i), "]");
            if (!vm.parseJsonBool(cfg, string.concat(k, ".enabled"))) continue;
            string memory sym = vm.parseJsonString(cfg, string.concat(k, ".symbol"));
            bytes32 id = keccak256(bytes(sym));
            o.oracle.setFeed(id, vm.parseJsonBytes32(cfg, string.concat(k, ".feedId")), vm.parseJsonUint(cfg, string.concat(k, ".volWad")), maxAge);
            symbols.push(sym); ++registered;
        }
        require(registered > 0, "no enabled feeds in config/pyth-feeds.json");
        console2.log("registered feeds", registered);
        o.resolver = new PythSettlementResolver(pyth, address(o.oracle), msg.sender);
        for (uint256 i; i < symbols.length; ++i) o.resolver.setSymbol(keccak256(bytes(symbols[i])), symbols[i]);
        o.timelock = new TimelockOpResolver(msg.sender);
        o.book.setResolverAllowed(address(o.resolver), true);
        o.book.setResolverAllowed(address(o.timelock), true);
        o.quoter = new Quoter(address(o.book), address(o.resolver));
        o.book.setCollateralCap(collateralCap);
        o.book.setSeriesPoolCap(seriesCap);
        o.book.setPaused(true); // launches PAUSED; unpausing is a deliberate owner action after verification
        if (withVault) {
            o.vault = new MakerVault(address(o.book), address(o.quoter), msg.sender);
            o.vault.setTrustedResolver(address(o.resolver));
            o.vault.setMaxTotalAssets(vaultCap);
            o.vault.setDepositsPaused(true);
        }
        vm.stopBroadcast();

        _writeManifest(o, safe);
        console2.log("Book", address(o.book)); console2.log("Quoter", address(o.quoter)); console2.log("PythOracle", address(o.oracle));
        console2.log("PythResolver", address(o.resolver)); if (withVault) console2.log("Vault", address(o.vault));
        console2.log("NEXT: scripts/verify-deployment.sh, then Safe requests ownership handover, then HandoverOwnership.s.sol, then unpause.");
    }

    function _writeManifest(Out memory o, address safe) internal {
        string memory c = "contracts";
        vm.serializeAddress(c, "book", address(o.book));
        vm.serializeAddress(c, "quoter", address(o.quoter));
        vm.serializeAddress(c, "collateral", o.usdc);
        vm.serializeAddress(c, "pythOracle", address(o.oracle));
        vm.serializeAddress(c, "pythResolver", address(o.resolver));
        vm.serializeAddress(c, "timelockResolver", address(o.timelock));
        string memory contracts = o.vault == MakerVault(address(0)) ? vm.serializeAddress(c, "pyth", o.pyth) : vm.serializeAddress(c, "vault", address(o.vault));
        string memory root = "manifest";
        vm.serializeUint(root, "chainId", block.chainid);
        vm.serializeString(root, "network", block.chainid == MONAD_MAINNET ? "mainnet" : "testnet");
        vm.serializeString(root, "rpc", vm.envOr("PRIMARY_RPC", string(block.chainid == MONAD_MAINNET ? "https://rpc.monad.xyz" : "https://testnet-rpc.monad.xyz")));
        vm.serializeString(root, "explorer", block.chainid == MONAD_MAINNET ? "https://monadvision.com" : "https://testnet.monadvision.com");
        vm.serializeAddress(root, "ownerSafe", safe);
        vm.serializeUint(root, "startBlock", block.number);
        vm.serializeBytes32(root, "monFeed", FEED_MON_USD);
        string memory json = vm.serializeString(root, "contractsNote", "see contracts object");
        // assets array is written by scripts/finish-manifest.mjs (needs structured arrays); contracts are included below.
        vm.writeJson(contracts, string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".contracts.json"));
        vm.writeJson(json, string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".meta.json"));
    }
}

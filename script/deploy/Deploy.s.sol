// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Snaxpot} from "../../src/Snaxpot.sol";
import {JackpotClaimer} from "../../src/JackpotClaimer.sol";
import {PrizeDistributor} from "../../src/PrizeDistributor.sol";

/// @notice Deploys all Snaxpot contracts in a single script.
///
///   Contracts deployed:
///     - Snaxpot (UUPS proxy + implementation)
///     - JackpotClaimer (via CREATE2 to resolve circular dependency)
///     - PrizeDistributor
///
///   Required env vars:
///     DEPLOYER_PRIVATE_KEY, ADMIN, OPERATOR, USDT,
///     VRF_SUBSCRIPTION_ID, DEPOSIT_CONTRACT
///
///   Example (dry-run):
///     forge script script/deploy/Deploy.s.sol --rpc-url $RPC_URL -vvvv
///
///   Example (broadcast):
///     forge script script/deploy/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify -vvvv
contract Deploy is Script {
    uint32 constant VRF_CALLBACK_GAS_LIMIT = 500_000;
    uint16 constant VRF_REQUEST_CONFIRMATIONS = 6;
    bytes32 constant CREATE2_SALT = keccak256("snaxpot-v1");

    struct Config {
        address admin;
        address operator;
        address usdt;
        address depositContract;
        address vrfCoordinator;
        uint256 vrfSubscriptionId;
        bytes32 vrfKeyHash;
    }

    function _requireNonZero(address addr, string memory name) internal pure {
        require(addr != address(0), string.concat(name, " is zero address"));
    }

    function _vrfConfig() internal view returns (address coordinator, bytes32 keyHash) {
        uint256 chainId = block.chainid;

        if (chainId == 1) {
            // Ethereum Mainnet — 500 gwei lane
            coordinator = 0xD7f86b4b8Cae7D942340FF628F82735b7a20893a;
            keyHash = 0x3fd2fec10d06ee8f65e7f2e95f5c56511359ece3f33960ad8a866ae24a8ff10b;
        } else if (chainId == 11155111) {
            // Sepolia — 500 gwei lane
            coordinator = 0x9DdfaCa8183c41ad55329BdeeD9F6A8d53168B1B;
            keyHash = 0x787d74caea10b2b357790d5b5247c2f63d1d91572a9846f780606e4d953677ae;
        } else {
            revert(string.concat("Unsupported chain ID: ", vm.toString(chainId)));
        }
    }

    function _loadConfig() internal view returns (Config memory c) {
        c.admin = vm.envAddress("ADMIN");
        c.operator = vm.envAddress("OPERATOR");
        c.usdt = vm.envAddress("USDT");
        c.depositContract = vm.envAddress("DEPOSIT_CONTRACT");
        c.vrfSubscriptionId = vm.envUint("VRF_SUBSCRIPTION_ID");

        (c.vrfCoordinator, c.vrfKeyHash) = _vrfConfig();

        _requireNonZero(c.admin, "ADMIN");
        _requireNonZero(c.operator, "OPERATOR");
        _requireNonZero(c.usdt, "USDT");
        _requireNonZero(c.depositContract, "DEPOSIT_CONTRACT");
        require(c.vrfSubscriptionId != 0, "VRF_SUBSCRIPTION_ID is zero");
    }

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);
        Config memory cfg = _loadConfig();

        // Implementation deploys at `nonce`, proxy at `nonce + 1`.
        uint64 nonce = vm.getNonce(deployer);
        address predictedProxy = vm.computeCreateAddress(deployer, nonce + 1);

        bytes32 claimerInitCodeHash = keccak256(
            abi.encodePacked(type(JackpotClaimer).creationCode, abi.encode(cfg.usdt, predictedProxy, cfg.admin))
        );
        address predictedClaimer = vm.computeCreate2Address(CREATE2_SALT, claimerInitCodeHash);

        console.log("Deployer:          ", deployer);
        console.log("Predicted proxy:   ", predictedProxy);
        console.log("Predicted claimer: ", predictedClaimer);

        vm.startBroadcast(deployerPk);

        // 1. Snaxpot implementation
        Snaxpot impl = new Snaxpot();

        // 2. Snaxpot proxy (calls initialize via delegatecall)
        bytes memory initData = abi.encodeCall(
            Snaxpot.initialize,
            (
                cfg.admin,
                cfg.operator,
                cfg.usdt,
                predictedClaimer,
                cfg.vrfCoordinator,
                cfg.vrfSubscriptionId,
                cfg.vrfKeyHash,
                VRF_CALLBACK_GAS_LIMIT,
                VRF_REQUEST_CONFIRMATIONS
            )
        );
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), initData);
        require(address(proxy) == predictedProxy, "Deploy: proxy address mismatch");

        // 3. JackpotClaimer via CREATE2
        JackpotClaimer claimer = new JackpotClaimer{salt: CREATE2_SALT}(cfg.usdt, address(proxy), cfg.admin);
        require(address(claimer) == predictedClaimer, "Deploy: claimer address mismatch");

        // 4. PrizeDistributor
        PrizeDistributor distributor = new PrizeDistributor(cfg.usdt, cfg.admin, cfg.operator, cfg.depositContract);

        vm.stopBroadcast();

        console.log("--- Deployed ---");
        console.log("Implementation:    ", address(impl));
        console.log("Proxy (Snaxpot):   ", address(proxy));
        console.log("JackpotClaimer:    ", address(claimer));
        console.log("PrizeDistributor:  ", address(distributor));
    }
}

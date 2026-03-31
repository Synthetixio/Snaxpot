// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {MockERC20} from "../../test/mocks/MockERC20.sol";

/// @notice Deploys a MockERC20 as test USDT on Sepolia and mints 10M to the deployer.
///
///   Example (dry-run):
///     forge script script/deploy/DeployMockUSDT.s.sol --rpc-url $RPC_URL -vvvv
///
///   Example (broadcast):
///     forge script script/deploy/DeployMockUSDT.s.sol --rpc-url $RPC_URL --broadcast -vvvv
contract DeployMockUSDT is Script {
    uint256 constant INITIAL_MINT = 10_000_000e6; // 10M USDT (6 decimals)

    function run() external {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPk);

        vm.startBroadcast(deployerPk);

        MockERC20 usdt = new MockERC20("Tether USD", "USDT", 6);
        usdt.mint(deployer, INITIAL_MINT);

        vm.stopBroadcast();

        console.log("Mock USDT deployed at:", address(usdt));
        console.log("Minted %s USDT to %s", INITIAL_MINT / 1e6, deployer);
    }
}

// SPDX-License-Identifier: MIT
// Source: @chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFMigratableConsumerV2Plus.sol
pragma solidity ^0.8.0;

interface IVRFMigratableConsumerV2Plus {
    event CoordinatorSet(address vrfCoordinator);

    /// @notice Sets the VRF Coordinator address.
    /// @notice This method should only be callable by the coordinator or contract owner.
    function setCoordinator(address vrfCoordinator) external;
}

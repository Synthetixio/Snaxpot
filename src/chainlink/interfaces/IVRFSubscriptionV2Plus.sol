// SPDX-License-Identifier: MIT
// Source: @chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFSubscriptionV2Plus.sol
pragma solidity ^0.8.0;

interface IVRFSubscriptionV2Plus {
    function addConsumer(uint256 subId, address consumer) external;

    function removeConsumer(uint256 subId, address consumer) external;

    function cancelSubscription(uint256 subId, address to) external;

    function acceptSubscriptionOwnerTransfer(uint256 subId) external;

    function requestSubscriptionOwnerTransfer(uint256 subId, address newOwner) external;

    function createSubscription() external returns (uint256 subId);

    function getSubscription(uint256 subId)
        external
        view
        returns (uint96 balance, uint96 nativeBalance, uint64 reqCount, address owner, address[] memory consumers);

    function pendingRequestExists(uint256 subId) external view returns (bool);

    function getActiveSubscriptionIds(uint256 startIndex, uint256 maxCount) external view returns (uint256[] memory);

    function fundSubscriptionWithNative(uint256 subId) external payable;
}

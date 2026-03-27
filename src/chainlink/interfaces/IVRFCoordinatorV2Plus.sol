// SPDX-License-Identifier: MIT
// Source: @chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol
pragma solidity ^0.8.0;

import {VRFV2PlusClient} from "../libraries/VRFV2PlusClient.sol";
import {IVRFSubscriptionV2Plus} from "./IVRFSubscriptionV2Plus.sol";

/// @notice Enables consumers of VRFCoordinatorV2Plus to be future-proof for upgrades.
/// This interface is supported by subsequent versions of VRFCoordinatorV2Plus.
interface IVRFCoordinatorV2Plus is IVRFSubscriptionV2Plus {
    /**
     * @notice Request a set of random words.
     * @param req - a struct containing following fields for randomness request:
     * keyHash - Corresponds to a particular oracle job which uses that key for generating the VRF
     *   proof. Different keyHash's have different gas price ceilings, so you can select a specific
     *   one to bound your maximum per request cost.
     * subId  - The ID of the VRF subscription. Must be funded with the minimum subscription
     *   balance required for the selected keyHash.
     * requestConfirmations - How many blocks you'd like the oracle to wait before responding to
     *   the request. The acceptable range is [minimumRequestBlockConfirmations, 200].
     * callbackGasLimit - How much gas you'd like to receive in your fulfillRandomWords callback.
     * numWords - The number of uint256 random values you'd like to receive in your
     *   fulfillRandomWords callback.
     * extraArgs - abi-encoded extra args
     * @return requestId - A unique identifier of the request.
     */
    function requestRandomWords(VRFV2PlusClient.RandomWordsRequest calldata req) external returns (uint256 requestId);
}

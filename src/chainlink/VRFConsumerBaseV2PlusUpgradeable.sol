// SPDX-License-Identifier: MIT
// ──────────────────────────────────────────────────────────────────────────────
// Upgradeable variant of VRFConsumerBaseV2Plus for use with UUPS / Transparent
// proxies.  Derived from the non-upgradeable V2.5 base and the V2 upgradeable
// pattern (VRFConsumerBaseV2Upgradeable).
//
// Key differences from VRFConsumerBaseV2Plus:
//   • Inherits Initializable instead of ConfirmedOwner.
//   • Constructor → __VRFConsumerBaseV2Plus_init (onlyInitializing).
//   • Access control for setCoordinator delegated to inheriting contract via
//     the virtual _checkAuthorizedToSetCoordinator() hook.
//   • Storage gap reserved for future upgrades.
// ──────────────────────────────────────────────────────────────────────────────
pragma solidity ^0.8.4;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IVRFCoordinatorV2Plus} from "./interfaces/IVRFCoordinatorV2Plus.sol";
import {IVRFMigratableConsumerV2Plus} from "./interfaces/IVRFMigratableConsumerV2Plus.sol";

abstract contract VRFConsumerBaseV2PlusUpgradeable is Initializable, IVRFMigratableConsumerV2Plus {
    error OnlyCoordinatorCanFulfill(address have, address want);
    error OnlyOwnerOrCoordinator(address have, address owner, address coordinator);
    error ZeroAddress();

    // s_vrfCoordinator should be used by consumers to make requests to vrfCoordinator
    // so that coordinator reference is updated after migration
    IVRFCoordinatorV2Plus public s_vrfCoordinator;

    uint256[49] private __gap;

    // solhint-disable-next-line func-name-mixedcase
    function __VRFConsumerBaseV2Plus_init(address _vrfCoordinator) internal onlyInitializing {
        if (_vrfCoordinator == address(0)) {
            revert ZeroAddress();
        }
        s_vrfCoordinator = IVRFCoordinatorV2Plus(_vrfCoordinator);
    }

    /**
     * @notice fulfillRandomness handles the VRF response. Your contract must
     * implement it. See "SECURITY CONSIDERATIONS" in VRFConsumerBaseV2Plus
     * for important principles to keep in mind.
     *
     * @dev VRFConsumerBaseV2PlusUpgradeable expects its subcontracts to have a
     * method with this signature, and will call it once it has verified the
     * proof associated with the randomness. (It is triggered via a call to
     * rawFulfillRandomWords, below.)
     *
     * @param requestId The Id initially returned by requestRandomness
     * @param randomWords the VRF output expanded to the requested number of words
     */
    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal virtual;

    /// @dev rawFulfillRandomWords is called by VRFCoordinator when it receives a
    /// valid VRF proof. It then calls fulfillRandomWords after validating the caller.
    function rawFulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) external {
        if (msg.sender != address(s_vrfCoordinator)) {
            revert OnlyCoordinatorCanFulfill(msg.sender, address(s_vrfCoordinator));
        }
        fulfillRandomWords(requestId, randomWords);
    }

    /// @inheritdoc IVRFMigratableConsumerV2Plus
    function setCoordinator(address _vrfCoordinator) external override {
        if (msg.sender != address(s_vrfCoordinator)) {
            _checkAuthorizedToSetCoordinator();
        }
        if (_vrfCoordinator == address(0)) {
            revert ZeroAddress();
        }
        s_vrfCoordinator = IVRFCoordinatorV2Plus(_vrfCoordinator);
        emit CoordinatorSet(_vrfCoordinator);
    }

    /// @dev Override this to enforce your own access control (e.g. _checkRole(DEFAULT_ADMIN_ROLE)).
    function _checkAuthorizedToSetCoordinator() internal virtual;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
// import {IVRFCoordinatorV2Plus} from "@chainlink/contracts/src/v0.8/vrf/dev/interfaces/IVRFCoordinatorV2Plus.sol";
// import {VRFV2PlusClient} from "@chainlink/contracts/src/v0.8/vrf/dev/libraries/VRFV2PlusClient.sol";

import {ISnaxpot} from "./interfaces/ISnaxpot.sol";
import {IJackpotClaimer} from "./interfaces/IJackpotClaimer.sol";

// TODO: Create VRFConsumerBaseV2PlusUpgradeable — no official Chainlink one exists for V2.5 + UUPS.
//       Snaxpot should inherit it. See VRFConsumerBaseV2Upgradeable (V2) for reference pattern.
contract Snaxpot is
    ISnaxpot,
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable
{
    using SafeERC20 for IERC20;

    // ─── Constants ─────────────────────────────────────────────────────
    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    uint8 public constant BALL_MAX = 32;
    uint8 public constant SNAX_BALL_MAX = 5;

    // ─── External contracts ────────────────────────────────────────────
    IERC20 public usdt;
    IJackpotClaimer public jackpotClaimer;

    bool public paused;

    uint256 public currentJackpot;
    uint256 public totalAccountedUSDT;
    uint256 public currentEpochId;
    mapping(uint256 epochId => EpochData) public epochs;

    // TODO: VRF state — uncomment when Chainlink integration is wired up
    // IVRFCoordinatorV2Plus public vrfCoordinator;
    // uint256 public vrfSubscriptionId;
    // bytes32 public vrfKeyHash;
    // uint32 public vrfCallbackGasLimit;
    // uint16 public vrfRequestConfirmations;
    // mapping(uint256 requestId => uint256 epochId) public vrfRequestToEpoch;
    // mapping(uint256 requestId => VrfRequestType) public vrfRequestType;

    modifier whenNotPaused() {
        require(!paused, "Paused");
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _admin,
        address _operator,
        address _usdt,
        address _jackpotClaimer
    ) external initializer {
        __AccessControl_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _operator);

        usdt = IERC20(_usdt);
        jackpotClaimer = IJackpotClaimer(_jackpotClaimer);
    }

    function _authorizeUpgrade(
        address
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

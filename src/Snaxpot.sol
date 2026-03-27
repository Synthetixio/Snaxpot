// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

import {VRFConsumerBaseV2PlusUpgradeable} from "./chainlink/VRFConsumerBaseV2PlusUpgradeable.sol";
import {VRFV2PlusClient} from "./chainlink/libraries/VRFV2PlusClient.sol";
import {ISnaxpot} from "./interfaces/ISnaxpot.sol";
import {IJackpotClaimer} from "./interfaces/IJackpotClaimer.sol";

contract Snaxpot is
    ISnaxpot,
    Initializable,
    UUPSUpgradeable,
    AccessControlUpgradeable,
    VRFConsumerBaseV2PlusUpgradeable
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

    // ─── VRF state ─────────────────────────────────────────────────────
    uint256 public vrfSubscriptionId;
    bytes32 public vrfKeyHash;
    uint32 public vrfCallbackGasLimit;
    uint16 public vrfRequestConfirmations;
    mapping(uint256 requestId => uint256 epochId) public vrfRequestToEpoch;
    mapping(uint256 requestId => VrfRequestType) public vrfRequestType;

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
        address _jackpotClaimer,
        address _vrfCoordinator,
        uint256 _vrfSubscriptionId,
        bytes32 _vrfKeyHash,
        uint32 _vrfCallbackGasLimit,
        uint16 _vrfRequestConfirmations
    ) external initializer {
        __AccessControl_init();
        __VRFConsumerBaseV2Plus_init(_vrfCoordinator);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _operator);

        usdt = IERC20(_usdt);
        jackpotClaimer = IJackpotClaimer(_jackpotClaimer);

        vrfSubscriptionId = _vrfSubscriptionId;
        vrfKeyHash = _vrfKeyHash;
        vrfCallbackGasLimit = _vrfCallbackGasLimit;
        vrfRequestConfirmations = _vrfRequestConfirmations;
    }

    // ─── Admin ───────────────────────────────────────────────────────

    /// @notice Recover non-USDT ERC-20 tokens accidentally sent to this contract.
    function rescueToken(
        address token,
        address to,
        uint256 amount
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(token != address(usdt), "cannot withdraw USDT");
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Credit any USDT surplus (direct transfers) to the jackpot.
    function reconcileUSDT() external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 actual = usdt.balanceOf(address(this));
        uint256 surplus = actual - totalAccountedUSDT;
        if (surplus > 0) {
            currentJackpot += surplus;
            totalAccountedUSDT += surplus;
            emit JackpotFunded(surplus, currentJackpot);
        }
    }

    function setJackpotClaimer(
        address _jackpotClaimer
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_jackpotClaimer != address(0), "zero address");
        jackpotClaimer = IJackpotClaimer(_jackpotClaimer);
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        paused = true;
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        paused = false;
    }

    function setVrfConfig(
        uint256 _subscriptionId,
        bytes32 _keyHash,
        uint32 _callbackGasLimit,
        uint16 _requestConfirmations
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        vrfSubscriptionId = _subscriptionId;
        vrfKeyHash = _keyHash;
        vrfCallbackGasLimit = _callbackGasLimit;
        vrfRequestConfirmations = _requestConfirmations;
    }

    // ─── VRF ──────────────────────────────────────────────────────────

    function _requestVrf(
        uint256 epochId,
        VrfRequestType reqType
    ) internal returns (uint256 requestId) {
        requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: vrfKeyHash,
                subId: vrfSubscriptionId,
                requestConfirmations: vrfRequestConfirmations,
                callbackGasLimit: vrfCallbackGasLimit,
                numWords: reqType == VrfRequestType.SEED ? 1 : 6,
                extraArgs: VRFV2PlusClient._argsToBytes(
                    VRFV2PlusClient.ExtraArgsV1({nativePayment: false})
                )
            })
        );

        vrfRequestToEpoch[requestId] = epochId;
        vrfRequestType[requestId] = reqType;
    }

    function fulfillRandomWords(
        uint256 requestId,
        uint256[] calldata randomWords
    ) internal override {
        uint256 epochId = vrfRequestToEpoch[requestId];
        EpochData storage epoch = epochs[epochId];
        VrfRequestType reqType = vrfRequestType[requestId];

        if (reqType == VrfRequestType.SEED) {
            epoch.vrfSeed = randomWords[0];
        } else {
            // DRAW — 6 random words: 5 main balls [1,BALL_MAX] + 1 snax ball [1,SNAX_BALL_MAX].
            // Duplicates in main balls rejected via bitmask; collisions re-derived with keccak.
            // TODO: _deriveBalls(randomWords) and set epoch winning fields, transition to RESOLVED.
        }

        delete vrfRequestToEpoch[requestId];
        delete vrfRequestType[requestId];
    }

    function _checkAuthorizedToSetCoordinator() internal override {
        _checkRole(DEFAULT_ADMIN_ROLE);
    }

    // ─── OTHER ────────────────────────────────────────────────────

    function _authorizeUpgrade(
        address
    ) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

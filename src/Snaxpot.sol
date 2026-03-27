// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
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
    using SafeCast for uint256;

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
        _whenNotPaused();
        _;
    }

    function _whenNotPaused() internal view {
        if (paused) revert ContractPaused();
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

    // ─── Operator ──────────────────────────────────────────────────────

    function openEpoch() external onlyRole(OPERATOR_ROLE) whenNotPaused {
        _openEpoch();
    }

    function closeEpoch(uint256 epochId) external onlyRole(OPERATOR_ROLE) whenNotPaused {
        _closeEpoch(epochId);
    }

    function closeAndOpenNewEpoch(uint256 epochId) external onlyRole(OPERATOR_ROLE) whenNotPaused {
        _closeEpoch(epochId);
        _openEpoch();
    }

    function _openEpoch() internal {
        if (currentEpochId > 0 && epochs[currentEpochId].state == EpochState.OPEN) {
            revert EpochAlreadyOpen();
        }

        currentEpochId++;
        uint256 epochId = currentEpochId;

        EpochData storage epoch = epochs[epochId];
        epoch.state = EpochState.OPEN;
        epoch.startTimestamp = uint40(block.timestamp);

        _requestVrf(epochId, VrfRequestType.SEED);
    }

    function _closeEpoch(uint256 epochId) internal {
        EpochData storage epoch = epochs[epochId];
        if (epoch.state != EpochState.OPEN) {
            revert InvalidEpochState(epochId, epoch.state, EpochState.OPEN);
        }

        epoch.state = EpochState.CLOSED;
        epoch.closeTimestamp = uint40(block.timestamp);

        uint64 snapshot = currentJackpot.toUint64();
        epoch.jackpotAmount = snapshot;
        currentJackpot = 0;

        emit EpochClosed(epochId, snapshot, block.timestamp);
    }

    // ─── Admin ───────────────────────────────────────────────────────

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        paused = true;
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        paused = false;
    }

    function setJackpotClaimer(address _jackpotClaimer) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_jackpotClaimer == address(0)) revert ZeroAddress();
        jackpotClaimer = IJackpotClaimer(_jackpotClaimer);
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

    /// @notice Recover non-USDT ERC-20 tokens accidentally sent to this contract.
    function rescueToken(address token, address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(usdt)) revert CannotWithdrawUSDT();
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

    // ─── VRF ──────────────────────────────────────────────────────────

    function _requestVrf(uint256 epochId, VrfRequestType reqType) internal returns (uint256 requestId) {
        requestId = s_vrfCoordinator.requestRandomWords(
            VRFV2PlusClient.RandomWordsRequest({
                keyHash: vrfKeyHash,
                subId: vrfSubscriptionId,
                requestConfirmations: vrfRequestConfirmations,
                callbackGasLimit: vrfCallbackGasLimit,
                numWords: reqType == VrfRequestType.SEED ? 1 : 6,
                extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: false}))
            })
        );

        vrfRequestToEpoch[requestId] = epochId;
        vrfRequestType[requestId] = reqType;
    }

    function fulfillRandomWords(uint256 requestId, uint256[] calldata randomWords) internal override {
        uint256 epochId = vrfRequestToEpoch[requestId];
        EpochData storage epoch = epochs[epochId];
        VrfRequestType reqType = vrfRequestType[requestId];

        if (reqType == VrfRequestType.SEED) {
            epoch.vrfSeed = randomWords[0];
            emit EpochOpened(epochId, epoch.vrfSeed, epoch.startTimestamp);
        } else {
            (uint8[5] memory balls, uint8 snaxBall) = _deriveBalls(randomWords);
            epoch.winningBall1 = balls[0];
            epoch.winningBall2 = balls[1];
            epoch.winningBall3 = balls[2];
            epoch.winningBall4 = balls[3];
            epoch.winningBall5 = balls[4];
            epoch.winningSnaxBall = snaxBall;
            epoch.state = EpochState.DRAWN;
            emit WinningNumbersDrawn(epochId, balls, snaxBall, requestId);
        }

        delete vrfRequestToEpoch[requestId];
        delete vrfRequestType[requestId];
    }

    /// @dev Derive 5 unique main balls [1,BALL_MAX] + 1 snax ball [1,SNAX_BALL_MAX] from 6 VRF words.
    function _deriveBalls(uint256[] calldata randomWords)
        internal
        pure
        returns (uint8[5] memory balls, uint8 snaxBall)
    {
        uint256 usedMask;
        uint8 count;

        for (uint8 i = 0; count < 5; i++) {
            // Use VRF word directly for first 5 iterations; if collisions force extra
            // iterations beyond the 5 words, derive fresh entropy via keccak.
            uint256 rand = i < 5 ? randomWords[i] : uint256(keccak256(abi.encodePacked(randomWords[i - 1], i)));
            uint8 ball = uint8((rand % BALL_MAX) + 1);
            uint256 bit = uint256(1) << ball;

            if (usedMask & bit == 0) {
                // No collision — accept this ball
                usedMask |= bit;
                balls[count] = ball;
                count++;
            } else {
                // Collision — re-hash until we land on an unused number
                uint256 hash = rand;
                while (usedMask & bit != 0) {
                    hash = uint256(keccak256(abi.encodePacked(hash)));
                    ball = uint8((hash % BALL_MAX) + 1);
                    bit = uint256(1) << ball;
                }
                usedMask |= bit;
                balls[count] = ball;
                count++;
            }
        }

        snaxBall = uint8((randomWords[5] % SNAX_BALL_MAX) + 1);
    }

    function _checkAuthorizedToSetCoordinator() internal override {
        _checkRole(DEFAULT_ADMIN_ROLE);
    }

    // ─── OTHER ────────────────────────────────────────────────────

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

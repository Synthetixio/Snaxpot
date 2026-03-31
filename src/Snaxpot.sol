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

    /// @notice Deploy requires CREATE2 to resolve circular dependency:
    ///   1. Precompute JackpotClaimer address via CREATE2 salt
    ///   2. Deploy Snaxpot proxy → initialize(_jackpotClaimer = precomputed address)
    ///   3. Deploy JackpotClaimer via CREATE2 → constructor(_snaxpot = proxy address)
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
        if (_jackpotClaimer == address(0)) revert ZeroAddress();

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

    // NONE → OPEN
    function openEpoch() external onlyRole(OPERATOR_ROLE) whenNotPaused {
        _openEpoch();
    }

    // OPEN → CLOSED
    function closeEpoch(uint256 epochId) external onlyRole(OPERATOR_ROLE) whenNotPaused {
        _closeEpoch(epochId);
    }

    // OPEN → CLOSED (old) + NONE → OPEN (new)
    function closeAndOpenNewEpoch(uint256 epochId) external onlyRole(OPERATOR_ROLE) whenNotPaused {
        _closeEpoch(epochId);
        _openEpoch();
    }

    function _openEpoch() internal {
        currentEpochId++;
        uint256 epochId = currentEpochId;

        EpochData storage epoch = epochs[epochId];
        if (epoch.state != EpochState.NONE) {
            revert InvalidEpochState(epochId, epoch.state, EpochState.NONE);
        }

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

    // CLOSED → DRAWING (requests VRF draw)
    function commitMerkleRootAndDraw(uint256 epochId, bytes32 root) external onlyRole(OPERATOR_ROLE) whenNotPaused {
        EpochData storage epoch = epochs[epochId];
        if (epoch.state != EpochState.CLOSED) {
            revert InvalidEpochState(epochId, epoch.state, EpochState.CLOSED);
        }
        if (root == bytes32(0)) revert ZeroMerkleRoot();

        epoch.merkleRoot = root;
        epoch.state = EpochState.DRAWING;

        uint256 requestId = _requestVrf(epochId, VrfRequestType.DRAW);
        epoch.vrfRequestId = requestId;

        emit MerkleRootCommitted(epochId, root);
    }

    // DRAWN → RESOLVED (no jackpot winner — roll funds to next epoch)
    function resolveJackpotNoWinner(uint256 epochId) external onlyRole(OPERATOR_ROLE) whenNotPaused {
        EpochData storage epoch = epochs[epochId];
        if (epoch.state != EpochState.DRAWN) {
            revert InvalidEpochState(epochId, epoch.state, EpochState.DRAWN);
        }

        epoch.state = EpochState.RESOLVED;

        uint256 rolled = epoch.jackpotAmount;
        currentJackpot += rolled;

        emit JackpotRolledOver(epochId, rolled);
    }

    // DRAWN → RESOLVED (jackpot winner(s) found)
    function resolveJackpot(uint256 epochId, uint8[5] calldata balls, uint8 snaxBall, JackpotWinner[] calldata winners)
        external
        onlyRole(OPERATOR_ROLE)
        whenNotPaused
    {
        EpochData storage epoch = epochs[epochId];
        if (epoch.state != EpochState.DRAWN) {
            revert InvalidEpochState(epochId, epoch.state, EpochState.DRAWN);
        }
        if (winners.length == 0) revert NoWinners();

        if (!_ballsMatch(epoch, balls, snaxBall)) {
            revert WinningNumbersMismatch();
        }

        uint8[5] memory sorted = _sortBalls(balls);

        for (uint256 i; i < winners.length; i++) {
            bytes32 leaf = keccak256(
                bytes.concat(keccak256(abi.encode(winners[i].winner, sorted, snaxBall, winners[i].ticketIndex)))
            );
            if (!MerkleProof.verify(winners[i].merkleProof, epoch.merkleRoot, leaf)) {
                revert InvalidMerkleProof();
            }
        }

        epoch.jackpotClaimed = true;
        epoch.state = EpochState.RESOLVED;

        // Integer division may leave dust; reconcileUSDT() sweeps it later.
        uint256 share = epoch.jackpotAmount / winners.length;
        totalAccountedUSDT -= epoch.jackpotAmount;

        for (uint256 i; i < winners.length; i++) {
            usdt.forceApprove(address(jackpotClaimer), share);
            jackpotClaimer.credit(winners[i].winner, epochId, share);
            emit JackpotWon(epochId, winners[i].winner, share);
        }
    }

    /// @dev Checks whether a ticket's balls match the winning balls, regardless
    /// of order. Works by building a "bitmask" for each set and comparing them.
    ///
    /// A bitmask is a single uint256 where each ball number "flips on" one bit.
    /// For example, if a ball is 3, we set bit 3: `1 << 3` = ...001000.
    /// If balls are {3, 7, 12}, the mask is: bit 3 ON | bit 7 ON | bit 12 ON.
    ///
    /// Two sets of balls contain the same numbers (in any order) if and only if
    /// their masks are identical. Duplicates are also caught: if a ticket has
    /// [3, 3, 7, 12, 20], only 4 bits get set instead of 5, so it can never
    /// equal a mask built from 5 distinct winning balls.
    function _ballsMatch(EpochData storage epoch, uint8[5] calldata balls, uint8 snaxBall)
        internal
        view
        returns (bool)
    {
        if (snaxBall != epoch.winningSnaxBall) return false;

        // Build a mask from the epoch's winning balls (each `1 << ballNumber`
        // turns on exactly one bit, then OR merges them into a single number).
        uint256 winningMask = (1 << epoch.winningBall1) | (1 << epoch.winningBall2) | (1 << epoch.winningBall3)
            | (1 << epoch.winningBall4) | (1 << epoch.winningBall5);

        // Build the same kind of mask from the ticket's balls.
        uint256 ticketMask;
        for (uint256 i; i < 5; i++) {
            ticketMask |= 1 << balls[i];
        }

        // If both masks are equal, the ticket has the exact same set of numbers.
        return winningMask == ticketMask;
    }

    /// @dev Insertion sort — cheap for 5 elements.
    function _sortBalls(uint8[5] calldata balls) internal pure returns (uint8[5] memory sorted) {
        sorted = balls;
        for (uint256 i = 1; i < 5; i++) {
            uint8 key = sorted[i];
            uint256 j = i;
            while (j > 0 && sorted[j - 1] > key) {
                sorted[j] = sorted[j - 1];
                j--;
            }
            sorted[j] = key;
        }
    }

    /// @notice No state changes — purely emits events so ticket data is available on-chain for merkle tree verification.
    function logTickets(uint256 epochId, TicketLog[] calldata tickets) external onlyRole(OPERATOR_ROLE) {
        EpochState s = epochs[epochId].state;
        if (s != EpochState.OPEN && s != EpochState.CLOSED) {
            revert InvalidEpochState(epochId, s, EpochState.OPEN);
        }

        for (uint256 i; i < tickets.length; i++) {
            emit TicketAdded(epochId, tickets[i].trader, tickets[i].balls, tickets[i].snaxBall, tickets[i].ticketIndex);
        }
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
        if (actual > totalAccountedUSDT) {
            uint256 surplus = actual - totalAccountedUSDT;
            currentJackpot += surplus;
            totalAccountedUSDT += surplus;
            emit JackpotFunded(surplus, currentJackpot);
        }
    }

    // ─── External ────────────────────────────────────────────────────

    function fundJackpot(uint256 amount) external whenNotPaused {
        uint256 balBefore = usdt.balanceOf(address(this));
        usdt.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = usdt.balanceOf(address(this)) - balBefore;
        currentJackpot += received;
        totalAccountedUSDT += received;
        emit JackpotFunded(received, currentJackpot);
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

    // ─── View ─────────────────────────────────────────────────────

    function getEpoch(uint256 epochId) external view returns (EpochData memory) {
        return epochs[epochId];
    }

    function getVrfRequestEpoch(uint256 requestId) external view returns (uint256) {
        return vrfRequestToEpoch[requestId];
    }

    function getVrfRequestType(uint256 requestId) external view returns (VrfRequestType) {
        return vrfRequestType[requestId];
    }

    // ─── OTHER ────────────────────────────────────────────────────

    function _authorizeUpgrade(address) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}
}

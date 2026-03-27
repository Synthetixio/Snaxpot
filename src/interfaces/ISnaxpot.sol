// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ISnaxpot {
    enum EpochState {
        NONE,
        OPEN,
        CLOSED,
        DRAWING,
        DRAWN,
        RESOLVED
    }

    enum VrfRequestType {
        SEED,
        DRAW
    }

    struct EpochData {
        uint256 vrfSeed; // slot 0
        bytes32 merkleRoot; // slot 1
        uint256 vrfRequestId; // slot 2
        // slot 3: 8+5+5+1+1+1+1+1+1+1+1 = 26 bytes (6 spare)
        uint64 jackpotAmount;
        uint40 startTimestamp;
        uint40 closeTimestamp;
        uint8 winningBall1;
        uint8 winningBall2;
        uint8 winningBall3;
        uint8 winningBall4;
        uint8 winningBall5;
        uint8 winningSnaxBall;
        EpochState state;
        bool jackpotClaimed;
    }

    // ─── Errors ──────────────────────────────────────────────────────
    error ContractPaused();
    error InvalidEpochState(uint256 epochId, EpochState current, EpochState expected);
    error CannotWithdrawUSDT();
    error ZeroMerkleRoot();
    error WinningNumbersMismatch();
    error InvalidMerkleProof();
    error NoWinners();

    struct JackpotWinner {
        address winner;
        uint256 ticketIndex;
        bytes32[] merkleProof;
    }

    struct TicketLog {
        address trader;
        uint8[5] balls;
        uint8 snaxBall;
        uint256 ticketIndex;
    }

    event EpochOpened(uint256 indexed epochId, uint256 vrfSeed, uint256 startTimestamp);
    event EpochClosed(uint256 indexed epochId, uint64 jackpotAmount, uint256 closeTimestamp);
    event MerkleRootCommitted(uint256 indexed epochId, bytes32 root);
    event WinningNumbersDrawn(uint256 indexed epochId, uint8[5] balls, uint8 snaxBall, uint256 vrfRequestId);
    event JackpotWon(uint256 indexed epochId, address indexed winner, uint256 amount);
    event JackpotRolledOver(uint256 indexed epochId, uint256 rolledAmount);

    event JackpotFunded(uint256 amount, uint256 newTotal);

    event TicketAdded(
        uint256 indexed epochId, address indexed trader, uint8[5] balls, uint8 snaxBall, uint256 ticketIndex
    );

    // ─── Operator ─────────────────────────────────────────────────────
    function openEpoch() external;

    function closeEpoch(uint256 epochId) external;

    function closeAndOpenNewEpoch(uint256 epochId) external;

    function commitMerkleRootAndDraw(uint256 epochId, bytes32 root) external;

    function resolveJackpot(uint256 epochId, uint8[5] calldata balls, uint8 snaxBall, JackpotWinner[] calldata winners)
        external;

    function resolveJackpotNoWinner(uint256 epochId) external;

    function logTickets(uint256 epochId, TicketLog[] calldata tickets) external;

    // ─── Admin ───────────────────────────────────────────────────────
    function rescueToken(address token, address to, uint256 amount) external;

    function reconcileUSDT() external;

    function setJackpotClaimer(address _jackpotClaimer) external;

    function pause() external;

    function unpause() external;

    function setVrfConfig(
        uint256 _subscriptionId,
        bytes32 _keyHash,
        uint32 _callbackGasLimit,
        uint16 _requestConfirmations
    ) external;

    // ─── External ──────────────────────────────────────────────
    function fundJackpot(uint256 amount) external;

    // ─── View ────────────────────────────────────────────────────────
    function getEpoch(uint256 epochId) external view returns (EpochData memory);
    function getVrfRequestEpoch(uint256 requestId) external view returns (uint256);
    function getVrfRequestType(uint256 requestId) external view returns (VrfRequestType);
}

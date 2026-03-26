// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface ISnaxpot {
    enum EpochState {
        OPEN,
        CLOSED,
        DRAWING,
        RESOLVED
    }

    struct Epoch {
        EpochState state;
        uint256 startTimestamp;
        uint256 closeTimestamp;
        uint256 vrfSeed;
        bytes32 merkleRoot;
        uint8[5] winningBalls;
        uint8 winningSnaxBall;
        uint256 jackpotAmount;
        uint256 vrfRequestId;
        bool jackpotClaimed;
    }

    // struct TicketLog {
    //     address trader;
    //     uint8[5] balls;
    //     uint8 snaxBall;xw
    //     uint256 ticketIndex;
    // }

    // event EpochOpened(uint256 indexed epochId, uint256 vrfSeed, uint256 startTimestamp);
    // event EpochClosed(uint256 indexed epochId, uint256 closeTimestamp);
    // event MerkleRootCommitted(uint256 indexed epochId, bytes32 root);
    // event WinningNumbersDrawn(uint256 indexed epochId, uint8[5] balls, uint8 snaxBall, uint256 vrfRequestId);
    // event JackpotWon(uint256 indexed epochId, address indexed winner, uint256 amount);
    // event JackpotRolledOver(uint256 indexed epochId, uint256 rolledAmount);
    // event SmallPrizesResolved(uint256 indexed epochId, uint256 totalAmount, uint256 winnerCount);
    // event JackpotFunded(uint256 amount, uint256 newTotal);
    // event TicketAdded(uint256 indexed epochId, address indexed trader, uint8[5] balls, uint8 snaxBall, uint256 ticketIndex);

    // function openEpoch() external;
    // function closeEpoch(uint256 epochId) external;
    // function closeAndOpenNewEpoch(uint256 epochId) external;
    // function commitMerkleRoot(uint256 epochId, bytes32 root) external;
    // function drawJackpot(uint256 epochId) external;
    // function resolveJackpot(
    //     uint256 epochId,
    //     address winner,
    //     uint8[5] calldata balls,
    //     uint8 snaxBall,
    //     uint256 ticketIndex,
    //     bytes32[] calldata merkleProof
    // ) external;
    // function resolveJackpotNoWinner(uint256 epochId) external;
    // function resolveSmallPrizes(uint256 epochId, uint256 totalAmount, uint256 winnerCount) external;
    // function fundJackpot(uint256 amount) external;
    // function logTickets(uint256 epochId, TicketLog[] calldata tickets) external;
    // function rescueToken(address token, address to, uint256 amount) external;
    // function currentEpochId() external view returns (uint256);
    // function currentJackpot() external view returns (uint256);
    // function epochs(uint256 epochId) external view returns (Epoch memory);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IJackpotClaimer {
    // event Credited(address indexed winner, uint256 indexed epochId, uint256 amount, uint256 expiresAt);
    // event Claimed(address indexed winner, uint256 amount);
    // event Swept(address indexed winner, uint256 amount, address returnedTo);
    function credit(address winner, uint256 epochId, uint256 amount) external;
    // function claim() external;
    // function sweepExpired(address winner) external;
    // function claimableBalance(address user) external view returns (uint256);
}

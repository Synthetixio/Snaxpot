// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/// @notice Minimal interface for the external deposit contract used by PrizePool.
/// Actual interface TBD — this is a placeholder.
interface IDepositContract {
    function deposit(address recipient, uint256 amount) external;
}

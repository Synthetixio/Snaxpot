// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IJackpotClaimer} from "./interfaces/IJackpotClaimer.sol";
import {ISnaxpot} from "./interfaces/ISnaxpot.sol";

contract JackpotClaimer is IJackpotClaimer {
    using SafeERC20 for IERC20;

    uint256 public constant CLAIM_WINDOW = 90 days;

    IERC20 public immutable usdt;
    address public immutable snaxpot;
    address public immutable admin;

    mapping(address => uint256) public balances;
    mapping(address => uint256) public expiresAt;

    modifier onlySnaxpot() {
        if (msg.sender != snaxpot) revert OnlySnaxpot();
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    /// @notice Must be deployed via CREATE2 so its address can be precomputed
    /// before the Snaxpot proxy exists. See Snaxpot.initialize() for the full
    /// deploy sequence.
    constructor(address _usdt, address _snaxpot, address _admin) {
        usdt = IERC20(_usdt);
        snaxpot = _snaxpot;
        admin = _admin;
    }

    function credit(address winner, uint256 epochId, uint256 amount) external override onlySnaxpot {
        if (amount == 0) revert ZeroAmount();

        usdt.safeTransferFrom(msg.sender, address(this), amount);

        balances[winner] += amount;
        expiresAt[winner] = block.timestamp + CLAIM_WINDOW;

        emit Credited(winner, epochId, amount, expiresAt[winner]);
    }

    function claim() external override {
        uint256 amount = balances[msg.sender];
        if (amount == 0) revert NothingToClaim();

        balances[msg.sender] = 0;
        expiresAt[msg.sender] = 0;

        usdt.safeTransfer(msg.sender, amount);

        emit Claimed(msg.sender, amount);
    }

    function sweepExpired(address winner) external override onlyAdmin {
        uint256 amount = balances[winner];
        if (amount == 0 || block.timestamp <= expiresAt[winner]) {
            revert NotExpired();
        }

        balances[winner] = 0;
        expiresAt[winner] = 0;

        usdt.forceApprove(snaxpot, amount);
        ISnaxpot(snaxpot).fundJackpot(amount);

        emit Swept(winner, amount, snaxpot);
    }

    function claimableBalance(address user) external view override returns (uint256) {
        return balances[user];
    }
}

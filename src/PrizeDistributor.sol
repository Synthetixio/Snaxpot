// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

import {IPrizeDistributor} from "./interfaces/IPrizeDistributor.sol";
import {IDepositContract} from "./interfaces/deposit-contract/IDepositContract.sol";

contract PrizeDistributor is IPrizeDistributor, AccessControl {
    using SafeERC20 for IERC20;

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    IERC20 public immutable usdt;
    IDepositContract public depositContract;

    constructor(address _usdt, address _admin, address _operator, address _depositContract) {
        if (_usdt == address(0) || _admin == address(0) || _operator == address(0) || _depositContract == address(0)) {
            revert ZeroAddress();
        }

        usdt = IERC20(_usdt);
        depositContract = IDepositContract(_depositContract);

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(OPERATOR_ROLE, _operator);
    }

    function fund(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        uint256 balBefore = usdt.balanceOf(address(this));
        usdt.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = usdt.balanceOf(address(this)) - balBefore;
        emit PrizePoolFunded(received);
    }

    function distribute(address[] calldata winners, uint256[] calldata amounts, uint256[] calldata subAccountIds)
        external
        onlyRole(OPERATOR_ROLE)
    {
        if (winners.length != amounts.length || winners.length != subAccountIds.length) revert ArrayLengthMismatch();

        IDepositContract.DepositEntry[] memory entries = new IDepositContract.DepositEntry[](winners.length);
        uint256 total;

        for (uint256 i; i < winners.length; i++) {
            entries[i].token = address(usdt);
            entries[i].amount = amounts[i];
            entries[i].beneficiary = winners[i];
            entries[i].subAccountId = subAccountIds[i];
            total += amounts[i];
            emit PrizeDistributed(winners[i], amounts[i]);
        }

        usdt.forceApprove(address(depositContract), total);
        depositContract.deposit(entries);
    }

    function recoverUSDT(address to, uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        usdt.safeTransfer(to, amount);
        emit USDTRecovered(to, amount);
    }

    function setDepositContract(address _depositContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_depositContract == address(0)) revert ZeroAddress();
        depositContract = IDepositContract(_depositContract);
        emit DepositContractUpdated(_depositContract);
    }
}

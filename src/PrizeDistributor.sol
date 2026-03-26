// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPrizeDistributor} from "./interfaces/IPrizeDistributor.sol";
import {IDepositContract} from "./interfaces/IDepositContract.sol";

contract PrizeDistributor is IPrizeDistributor {
    using SafeERC20 for IERC20;
}

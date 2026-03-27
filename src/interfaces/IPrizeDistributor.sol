// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

interface IPrizeDistributor {
    event PrizePoolFunded(uint256 amount);
    event PrizeDistributed(address indexed winner, uint256 amount);
    event USDTRecovered(address indexed to, uint256 amount);
    event DepositContractUpdated(address indexed newDepositContract);

    error ZeroAddress();
    error ArrayLengthMismatch();
    error ZeroAmount();

    function fund(uint256 amount) external;

    function distribute(address[] calldata winners, uint256[] calldata amounts, uint256[] calldata subAccountIds)
        external;

    function recoverUSDT(address to, uint256 amount) external;

    function setDepositContract(address depositContract) external;
}

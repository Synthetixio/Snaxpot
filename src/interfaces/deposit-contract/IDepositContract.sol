// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {ISignatureTransfer} from "./IPermit2.sol";

interface IDepositContract {
    struct PermitDetails {
        ISignatureTransfer.PermitTransferFrom permit;
        bytes signature;
    }

    struct DepositEntry {
        address token;
        uint256 amount;
        address beneficiary;
        uint256 subAccountId;
        PermitDetails permitDetails;
    }

    function deposit(DepositEntry[] calldata _deposits) external;
}

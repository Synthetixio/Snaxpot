// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

/**
 * @title IPermit2
 * @author Synthetix
 * @notice Interface for the Uniswap Permit2 contract, enabling gasless token approvals.
 * @dev See https://github.com/Uniswap/permit2
 */
interface IPermit2 {
    /**
     * @notice Transfers tokens using a signed permit message
     * @param permit The permit data signed by the owner
     * @param transferDetails The transfer details including recipient and amount
     * @param owner The owner of the tokens being transferred
     * @param signature The signature authorizing the transfer
     */
    function permitTransferFrom(
        ISignatureTransfer.PermitTransferFrom memory permit,
        ISignatureTransfer.SignatureTransferDetails calldata transferDetails,
        address owner,
        bytes calldata signature
    ) external;
}

/**
 * @title ISignatureTransfer
 * @author Synthetix
 * @notice Interface for the data structures used by Permit2 signature-based transfers
 */
interface ISignatureTransfer {
    struct TokenPermissions {
        address token;
        uint256 amount;
    }

    struct PermitTransferFrom {
        TokenPermissions permitted;
        uint256 nonce;
        uint256 deadline;
    }

    struct SignatureTransferDetails {
        address to;
        uint256 requestedAmount;
    }
}

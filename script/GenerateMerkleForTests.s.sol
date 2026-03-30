// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Script, console2} from "forge-std/Script.sol";
import {Hashes} from "@openzeppelin/contracts/utils/cryptography/Hashes.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @dev Generates merkle root and proofs for a fixed set of 4 test tickets.
///      Run: forge script script/GenerateMerkleForTests.s.sol -v
///
///  Wallets (from makeAddr):
///    alice = 0x328809Bc894f92807417D2dAD6b7C998c1aFdac6
///    bob   = 0x1D96F2f6BeF1202E4Ce1Ff6Dad0c2CB002861d3e
///
///  VRF draws:
///    DRAW_A: words [10,20,30,40,50,3]       → balls [9,11,19,21,31] snaxBall 4 (multi-winner)
///    DRAW_C: words [100,200,300,400,500,7]   → balls [5,9,13,17,21] snaxBall 3 (single-winner)
///
///  Ticket data (balls already sorted):
///    [0] alice | [9,11,19,21,31]  | snaxBall 4 | idx 0  → matches DRAW_A
///    [1] bob   | [9,11,19,21,31]  | snaxBall 4 | idx 0  → matches DRAW_A
///    [2] alice | [5,9,13,17,21]   | snaxBall 3 | idx 1  → matches DRAW_C
///    [3] bob   | [1,7,12,20,28]   | snaxBall 2 | idx 1  → matches neither
contract GenerateMerkleForTests is Script {
    function run() external {
        (address alice,) = makeAddrAndKey("alice");
        (address bob,) = makeAddrAndKey("bob");

        console2.log("alice:", alice);
        console2.log("bob:  ", bob);

        bytes32[] memory leaves = new bytes32[](4);
        leaves[0] = _leaf(alice, [uint8(9), 11, 19, 21, 31], 4, 0);
        leaves[1] = _leaf(bob, [uint8(9), 11, 19, 21, 31], 4, 0);
        leaves[2] = _leaf(alice, [uint8(5), 9, 13, 17, 21], 3, 1);
        leaves[3] = _leaf(bob, [uint8(1), 7, 12, 20, 28], 2, 1);

        console2.log("\n--- Leaves ---");
        for (uint256 i; i < 4; i++) {
            console2.log("leaf[%d]:", i);
            console2.logBytes32(leaves[i]);
        }

        bytes32 h01 = Hashes.commutativeKeccak256(leaves[0], leaves[1]);
        bytes32 h23 = Hashes.commutativeKeccak256(leaves[2], leaves[3]);
        bytes32 root = Hashes.commutativeKeccak256(h01, h23);

        console2.log("\n--- Internal nodes ---");
        console2.log("h01:");
        console2.logBytes32(h01);
        console2.log("h23:");
        console2.logBytes32(h23);

        console2.log("\n--- Root ---");
        console2.logBytes32(root);

        console2.log("\n--- Proofs ---");
        console2.log("proof[0]: [leaf[1], h23]");
        console2.logBytes32(leaves[1]);
        console2.logBytes32(h23);

        console2.log("proof[1]: [leaf[0], h23]");
        console2.logBytes32(leaves[0]);
        console2.logBytes32(h23);

        console2.log("proof[2]: [leaf[3], h01]");
        console2.logBytes32(leaves[3]);
        console2.logBytes32(h01);

        console2.log("proof[3]: [leaf[2], h01]");
        console2.logBytes32(leaves[2]);
        console2.logBytes32(h01);

        console2.log("\n--- Verification ---");
        bytes32[] memory p = new bytes32[](2);

        p[0] = leaves[1];
        p[1] = h23;
        console2.log("leaf[0] valid:", MerkleProof.verify(p, root, leaves[0]));

        p[0] = leaves[0];
        p[1] = h23;
        console2.log("leaf[1] valid:", MerkleProof.verify(p, root, leaves[1]));

        p[0] = leaves[3];
        p[1] = h01;
        console2.log("leaf[2] valid:", MerkleProof.verify(p, root, leaves[2]));

        p[0] = leaves[2];
        p[1] = h01;
        console2.log("leaf[3] valid:", MerkleProof.verify(p, root, leaves[3]));
    }

    function _leaf(address wallet, uint8[5] memory balls, uint8 snaxBall, uint256 ticketIndex)
        internal
        pure
        returns (bytes32)
    {
        return keccak256(bytes.concat(keccak256(abi.encode(wallet, balls, snaxBall, ticketIndex))));
    }
}

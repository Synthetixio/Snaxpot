// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Snaxpot} from "../src/Snaxpot.sol";
import {ISnaxpot} from "../src/interfaces/ISnaxpot.sol";
import {JackpotClaimer} from "../src/JackpotClaimer.sol";
import {PrizeDistributor} from "../src/PrizeDistributor.sol";
import {IDepositContract} from "../src/interfaces/deposit-contract/IDepositContract.sol";
import {IVRFCoordinatorV2Plus} from "../src/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";

import {MockERC20} from "./mocks/MockERC20.sol";

contract E2ETest is Test {
    address admin;
    address operator;
    address alice;
    address bob;

    MockERC20 usdt;
    Snaxpot snaxpot;
    JackpotClaimer jackpotClaimer;
    PrizeDistributor prizeDistributor;

    address vrfCoordinator;
    address depositContract;

    uint256 constant VRF_SUB_ID = 1;
    bytes32 constant VRF_KEY_HASH = bytes32(uint256(0xdead));
    uint32 constant VRF_CALLBACK_GAS = 500_000;
    uint16 constant VRF_CONFIRMATIONS = 3;
    uint256 constant VRF_REQUEST_ID = 1;

    // Reuse merkle fixtures from GenerateMerkleForTests.s.sol
    bytes32 constant MERKLE_ROOT = 0xd2bfa9184f92b4541c8a5bac90707dac540e56846ee0b828acbf47648203ae9e;
    bytes32 constant LEAF_0 = 0x9df0a167364098ea1175a7304fb63e3f2c166e61c5609a9975b116fb9e23d6b3;
    bytes32 constant LEAF_1 = 0x7a2736475d1e90a8e50dc49c2732441be24b234c3e21b41069cb9a50002f1ecf;
    bytes32 constant LEAF_2 = 0xb5d7d2d2e177971f8fb479f830fdfa48d3211c5f0031e4646c00e584fe4415c6;
    bytes32 constant LEAF_3 = 0x315b7e24d032df9ed10ce96f70085398241b7eb20516b300517274f80917cb67;
    bytes32 constant H01 = 0x76f1d25323b8ca98b2ca15371dea798cfd7f5b2a2cafbe217869ef217a076bbc;
    bytes32 constant H23 = 0x9bc1b7e3d91372025ba74777763aaa31508f86e365ab2af4e552ad127fa67dec;

    function setUp() public {
        admin = makeAddr("admin");
        operator = makeAddr("operator");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        usdt = new MockERC20("Tether USD", "USDT", 6);
        vrfCoordinator = makeAddr("vrfCoordinator");
        depositContract = makeAddr("depositContract");

        vm.mockCall(
            vrfCoordinator,
            abi.encodeWithSelector(IVRFCoordinatorV2Plus.requestRandomWords.selector),
            abi.encode(VRF_REQUEST_ID)
        );
        vm.mockCall(depositContract, abi.encodeWithSelector(IDepositContract.deposit.selector), abi.encode());

        // Deploy Snaxpot with placeholder claimer, then swap in the real one
        Snaxpot impl = new Snaxpot();
        bytes memory initData = abi.encodeCall(
            Snaxpot.initialize,
            (
                admin,
                operator,
                address(usdt),
                address(1),
                vrfCoordinator,
                VRF_SUB_ID,
                VRF_KEY_HASH,
                VRF_CALLBACK_GAS,
                VRF_CONFIRMATIONS
            )
        );
        snaxpot = Snaxpot(address(new ERC1967Proxy(address(impl), initData)));

        jackpotClaimer = new JackpotClaimer(address(usdt), address(snaxpot), admin);

        vm.prank(admin);
        snaxpot.setJackpotClaimer(address(jackpotClaimer));

        prizeDistributor = new PrizeDistributor(address(usdt), admin, operator, depositContract);
    }

    // ─── Helpers ─────────────────────────────────────────────────────

    function _fulfillVrf(uint256[] memory words) internal {
        vm.prank(vrfCoordinator);
        snaxpot.rawFulfillRandomWords(VRF_REQUEST_ID, words);
    }

    function _deriveBalls(uint256[] memory randomWords) internal pure returns (uint8[5] memory balls, uint8 snaxBall) {
        uint256 usedMask;
        uint8 count;
        for (uint8 i = 0; count < 5; i++) {
            uint256 rand = i < 5 ? randomWords[i] : uint256(keccak256(abi.encodePacked(randomWords[i - 1], i)));
            uint8 ball = uint8((rand % 32) + 1);
            uint256 bit = uint256(1) << ball;
            if (usedMask & bit == 0) {
                usedMask |= bit;
                balls[count++] = ball;
            } else {
                uint256 h = rand;
                while (usedMask & bit != 0) {
                    h = uint256(keccak256(abi.encodePacked(h)));
                    ball = uint8((h % 32) + 1);
                    bit = uint256(1) << ball;
                }
                usedMask |= bit;
                balls[count++] = ball;
            }
        }
        snaxBall = uint8((randomWords[5] % 5) + 1);
    }

    // ─── Test ────────────────────────────────────────────────────────

    function test_e2e_fullLifecycle() public {
        uint256 fundEpoch1 = 1000e6;
        uint256 fundEpoch2 = 500e6;
        uint256 minorPrizePool = 200e6;

        // Fund PrizeDistributor for minor prizes across both epochs
        usdt.mint(admin, minorPrizePool);
        vm.startPrank(admin);
        usdt.approve(address(prizeDistributor), minorPrizePool);
        prizeDistributor.fund(minorPrizePool);
        vm.stopPrank();

        // ═══════════════════════════════════════════════════════════════
        //  EPOCH 1 — no jackpot winner, minor prizes, jackpot rolls over
        // ═══════════════════════════════════════════════════════════════

        vm.prank(operator);
        snaxpot.openEpoch();
        assertEq(snaxpot.currentEpochId(), 1);

        uint256[] memory seedWords = new uint256[](1);
        seedWords[0] = 42;
        _fulfillVrf(seedWords);

        usdt.mint(alice, fundEpoch1);
        vm.startPrank(alice);
        usdt.approve(address(snaxpot), fundEpoch1);
        snaxpot.fundJackpot(fundEpoch1);
        vm.stopPrank();

        assertEq(snaxpot.currentJackpot(), fundEpoch1);
        assertEq(snaxpot.totalAccountedUSDT(), fundEpoch1);

        ISnaxpot.TicketLog[] memory tickets = new ISnaxpot.TicketLog[](4);
        tickets[0] = ISnaxpot.TicketLog({trader: alice, balls: [uint8(9), 11, 19, 21, 31], snaxBall: 4, ticketIndex: 0});
        tickets[1] = ISnaxpot.TicketLog({trader: bob, balls: [uint8(9), 11, 19, 21, 31], snaxBall: 4, ticketIndex: 0});
        tickets[2] = ISnaxpot.TicketLog({trader: alice, balls: [uint8(5), 9, 13, 17, 21], snaxBall: 3, ticketIndex: 1});
        tickets[3] = ISnaxpot.TicketLog({trader: bob, balls: [uint8(1), 7, 12, 20, 28], snaxBall: 2, ticketIndex: 1});
        vm.prank(operator);
        snaxpot.logTickets(1, tickets);

        // Atomic close epoch 1 + open epoch 2
        vm.prank(operator);
        snaxpot.closeAndOpenNewEpoch(1);
        assertEq(snaxpot.currentEpochId(), 2);
        assertEq(snaxpot.currentJackpot(), 0);

        ISnaxpot.EpochData memory epoch1 = snaxpot.getEpoch(1);
        assertEq(uint8(epoch1.state), uint8(ISnaxpot.EpochState.CLOSED));
        assertEq(epoch1.jackpotAmount, fundEpoch1);

        // Fulfill seed VRF for epoch 2 (opened by closeAndOpenNewEpoch)
        seedWords[0] = 99;
        _fulfillVrf(seedWords);

        // Draw for epoch 1 — DRAW_B: balls [2,3,4,5,6] snaxBall 1, no ticket matches
        vm.prank(operator);
        snaxpot.commitMerkleRootAndDraw(1, MERKLE_ROOT);

        uint256[] memory drawWords1 = new uint256[](6);
        drawWords1[0] = 1;
        drawWords1[1] = 2;
        drawWords1[2] = 3;
        drawWords1[3] = 4;
        drawWords1[4] = 5;
        drawWords1[5] = 0;
        _fulfillVrf(drawWords1);

        epoch1 = snaxpot.getEpoch(1);
        assertEq(uint8(epoch1.state), uint8(ISnaxpot.EpochState.DRAWN));

        vm.prank(operator);
        snaxpot.resolveJackpotNoWinner(1);

        epoch1 = snaxpot.getEpoch(1);
        assertEq(uint8(epoch1.state), uint8(ISnaxpot.EpochState.RESOLVED));
        assertFalse(epoch1.jackpotClaimed);
        assertEq(snaxpot.currentJackpot(), fundEpoch1);
        assertEq(snaxpot.totalAccountedUSDT(), fundEpoch1);
        assertEq(usdt.balanceOf(address(snaxpot)), fundEpoch1);

        // Minor prizes for epoch 1
        address[] memory minorWinners = new address[](2);
        minorWinners[0] = alice;
        minorWinners[1] = bob;
        uint256[] memory minorAmounts = new uint256[](2);
        minorAmounts[0] = 50e6;
        minorAmounts[1] = 30e6;
        uint256[] memory subAccountIds = new uint256[](2);
        subAccountIds[0] = 0;
        subAccountIds[1] = 0;
        vm.prank(operator);
        prizeDistributor.distribute(minorWinners, minorAmounts, subAccountIds);

        // ═══════════════════════════════════════════════════════════════
        //  EPOCH 2 — jackpot winner (alice), minor prizes, claim
        // ═══════════════════════════════════════════════════════════════

        usdt.mint(bob, fundEpoch2);
        vm.startPrank(bob);
        usdt.approve(address(snaxpot), fundEpoch2);
        snaxpot.fundJackpot(fundEpoch2);
        vm.stopPrank();

        uint256 totalJackpot = fundEpoch1 + fundEpoch2;
        assertEq(snaxpot.currentJackpot(), totalJackpot);
        assertEq(snaxpot.totalAccountedUSDT(), totalJackpot);

        vm.prank(operator);
        snaxpot.logTickets(2, tickets);

        vm.prank(operator);
        snaxpot.closeEpoch(2);

        ISnaxpot.EpochData memory epoch2 = snaxpot.getEpoch(2);
        assertEq(uint8(epoch2.state), uint8(ISnaxpot.EpochState.CLOSED));
        assertEq(epoch2.jackpotAmount, totalJackpot);
        assertEq(snaxpot.currentJackpot(), 0);

        // Draw for epoch 2 — DRAW_C: balls [5,9,13,17,21] snaxBall 3, ticket[2] (alice) matches
        vm.prank(operator);
        snaxpot.commitMerkleRootAndDraw(2, MERKLE_ROOT);

        uint256[] memory drawWords2 = new uint256[](6);
        drawWords2[0] = 100;
        drawWords2[1] = 200;
        drawWords2[2] = 300;
        drawWords2[3] = 400;
        drawWords2[4] = 500;
        drawWords2[5] = 7;
        _fulfillVrf(drawWords2);

        epoch2 = snaxpot.getEpoch(2);
        assertEq(uint8(epoch2.state), uint8(ISnaxpot.EpochState.DRAWN));

        // Resolve — alice wins with ticket[2]: balls [5,9,13,17,21] snaxBall 3, ticketIndex 1
        ISnaxpot.JackpotWinner[] memory winners = new ISnaxpot.JackpotWinner[](1);
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = LEAF_3;
        proof[1] = H01;
        winners[0] = ISnaxpot.JackpotWinner({winner: alice, ticketIndex: 1, merkleProof: proof});

        vm.prank(operator);
        snaxpot.resolveJackpot(2, [uint8(5), 9, 13, 17, 21], 3, winners);

        epoch2 = snaxpot.getEpoch(2);
        assertEq(uint8(epoch2.state), uint8(ISnaxpot.EpochState.RESOLVED));
        assertTrue(epoch2.jackpotClaimed);
        assertEq(snaxpot.totalAccountedUSDT(), 0);
        assertEq(usdt.balanceOf(address(snaxpot)), 0);
        assertEq(usdt.balanceOf(address(jackpotClaimer)), totalJackpot);
        assertEq(jackpotClaimer.balances(alice), totalJackpot);

        // Minor prizes for epoch 2
        minorAmounts[0] = 75e6;
        minorAmounts[1] = 25e6;
        vm.prank(operator);
        prizeDistributor.distribute(minorWinners, minorAmounts, subAccountIds);

        // ═══════════════════════════════════════════════════════════════
        //  JACKPOT CLAIM
        // ═══════════════════════════════════════════════════════════════

        vm.prank(alice);
        jackpotClaimer.claim();

        assertEq(usdt.balanceOf(alice), totalJackpot);
        assertEq(usdt.balanceOf(address(jackpotClaimer)), 0);
        assertEq(jackpotClaimer.balances(alice), 0);
        assertEq(jackpotClaimer.expiresAt(alice), 0);
    }
}

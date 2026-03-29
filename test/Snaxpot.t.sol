// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Snaxpot} from "../src/Snaxpot.sol";
import {ISnaxpot} from "../src/interfaces/ISnaxpot.sol";
import {IJackpotClaimer} from "../src/interfaces/IJackpotClaimer.sol";
import {IVRFCoordinatorV2Plus} from "../src/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";
import {VRFV2PlusClient} from "../src/chainlink/libraries/VRFV2PlusClient.sol";

import {MockERC20} from "./mocks/MockERC20.sol";

contract SnaxpotTest is Test {
    address admin;
    address operator;
    address alice;
    address bob;

    MockERC20 usdt;
    address vrfCoordinator;
    address jackpotClaimer;
    Snaxpot snaxpot;

    uint256 constant VRF_SUB_ID = 1;
    bytes32 constant VRF_KEY_HASH = bytes32(uint256(0xdead));
    uint32 constant VRF_CALLBACK_GAS = 500_000;
    uint16 constant VRF_CONFIRMATIONS = 3;

    uint256 constant VRF_REQUEST_ID = 1;

    function setUp() public {
        admin = makeAddr("admin");
        operator = makeAddr("operator");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        usdt = new MockERC20("Tether USD", "USDT", 6);
        vrfCoordinator = makeAddr("vrfCoordinator");
        jackpotClaimer = makeAddr("jackpotClaimer");

        vm.mockCall(
            jackpotClaimer,
            abi.encodeWithSelector(IJackpotClaimer.credit.selector),
            abi.encode()
        );
        vm.mockCall(
            vrfCoordinator,
            abi.encodeWithSelector(
                IVRFCoordinatorV2Plus.requestRandomWords.selector
            ),
            abi.encode(VRF_REQUEST_ID)
        );

        Snaxpot impl = new Snaxpot();
        bytes memory initData = abi.encodeCall(
            Snaxpot.initialize,
            (
                admin,
                operator,
                address(usdt),
                jackpotClaimer,
                vrfCoordinator,
                VRF_SUB_ID,
                VRF_KEY_HASH,
                VRF_CALLBACK_GAS,
                VRF_CONFIRMATIONS
            )
        );
        snaxpot = Snaxpot(address(new ERC1967Proxy(address(impl), initData)));
    }

    // ─── VRF helper ─────────────────────────────────────────────────

    function _fulfillVrf(uint256[] memory words) internal {
        vm.prank(vrfCoordinator);
        snaxpot.rawFulfillRandomWords(VRF_REQUEST_ID, words);
    }

    // Known VRF word → ball mappings (no collisions):
    //
    //   DRAW_A: words [10, 20, 30, 40, 50, 3]  → balls [11, 21, 31, 9, 19], snaxBall 4
    //   DRAW_B: words [100, 200, 300, 400, 500, 7] → balls [5, 9, 13, 17, 21], snaxBall 3
    //
    /// @dev Mirrors Snaxpot._deriveBalls so tests can predict winning numbers from VRF words.
    function _deriveBalls(
        uint256[] memory randomWords
    ) internal pure returns (uint8[5] memory balls, uint8 snaxBall) {
        uint256 usedMask;
        uint8 count;
        for (uint8 i = 0; count < 5; i++) {
            uint256 rand = i < 5
                ? randomWords[i]
                : uint256(keccak256(abi.encodePacked(randomWords[i - 1], i)));
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

    // ─── Tests ──────────────────────────────────────────────────────

    function test_initialState() public view {
        assertEq(snaxpot.currentEpochId(), 0);
        assertEq(snaxpot.currentJackpot(), 0);
        assertEq(snaxpot.totalAccountedUSDT(), 0);
        assertEq(address(snaxpot.usdt()), address(usdt));
        assertEq(address(snaxpot.jackpotClaimer()), jackpotClaimer);
        assertFalse(snaxpot.paused());
        assertTrue(snaxpot.hasRole(snaxpot.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(snaxpot.hasRole(snaxpot.OPERATOR_ROLE(), operator));
    }

    function test_openEpoch_happyPath() public {
        vm.expectCall(
            vrfCoordinator,
            abi.encodeCall(
                IVRFCoordinatorV2Plus.requestRandomWords,
                (VRFV2PlusClient.RandomWordsRequest({
                    keyHash: VRF_KEY_HASH,
                    subId: VRF_SUB_ID,
                    requestConfirmations: VRF_CONFIRMATIONS,
                    callbackGasLimit: VRF_CALLBACK_GAS,
                    numWords: 1,
                    extraArgs: VRFV2PlusClient._argsToBytes(VRFV2PlusClient.ExtraArgsV1({nativePayment: false}))
                }))
            )
        );

        vm.prank(operator);
        snaxpot.openEpoch();

        assertEq(snaxpot.currentEpochId(), 1);

        ISnaxpot.EpochData memory epoch = snaxpot.getEpoch(1);
        assertEq(uint8(epoch.state), uint8(ISnaxpot.EpochState.OPEN));
        assertEq(epoch.startTimestamp, block.timestamp);
    }

    function test_openEpoch_whenNotOperator_reverts() public {
        vm.prank(alice);
        vm.expectRevert();
        snaxpot.openEpoch();
    }

    function test_openEpoch_whenPaused_reverts() public {
        vm.prank(admin);
        snaxpot.pause();

        vm.prank(operator);
        vm.expectRevert(ISnaxpot.ContractPaused.selector);
        snaxpot.openEpoch();
    }

    function test_closeEpoch_happyPath() public {
        vm.startPrank(operator);
        snaxpot.openEpoch();
        snaxpot.closeEpoch(1);
        vm.stopPrank();

        ISnaxpot.EpochData memory epoch = snaxpot.getEpoch(1);
        assertEq(uint8(epoch.state), uint8(ISnaxpot.EpochState.CLOSED));
        assertEq(epoch.closeTimestamp, block.timestamp);
        assertEq(epoch.jackpotAmount, 0);
        assertEq(snaxpot.currentJackpot(), 0);
    }

    function test_closeEpoch_whenNotOperator_reverts() public {
        vm.prank(operator);
        snaxpot.openEpoch();

        vm.prank(alice);
        vm.expectRevert();
        snaxpot.closeEpoch(1);
    }

    function test_closeEpoch_whenPaused_reverts() public {
        vm.prank(operator);
        snaxpot.openEpoch();

        vm.prank(admin);
        snaxpot.pause();

        vm.prank(operator);
        vm.expectRevert(ISnaxpot.ContractPaused.selector);
        snaxpot.closeEpoch(1);
    }

    function test_closeEpoch_whenEpochNotOpen_reverts() public {
        vm.prank(operator);
        vm.expectRevert(
            abi.encodeWithSelector(
                ISnaxpot.InvalidEpochState.selector,
                1,
                ISnaxpot.EpochState.NONE,
                ISnaxpot.EpochState.OPEN
            )
        );
        snaxpot.closeEpoch(1);
    }
}

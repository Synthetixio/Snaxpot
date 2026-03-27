// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {Snaxpot} from "../src/Snaxpot.sol";
import {ISnaxpot} from "../src/interfaces/ISnaxpot.sol";
import {IJackpotClaimer} from "../src/interfaces/IJackpotClaimer.sol";
import {IVRFCoordinatorV2Plus} from "../src/chainlink/interfaces/IVRFCoordinatorV2Plus.sol";

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

        vm.mockCall(jackpotClaimer, abi.encodeWithSelector(IJackpotClaimer.credit.selector), abi.encode());
        vm.mockCall(
            vrfCoordinator,
            abi.encodeWithSelector(IVRFCoordinatorV2Plus.requestRandomWords.selector),
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
}

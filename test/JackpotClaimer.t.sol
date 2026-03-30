// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {JackpotClaimer} from "../src/JackpotClaimer.sol";
import {IJackpotClaimer} from "../src/interfaces/IJackpotClaimer.sol";
import {ISnaxpot} from "../src/interfaces/ISnaxpot.sol";

import {MockERC20} from "./mocks/MockERC20.sol";

contract JackpotClaimerTest is Test {
    address snaxpotAddr;
    address admin;
    address alice;
    address bob;

    MockERC20 usdt;
    JackpotClaimer claimer;

    function setUp() public {
        admin = makeAddr("admin");
        alice = makeAddr("alice");
        bob = makeAddr("bob");

        usdt = new MockERC20("Tether USD", "USDT", 6);

        snaxpotAddr = address(new MockERC20("dummy", "DUM", 18));

        claimer = new JackpotClaimer(address(usdt), snaxpotAddr, admin);

        vm.mockCall(snaxpotAddr, abi.encodeWithSelector(ISnaxpot.fundJackpot.selector), abi.encode());
    }

    // ─── Helpers ─────────────────────────────────────────────────

    function _creditAlice(uint256 amount) internal {
        usdt.mint(snaxpotAddr, amount);
        vm.startPrank(snaxpotAddr);
        usdt.approve(address(claimer), amount);
        claimer.credit(alice, 1, amount);
        vm.stopPrank();
    }

    // ─── Tests ───────────────────────────────────────────────────

    function test_initialState() public view {
        assertEq(address(claimer.usdt()), address(usdt));
        assertEq(claimer.snaxpot(), snaxpotAddr);
        assertEq(claimer.admin(), admin);
        assertEq(claimer.CLAIM_WINDOW(), 90 days);
    }

    function test_credit_happyPath() public {
        usdt.mint(snaxpotAddr, 500e6);

        vm.startPrank(snaxpotAddr);
        usdt.approve(address(claimer), 500e6);

        vm.expectEmit(true, true, false, true, address(claimer));
        emit IJackpotClaimer.Credited(alice, 1, 500e6, block.timestamp + 90 days);

        claimer.credit(alice, 1, 500e6);
        vm.stopPrank();

        assertEq(claimer.balances(alice), 500e6);
        assertEq(claimer.expiresAt(alice), block.timestamp + 90 days);
        assertEq(claimer.claimableBalance(alice), 500e6);
        assertEq(usdt.balanceOf(address(claimer)), 500e6);
    }

    function test_credit_accumulates() public {
        _creditAlice(500e6);

        usdt.mint(snaxpotAddr, 200e6);
        vm.startPrank(snaxpotAddr);
        usdt.approve(address(claimer), 200e6);
        claimer.credit(alice, 2, 200e6);
        vm.stopPrank();

        assertEq(claimer.balances(alice), 700e6);
        assertEq(claimer.expiresAt(alice), block.timestamp + 90 days);
    }

    function test_credit_whenNotSnaxpot_reverts() public {
        vm.prank(alice);
        vm.expectRevert(IJackpotClaimer.OnlySnaxpot.selector);
        claimer.credit(alice, 1, 500e6);
    }

    function test_credit_whenZeroAmount_reverts() public {
        vm.prank(snaxpotAddr);
        vm.expectRevert(IJackpotClaimer.ZeroAmount.selector);
        claimer.credit(alice, 1, 0);
    }

    function test_claim_happyPath() public {
        _creditAlice(500e6);

        vm.expectEmit(true, false, false, true, address(claimer));
        emit IJackpotClaimer.Claimed(alice, 500e6);

        vm.prank(alice);
        claimer.claim();

        assertEq(claimer.balances(alice), 0);
        assertEq(claimer.expiresAt(alice), 0);
        assertEq(usdt.balanceOf(alice), 500e6);
        assertEq(usdt.balanceOf(address(claimer)), 0);
    }

    function test_claim_whenNothingToClaim_reverts() public {
        vm.prank(alice);
        vm.expectRevert(IJackpotClaimer.NothingToClaim.selector);
        claimer.claim();
    }

    function test_sweepExpired_happyPath() public {
        _creditAlice(500e6);

        vm.warp(block.timestamp + 90 days + 1);

        vm.expectEmit(true, false, false, true, address(claimer));
        emit IJackpotClaimer.Swept(alice, 500e6, snaxpotAddr);

        vm.expectCall(snaxpotAddr, abi.encodeCall(ISnaxpot.fundJackpot, (500e6)));

        vm.prank(admin);
        claimer.sweepExpired(alice);

        assertEq(claimer.balances(alice), 0);
        assertEq(claimer.expiresAt(alice), 0);
    }

    function test_sweepExpired_whenNotAdmin_reverts() public {
        _creditAlice(500e6);
        vm.warp(block.timestamp + 90 days + 1);

        vm.prank(alice);
        vm.expectRevert(IJackpotClaimer.OnlyAdmin.selector);
        claimer.sweepExpired(alice);
    }

    function test_sweepExpired_whenNotExpired_reverts() public {
        _creditAlice(500e6);

        vm.prank(admin);
        vm.expectRevert(IJackpotClaimer.NotExpired.selector);
        claimer.sweepExpired(alice);
    }

    function test_sweepExpired_whenExactlyAtExpiry_reverts() public {
        _creditAlice(500e6);

        vm.warp(block.timestamp + 90 days);

        vm.prank(admin);
        vm.expectRevert(IJackpotClaimer.NotExpired.selector);
        claimer.sweepExpired(alice);
    }

    function test_sweepExpired_whenNoBalance_reverts() public {
        vm.prank(admin);
        vm.expectRevert(IJackpotClaimer.NotExpired.selector);
        claimer.sweepExpired(alice);
    }

    function test_claimableBalance_returnsZeroForUnknownUser() public view {
        assertEq(claimer.claimableBalance(bob), 0);
    }
}

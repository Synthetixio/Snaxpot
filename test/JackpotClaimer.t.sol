// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";

import {JackpotClaimer} from "../src/JackpotClaimer.sol";
import {IJackpotClaimer} from "../src/interfaces/IJackpotClaimer.sol";

import {MockERC20} from "./mocks/MockERC20.sol";

contract JackpotClaimerTest is Test {
    address snaxpotAddr;
    address admin;
    address alice;
    address bob;

    MockERC20 usdt;
    JackpotClaimer jackpotClaimer;

    function setUp() public {
        admin = makeAddr("admin");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        snaxpotAddr = makeAddr("snaxpot");

        usdt = new MockERC20("Tether USD", "USDT", 6);

        jackpotClaimer = new JackpotClaimer(address(usdt), snaxpotAddr, admin);
    }

    // ─── Helpers ─────────────────────────────────────────────────

    function _creditAlice(uint256 amount) internal {
        usdt.mint(snaxpotAddr, amount);
        vm.startPrank(snaxpotAddr);
        usdt.approve(address(jackpotClaimer), amount);
        jackpotClaimer.credit(alice, 1, amount);
        vm.stopPrank();
    }

    // ─── Tests ───────────────────────────────────────────────────

    function test_initialState() public view {
        assertEq(address(jackpotClaimer.usdt()), address(usdt));
        assertEq(jackpotClaimer.snaxpot(), snaxpotAddr);
        assertEq(jackpotClaimer.admin(), admin);
        assertEq(jackpotClaimer.CLAIM_WINDOW(), 90 days);
    }

    function test_credit_happyPath() public {
        usdt.mint(snaxpotAddr, 500e6);

        vm.startPrank(snaxpotAddr);
        usdt.approve(address(jackpotClaimer), 500e6);

        vm.expectEmit(true, true, false, true, address(jackpotClaimer));
        emit IJackpotClaimer.Credited(alice, 1, 500e6, block.timestamp + 90 days);

        jackpotClaimer.credit(alice, 1, 500e6);
        vm.stopPrank();

        assertEq(jackpotClaimer.balances(alice), 500e6);
        assertEq(jackpotClaimer.expiresAt(alice), block.timestamp + 90 days);
        assertEq(jackpotClaimer.claimableBalance(alice), 500e6);
        assertEq(usdt.balanceOf(address(jackpotClaimer)), 500e6);
    }

    function test_credit_accumulates() public {
        _creditAlice(500e6);

        usdt.mint(snaxpotAddr, 200e6);
        vm.startPrank(snaxpotAddr);
        usdt.approve(address(jackpotClaimer), 200e6);
        jackpotClaimer.credit(alice, 2, 200e6);
        vm.stopPrank();

        assertEq(jackpotClaimer.balances(alice), 700e6);
        assertEq(jackpotClaimer.expiresAt(alice), block.timestamp + 90 days);
    }

    function test_credit_whenNotSnaxpot_reverts() public {
        vm.prank(alice);
        vm.expectRevert(IJackpotClaimer.OnlySnaxpot.selector);
        jackpotClaimer.credit(alice, 1, 500e6);
    }

    function test_credit_whenZeroAmount_reverts() public {
        vm.prank(snaxpotAddr);
        vm.expectRevert(IJackpotClaimer.ZeroAmount.selector);
        jackpotClaimer.credit(alice, 1, 0);
    }

    function test_claim_happyPath() public {
        _creditAlice(500e6);

        vm.expectEmit(true, false, false, true, address(jackpotClaimer));
        emit IJackpotClaimer.Claimed(alice, 500e6);

        vm.prank(alice);
        jackpotClaimer.claim();

        assertEq(jackpotClaimer.balances(alice), 0);
        assertEq(jackpotClaimer.expiresAt(alice), 0);
        assertEq(usdt.balanceOf(alice), 500e6);
        assertEq(usdt.balanceOf(address(jackpotClaimer)), 0);
    }

    function test_claim_whenNothingToClaim_reverts() public {
        vm.prank(alice);
        vm.expectRevert(IJackpotClaimer.NothingToClaim.selector);
        jackpotClaimer.claim();
    }

    function test_sweepExpired_happyPath() public {
        _creditAlice(500e6);

        vm.warp(block.timestamp + 90 days + 1);

        vm.expectEmit(true, false, false, true, address(jackpotClaimer));
        emit IJackpotClaimer.Swept(alice, 500e6, admin);

        vm.prank(admin);
        jackpotClaimer.sweepExpired(alice);

        assertEq(jackpotClaimer.balances(alice), 0);
        assertEq(jackpotClaimer.expiresAt(alice), 0);
        assertEq(usdt.balanceOf(admin), 500e6);
        assertEq(usdt.balanceOf(address(jackpotClaimer)), 0);
    }

    function test_sweepExpired_whenNotAdmin_reverts() public {
        _creditAlice(500e6);
        vm.warp(block.timestamp + 90 days + 1);

        vm.prank(alice);
        vm.expectRevert(IJackpotClaimer.OnlyAdmin.selector);
        jackpotClaimer.sweepExpired(alice);
    }

    function test_sweepExpired_whenNotExpired_reverts() public {
        _creditAlice(500e6);

        vm.prank(admin);
        vm.expectRevert(IJackpotClaimer.NotExpired.selector);
        jackpotClaimer.sweepExpired(alice);
    }

    function test_sweepExpired_whenExactlyAtExpiry_reverts() public {
        _creditAlice(500e6);

        vm.warp(block.timestamp + 90 days);

        vm.prank(admin);
        vm.expectRevert(IJackpotClaimer.NotExpired.selector);
        jackpotClaimer.sweepExpired(alice);
    }

    function test_sweepExpired_whenNoBalance_reverts() public {
        vm.prank(admin);
        vm.expectRevert(IJackpotClaimer.NotExpired.selector);
        jackpotClaimer.sweepExpired(alice);
    }

    function test_claimableBalance_returnsZeroForUnknownUser() public view {
        assertEq(jackpotClaimer.claimableBalance(bob), 0);
    }
}

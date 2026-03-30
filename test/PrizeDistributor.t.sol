// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {PrizeDistributor} from "../src/PrizeDistributor.sol";
import {IPrizeDistributor} from "../src/interfaces/IPrizeDistributor.sol";
import {IDepositContract} from "../src/interfaces/deposit-contract/IDepositContract.sol";

import {MockERC20} from "./mocks/MockERC20.sol";

contract PrizeDistributorTest is Test {
    address admin;
    address operator;
    address alice;
    address bob;
    address depositContract;

    MockERC20 usdt;
    PrizeDistributor distributor;

    function setUp() public {
        admin = makeAddr("admin");
        operator = makeAddr("operator");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        depositContract = makeAddr("depositContract");

        usdt = new MockERC20("Tether USD", "USDT", 6);

        vm.mockCall(depositContract, abi.encodeWithSelector(IDepositContract.deposit.selector), abi.encode());

        distributor = new PrizeDistributor(address(usdt), admin, operator, depositContract);
    }

    // ─── Tests ────────────────────────────────────────────────────

    function test_initialState() public view {
        assertEq(address(distributor.usdt()), address(usdt));
        assertEq(address(distributor.depositContract()), depositContract);
        assertTrue(distributor.hasRole(distributor.DEFAULT_ADMIN_ROLE(), admin));
        assertTrue(distributor.hasRole(distributor.OPERATOR_ROLE(), operator));
    }

    function test_fund_happyPath() public {
        usdt.mint(alice, 1000e6);

        vm.startPrank(alice);
        usdt.approve(address(distributor), 1000e6);

        vm.expectEmit(false, false, false, true, address(distributor));
        emit IPrizeDistributor.PrizePoolFunded(1000e6);

        distributor.fund(1000e6);
        vm.stopPrank();

        assertEq(usdt.balanceOf(address(distributor)), 1000e6);
        assertEq(usdt.balanceOf(alice), 0);
    }

    function test_fund_zeroAmount_reverts() public {
        vm.expectRevert(IPrizeDistributor.ZeroAmount.selector);
        distributor.fund(0);
    }

    function test_distribute_happyPath() public {
        usdt.mint(address(distributor), 700e6);

        address[] memory winners = new address[](2);
        winners[0] = alice;
        winners[1] = bob;
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 500e6;
        amounts[1] = 200e6;
        uint256[] memory subAccountIds = new uint256[](2);
        subAccountIds[0] = 1;
        subAccountIds[1] = 2;

        vm.expectEmit(true, false, false, true, address(distributor));
        emit IPrizeDistributor.PrizeDistributed(alice, 500e6);
        vm.expectEmit(true, false, false, true, address(distributor));
        emit IPrizeDistributor.PrizeDistributed(bob, 200e6);

        vm.expectCall(depositContract, abi.encodeWithSelector(IDepositContract.deposit.selector));

        vm.prank(operator);
        distributor.distribute(winners, amounts, subAccountIds);

        assertEq(usdt.allowance(address(distributor), depositContract), 700e6);
    }

    function test_distribute_arrayLengthMismatch_reverts() public {
        address[] memory winners = new address[](2);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory subAccountIds = new uint256[](2);

        vm.prank(operator);
        vm.expectRevert(IPrizeDistributor.ArrayLengthMismatch.selector);
        distributor.distribute(winners, amounts, subAccountIds);
    }

    function test_distribute_whenNotOperator_reverts() public {
        address[] memory winners = new address[](1);
        uint256[] memory amounts = new uint256[](1);
        uint256[] memory subAccountIds = new uint256[](1);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, distributor.OPERATOR_ROLE()
            )
        );
        vm.prank(alice);
        distributor.distribute(winners, amounts, subAccountIds);
    }

    function test_recoverUSDT_happyPath() public {
        usdt.mint(address(distributor), 1000e6);

        vm.expectEmit(true, false, false, true, address(distributor));
        emit IPrizeDistributor.USDTRecovered(alice, 1000e6);

        vm.prank(admin);
        distributor.recoverUSDT(alice, 1000e6);

        assertEq(usdt.balanceOf(alice), 1000e6);
        assertEq(usdt.balanceOf(address(distributor)), 0);
    }

    function test_recoverUSDT_zeroAddress_reverts() public {
        vm.prank(admin);
        vm.expectRevert(IPrizeDistributor.ZeroAddress.selector);
        distributor.recoverUSDT(address(0), 100e6);
    }

    function test_recoverUSDT_whenNotAdmin_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, distributor.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        distributor.recoverUSDT(alice, 100e6);
    }

    function test_setDepositContract_happyPath() public {
        address newDeposit = makeAddr("newDeposit");

        vm.expectEmit(true, false, false, true, address(distributor));
        emit IPrizeDistributor.DepositContractUpdated(newDeposit);

        vm.prank(admin);
        distributor.setDepositContract(newDeposit);

        assertEq(address(distributor.depositContract()), newDeposit);
    }

    function test_setDepositContract_zeroAddress_reverts() public {
        vm.prank(admin);
        vm.expectRevert(IPrizeDistributor.ZeroAddress.selector);
        distributor.setDepositContract(address(0));
    }

    function test_setDepositContract_whenNotAdmin_reverts() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, distributor.DEFAULT_ADMIN_ROLE()
            )
        );
        vm.prank(alice);
        distributor.setDepositContract(makeAddr("x"));
    }
}

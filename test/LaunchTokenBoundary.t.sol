// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "src/LaunchToken.sol";

contract LaunchTokenBoundaryTest is Test {
    LaunchToken private token;
    address private spender = makeAddr("boundary spender");
    address private receiver = makeAddr("boundary receiver");
    uint256 private constant SUPPLY = 1e27;

    function setUp() public {
        token = new LaunchToken();
    }

    function test_ZeroAndOneUnitTransfersEmitExactEvents() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(this), receiver, 0);
        assertTrue(token.transfer(receiver, 0));
        assertEq(token.balanceOf(receiver), 0);
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Transfer(address(this), receiver, 1);
        assertTrue(token.transfer(receiver, 1));
        assertEq(token.balanceOf(receiver), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY - 1);
    }

    function test_FullSupplyCanRoundTripWithoutFeesOrLimits() public {
        token.transfer(receiver, SUPPLY);
        assertEq(token.balanceOf(receiver), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        vm.prank(receiver);
        token.transfer(address(this), SUPPLY);
        assertEq(token.balanceOf(receiver), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_FullBalanceSelfTransferDoesNotCreateOrDestroyTokens() public {
        token.transfer(address(this), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        token.approve(spender, SUPPLY);
        vm.prank(spender);
        token.transferFrom(address(this), address(this), SUPPLY);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_BurnAddressTransferRetainsFixedSupply() public {
        address burn = 0x000000000000000000000000000000000000dEaD;
        token.transfer(burn, SUPPLY);
        assertEq(token.balanceOf(burn), SUPPLY);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_InfiniteApprovalPersistsUntilExplicitRevocation() public {
        vm.expectEmit(true, true, false, true, address(token));
        emit IERC20.Approval(address(this), spender, type(uint256).max);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        token.transferFrom(address(this), receiver, 1);
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        token.approve(spender, 0);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(address(this), receiver, 1);
        assertEq(token.balanceOf(receiver), 1);
    }

    function test_OverwritingApprovalDoesNotAddToTheOldAllowance() public {
        token.approve(spender, 1_000);
        token.approve(spender, 1);
        assertEq(token.allowance(address(this), spender), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 1, 2));
        vm.prank(spender);
        token.transferFrom(address(this), receiver, 2);
        assertEq(token.allowance(address(this), spender), 1);
        assertEq(token.balanceOf(receiver), 0);
    }

    function test_InvalidRecipientRestoresAllowanceAndBalances() public {
        token.approve(spender, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(spender);
        token.transferFrom(address(this), address(0), 1);
        assertEq(token.allowance(address(this), spender), 1);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(address(0)), 0);
    }

    function test_MaximumAmountFailsWithBalanceErrorAndPreservesInfiniteAllowance() public {
        token.approve(spender, type(uint256).max);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, address(this), SUPPLY, type(uint256).max
            )
        );
        vm.prank(spender);
        token.transferFrom(address(this), receiver, type(uint256).max);
        assertEq(token.allowance(address(this), spender), type(uint256).max);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(receiver), 0);
    }

    function test_ZeroSpenderRejectedAndZeroDelegatedTransferNeedsNoAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidSpender.selector, address(0)));
        token.approve(address(0), 0);
        vm.prank(spender);
        assertTrue(token.transferFrom(address(this), receiver, 0));
        assertEq(token.allowance(address(this), spender), 0);
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertEq(token.balanceOf(receiver), 0);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_FailedTransferFromDoesNotSpendFiniteAllowance(uint256 balanceSeed, uint256 extraSeed) public {
        uint256 balance = bound(balanceSeed, 0, SUPPLY);
        uint256 amount = balance + bound(extraSeed, 1, SUPPLY);
        token.transfer(receiver, balance);
        vm.prank(receiver);
        token.approve(spender, amount);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, receiver, balance, amount)
        );
        vm.prank(spender);
        token.transferFrom(receiver, address(this), amount);
        assertEq(token.balanceOf(receiver), balance);
        assertEq(token.balanceOf(address(this)), SUPPLY - balance);
        assertEq(token.allowance(receiver, spender), amount);
        assertEq(token.totalSupply(), SUPPLY);
    }
}

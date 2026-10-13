// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {JobZero} from "../src/JobZero.sol";
import {AdversarialToken, NoMetadataToken} from "./helpers/AdversarialToken.sol";

contract JobZeroAdversarialTest is Test {
    JobZero private job;
    AdversarialToken private token;
    address private owner = makeAddr("owner");
    address private alice = makeAddr("alice");
    address private bob = makeAddr("bob");
    address private carol = makeAddr("carol");
    address private constant BURN = 0x000000000000000000000000000000000000dEaD;

    function setUp() public {
        vm.warp(10_000);
        token = new AdversarialToken(18);
        job = new JobZero(owner);
        vm.prank(owner);
        job.setToken(address(token));
        token.transfer(alice, 1_000_000 ether);
        token.transfer(bob, 1_000_000 ether);
        token.transfer(carol, 1_000_000 ether);
        vm.prank(alice);
        token.approve(address(job), 100_000 ether);
        vm.prank(bob);
        token.approve(address(job), 100_000 ether);
        vm.prank(carol);
        token.approve(address(job), 100_000 ether);
    }

    function test_TokenConfigurationRejectsWrongOrMissingDecimals() public {
        JobZero unset = new JobZero(owner);
        AdversarialToken sixDecimals = new AdversarialToken(6);
        NoMetadataToken noMetadata = new NoMetadataToken();
        vm.startPrank(owner);
        vm.expectRevert(JobZero.InvalidToken.selector);
        unset.setToken(address(sixDecimals));
        vm.expectRevert(JobZero.InvalidToken.selector);
        unset.setToken(address(noMetadata));
        unset.setToken(address(token));
        vm.stopPrank();
    }

    function test_FalseReturnRollsBackOpenAndQueueAndCanRetry() public {
        token.configure(AdversarialToken.ReturnMode.False, address(0), false);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        vm.prank(alice);
        job.open();
        assertEq(job.currentRun(), 0);
        assertFalse(job.isOpen());
        assertEq(token.balanceOf(address(job)), 0);
        assertEq(token.balanceOf(alice), 1_000_000 ether);
        token.configure(AdversarialToken.ReturnMode.Normal, address(0), false);
        vm.prank(alice);
        job.open();
        token.configure(AdversarialToken.ReturnMode.False, address(0), false);
        vm.expectRevert(abi.encodeWithSelector(SafeERC20.SafeERC20FailedOperation.selector, address(token)));
        vm.prank(bob);
        job.goOnline();
        assertFalse(job.hasJoinedQueue(1, bob));
        assertEq(job.queueLength(1), 0);
        assertEq(job.totalBurned(), 0);
        token.configure(AdversarialToken.ReturnMode.Normal, address(0), false);
        vm.prank(bob);
        job.goOnline();
        assertTrue(job.isOnline(1, bob));
    }

    function test_NoReturnTokenWorksForEveryFundMovement() public {
        token.configure(AdversarialToken.ReturnMode.Empty, address(0), false);
        vm.prank(alice);
        job.open();
        vm.prank(bob);
        job.goOnline();
        vm.prank(alice);
        job.handoff(bob);
        vm.warp(job.deadline());
        job.timeout();
        vm.prank(alice);
        job.claim(1);
        assertEq(token.balanceOf(address(job)), 0);
        assertEq(job.totalLiability(), 0);
        assertEq(token.balanceOf(BURN), 510 ether);
        // A solo timeout also uses safeTransfer with optional return data.
        vm.prank(carol);
        job.open();
        vm.warp(job.deadline());
        job.timeout();
        assertEq(token.balanceOf(BURN), 10_510 ether);
    }

    function test_FeeOnTransferDepositRejectedBeforeAnyLiabilityRemains() public {
        token.configure(AdversarialToken.ReturnMode.Normal, address(0), true);
        vm.expectRevert(JobZero.UnexpectedTokenAmount.selector);
        vm.prank(alice);
        job.open();
        assertEq(job.currentRun(), 0);
        assertEq(job.totalLiability(), 0);
        assertEq(token.balanceOf(address(job)), 0);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_FailedBurnRollsBackHandoffIncludingQueueAndStats() public {
        vm.prank(alice);
        job.open();
        vm.prank(bob);
        job.goOnline();
        token.configure(AdversarialToken.ReturnMode.Normal, BURN, false);
        vm.expectRevert(AdversarialToken.TransferRejected.selector);
        vm.prank(alice);
        job.handoff(bob);
        assertEq(job.worker(), alice);
        assertEq(job.runs(1).attempts, 1);
        assertEq(job.runs(1).bounty, 10_000 ether);
        assertEq(job.totalLiability(), 10_000 ether);
        assertEq(job.totalBurned(), 10 ether);
        assertTrue(job.isOnline(1, bob));
        assertFalse(job.hasHeld(1, bob));
        (, uint256 handoffs,,) = job.workerStats(alice);
        assertEq(handoffs, 0);
        token.configure(AdversarialToken.ReturnMode.Normal, address(0), false);
        vm.prank(alice);
        job.handoff(bob);
        assertEq(job.worker(), bob);
    }

    function test_FailedSoloSettlementRollsBackAndCanRetry() public {
        vm.prank(alice);
        job.open();
        vm.warp(job.deadline());
        token.configure(AdversarialToken.ReturnMode.Normal, BURN, false);
        vm.expectRevert(AdversarialToken.TransferRejected.selector);
        job.timeout();
        assertTrue(job.isOpen());
        assertFalse(job.runs(1).closed);
        assertEq(job.runs(1).failedWorker, address(0));
        assertEq(job.totalLiability(), 10_000 ether);
        assertEq(job.totalBurned(), 0);
        (,,, uint256 failed) = job.workerStats(alice);
        assertEq(failed, 0);
        token.configure(AdversarialToken.ReturnMode.Normal, address(0), false);
        job.timeout();
        assertFalse(job.isOpen());
        assertEq(job.totalLiability(), 0);
    }

    function test_FailedClaimPreservesEntitlementAndDoesNotBlockOtherClaims() public {
        vm.prank(alice);
        job.open();
        vm.prank(alice);
        job.handoff(bob);
        vm.prank(bob);
        job.handoff(carol);
        vm.warp(job.deadline());
        job.timeout();
        uint256 share = job.claimable(1, alice);
        token.configure(AdversarialToken.ReturnMode.Normal, alice, false);
        vm.expectRevert(AdversarialToken.TransferRejected.selector);
        vm.prank(alice);
        job.claim(1);
        assertFalse(job.claimed(1, alice));
        assertEq(job.runs(1).claimedCount, 0);
        assertEq(job.claimable(1, alice), share);
        (,, uint256 earned,) = job.workerStats(alice);
        assertEq(earned, 0);
        vm.prank(bob);
        job.claim(1);
        assertEq(job.totalLiability(), share);
        token.configure(AdversarialToken.ReturnMode.Normal, address(0), false);
        vm.prank(alice);
        job.claim(1);
        assertEq(job.totalLiability(), 0);
        assertEq(token.balanceOf(address(job)), 0);
    }

    function test_ReentrancyIntoEveryMutationIsRejectedDuringOpen() public {
        bytes[7] memory payloads = [
            abi.encodeCall(JobZero.open, ()),
            abi.encodeCall(JobZero.handoff, (bob)),
            abi.encodeCall(JobZero.timeout, ()),
            abi.encodeCall(JobZero.claim, (1)),
            abi.encodeCall(JobZero.goOnline, ()),
            abi.encodeCall(JobZero.goOffline, ()),
            abi.encodeCall(JobZero.setToken, (address(token)))
        ];
        for (uint256 i; i < payloads.length; i++) {
            JobZero target = new JobZero(owner);
            vm.prank(owner);
            target.setToken(address(token));
            vm.prank(alice);
            token.approve(address(target), 10_000 ether);
            token.setCallback(address(target), payloads[i]);
            vm.prank(alice);
            target.open();
            _assertReentrancyRejected();
            assertEq(target.currentRun(), 1);
            assertEq(target.runs(1).attempts, 1);
            assertEq(target.totalLiability(), 10_000 ether);
        }
        assertEq(token.callbacks(), 7);
    }

    function test_ReentrancyDuringHandoffQueueAndTimeoutIsRejected() public {
        vm.prank(alice);
        job.open();
        token.setCallback(address(job), abi.encodeCall(JobZero.goOnline, ()));
        vm.prank(bob);
        job.goOnline();
        _assertReentrancyRejected();
        assertEq(token.callbacks(), 2); // incoming payment and outgoing burn
        token.setCallback(address(job), abi.encodeCall(JobZero.handoff, (carol)));
        vm.prank(alice);
        job.handoff(bob);
        _assertReentrancyRejected();
        assertEq(token.callbacks(), 4);
        vm.warp(job.deadline());
        job.timeout();
        token.setCallback(address(job), abi.encodeCall(JobZero.open, ()));
        vm.prank(carol);
        job.open();
        token.setCallback(address(job), abi.encodeCall(JobZero.timeout, ()));
        vm.warp(job.deadline());
        job.timeout();
        _assertReentrancyRejected();
        assertFalse(job.isOpen());
        assertEq(job.totalLiability(), 10_500 ether);
    }

    function test_ReentrantEligibleClaimCannotPayTwice() public {
        // The callback token is itself an eligible worker, so identity checks cannot mask the guard.
        token.transfer(address(token), 20_000 ether);
        vm.startPrank(address(token));
        token.approve(address(job), 11_000 ether);
        job.open();
        job.handoff(bob);
        vm.stopPrank();
        vm.warp(job.deadline());
        job.timeout();
        token.setCallback(address(job), abi.encodeCall(JobZero.claim, (1)));
        uint256 before = token.balanceOf(address(token));
        vm.prank(address(token));
        job.claim(1);
        _assertReentrancyRejected();
        assertEq(token.balanceOf(address(token)), before + 10_500 ether);
        assertEq(job.runs(1).claimedCount, 1);
        assertEq(job.totalLiability(), 0);
        assertEq(token.balanceOf(address(job)), 0);
    }

    function _assertReentrancyRejected() private view {
        assertFalse(token.callbackSuccess());
        assertEq(token.callbackResult(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
    }
}

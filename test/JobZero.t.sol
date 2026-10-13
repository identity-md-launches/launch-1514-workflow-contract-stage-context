// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {JobZeroFixture} from "./helpers/JobZeroFixture.sol";
import {JobZero} from "../src/JobZero.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract JobZeroTest is JobZeroFixture {
    function test_ExplicitOwnerAndUnconfiguredState() public {
        JobZero unset = new JobZero(owner);
        assertEq(unset.owner(), owner);
        assertEq(address(unset.token()), address(0));
        assertEq(unset.currentRun(), 0);
        assertFalse(unset.isOpen());
        assertEq(unset.worker(), address(0));
        assertEq(unset.deadline(), 0);
        assertEq(unset.handoffFee(), FIRST_FEE);
        vm.expectRevert(JobZero.TokenNotConfigured.selector);
        unset.open();
        vm.expectRevert(JobZero.TokenNotConfigured.selector);
        unset.handoff(alice);
        vm.expectRevert(JobZero.TokenNotConfigured.selector);
        unset.timeout();
        vm.expectRevert(JobZero.TokenNotConfigured.selector);
        unset.claim(1);
        vm.expectRevert(JobZero.TokenNotConfigured.selector);
        unset.goOnline();
        vm.expectRevert(JobZero.TokenNotConfigured.selector);
        unset.goOffline();
        vm.expectRevert(JobZero.InvalidOwner.selector);
        new JobZero(address(0));
    }

    function test_TokenSetOnceByOwnerOnlyAndRejectsInvalidAddresses() public {
        JobZero unset = new JobZero(owner);
        vm.expectRevert(JobZero.Unauthorized.selector);
        unset.setToken(address(token));
        vm.startPrank(owner);
        vm.expectRevert(JobZero.InvalidToken.selector);
        unset.setToken(address(0));
        vm.expectRevert(JobZero.InvalidToken.selector);
        unset.setToken(alice);
        vm.expectRevert(JobZero.InvalidToken.selector);
        unset.setToken(address(unset));
        vm.expectEmit(true, false, false, true, address(unset));
        emit JobZero.TokenSet(address(token));
        unset.setToken(address(token));
        vm.expectRevert(JobZero.TokenAlreadySet.selector);
        unset.setToken(address(token));
        vm.stopPrank();
        assertEq(address(unset.token()), address(token));
    }

    function test_NoRunActionsAndNothingToClaim() public {
        vm.expectRevert(JobZero.NoOpenRun.selector);
        job.handoff(alice);
        vm.expectRevert(JobZero.NoOpenRun.selector);
        job.timeout();
        vm.expectRevert(JobZero.NoOpenRun.selector);
        job.goOnline();
        vm.expectRevert(JobZero.NoOpenRun.selector);
        job.goOffline();
        vm.expectRevert(JobZero.NothingToClaim.selector);
        job.claim(1);
        assertEq(job.claimable(type(uint256).max, alice), 0);
    }

    function test_OpenChargesFeeAndRecordsFirstWorker() public {
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        token.approve(address(job), OPEN);
        vm.expectEmit(true, true, false, true, address(job));
        emit JobZero.Opened(1, alice, vm.getBlockTimestamp() + 1 days, OPEN);
        vm.prank(alice);
        job.open();
        JobZero.Run memory run = job.runs(1);
        assertEq(job.currentRun(), 1);
        assertTrue(job.isOpen());
        assertEq(run.worker, alice);
        assertEq(run.attempts, 1);
        assertEq(run.openedAt, vm.getBlockTimestamp());
        assertEq(run.deadline, vm.getBlockTimestamp() + 1 days);
        assertEq(run.fee, FIRST_FEE);
        assertEq(run.bounty, OPEN);
        assertFalse(run.closed);
        assertTrue(job.hasHeld(1, alice));
        assertEq(token.balanceOf(alice), before - OPEN);
        assertEq(token.balanceOf(address(job)), OPEN);
        assertEq(job.totalLiability(), OPEN);
        assertEq(token.balanceOf(BURN), 0);
        (uint256 attempts, uint256 handoffs, uint256 earned, uint256 failed) = job.workerStats(alice);
        assertEq(attempts, 1);
        assertEq(handoffs + earned + failed, 0);
        assertEq(job.claimable(1, alice), 0);
        vm.expectRevert(JobZero.RunAlreadyOpen.selector);
        job.open();
    }

    function test_OpenWithoutAllowanceOrBalanceRollsBackEverything() public {
        vm.expectRevert();
        vm.prank(alice);
        job.open();
        assertEq(job.currentRun(), 0);
        assertEq(job.totalLiability(), 0);
        assertFalse(job.hasHeld(1, alice));
        address broke = makeAddr("broke");
        vm.startPrank(broke);
        token.approve(address(job), OPEN);
        vm.expectRevert();
        job.open();
        vm.stopPrank();
        assertFalse(job.isOpen());
        assertEq(job.getAttempts(1, 0, 100).length, 0);
        _open(alice);
        assertEq(job.currentRun(), 1);
    }

    function test_OnlyWorkerAndNoZeroSelfOrRepeatRecipient() public {
        _open(alice);
        vm.expectRevert(JobZero.NotWorker.selector);
        vm.prank(bob);
        job.handoff(carol);
        vm.startPrank(alice);
        vm.expectRevert(JobZero.InvalidRecipient.selector);
        job.handoff(address(0));
        vm.expectRevert(JobZero.InvalidRecipient.selector);
        job.handoff(alice);
        vm.stopPrank();
        _handoff(bob);
        vm.expectRevert(JobZero.AlreadyHeld.selector);
        vm.prank(bob);
        job.handoff(alice);
        assertEq(job.runs(1).attempts, 2);
    }

    function test_HandoffGrowthBurnBountyDeadlineAndAttempts() public {
        _open(alice);
        uint256 openedAt = vm.getBlockTimestamp();
        vm.warp(vm.getBlockTimestamp() + 7 hours);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        token.approve(address(job), FIRST_FEE);
        vm.expectEmit(true, true, true, true, address(job));
        emit JobZero.HandedOff(1, alice, bob, FIRST_FEE, 2);
        vm.prank(alice);
        job.handoff(bob);
        assertEq(token.balanceOf(alice), before - FIRST_FEE);
        assertEq(token.balanceOf(BURN), 500 ether);
        assertEq(token.balanceOf(address(job)), 10_500 ether);
        assertEq(job.handoffFee(), 1_030 ether);
        assertEq(job.deadline(), vm.getBlockTimestamp() + 1 days);
        _handoff(carol);
        assertEq(job.handoffFee(), 1_060.9 ether);
        assertEq(job.runs(1).bounty, 11_015 ether);
        assertEq(job.totalLiability(), 11_015 ether);
        assertEq(job.totalBurned(), 1_015 ether);
        assertEq(token.balanceOf(BURN), 1_015 ether);
        JobZero.Attempt[] memory attempts = job.getAttempts(1, 0, 100);
        assertEq(attempts.length, 3);
        assertEq(attempts[0].worker, carol);
        assertEq(uint256(attempts[0].status), uint256(JobZero.Status.Holding));
        assertEq(attempts[1].worker, bob);
        assertEq(uint256(attempts[1].status), uint256(JobZero.Status.HandedOff));
        assertEq(attempts[2].worker, alice);
        assertEq(attempts[2].startedAt, openedAt);
        assertEq(attempts[2].endedAt, vm.getBlockTimestamp());
        assertEq(job.biggestBounty(), 11_015 ether);
        assertEq(job.mostHandoffs(), 2);
    }

    function test_HandoffAtLastSecondAndTimeoutAtExactDeadline() public {
        _open(alice);
        vm.warp(job.deadline() - 1);
        vm.expectRevert(JobZero.DeadlineNotReached.selector);
        job.timeout();
        _handoff(bob);
        uint256 expiry = job.deadline();
        vm.warp(expiry);
        vm.expectRevert(JobZero.DeadlinePassed.selector);
        vm.prank(bob);
        job.handoff(carol);
        vm.expectEmit(true, true, false, true, address(job));
        emit JobZero.TimedOut(1, bob, 2, 10_500 ether);
        vm.prank(dave);
        job.timeout();
        assertFalse(job.isOpen());
        assertEq(job.worker(), address(0));
        assertEq(job.deadline(), 0);
        assertEq(job.runs(1).closedAt, expiry);
        assertEq(job.runs(1).failedWorker, bob);
        assertEq(uint256(job.getAttempts(1, 0, 1)[0].status), uint256(JobZero.Status.Failed));
        assertEq(job.claimable(1, bob), 0);
        vm.expectRevert(JobZero.NoOpenRun.selector);
        job.timeout();
    }

    function test_ExpiredRunBlocksOpenAndLateHandoffUntilTimeout() public {
        _open(alice);
        vm.warp(job.deadline() + 17 days);
        vm.expectRevert(JobZero.RunAlreadyOpen.selector);
        job.open();
        vm.expectRevert(JobZero.DeadlinePassed.selector);
        vm.prank(alice);
        job.handoff(bob);
        job.timeout();
        _open(bob);
        assertEq(job.currentRun(), 2);
        assertEq(job.runs(2).fee, FIRST_FEE);
    }

    function test_SoloRunBurnsWholeBountyAndFailedWorkerGetsNothing() public {
        _open(alice);
        _close();
        assertEq(token.balanceOf(address(job)), 0);
        assertEq(token.balanceOf(BURN), OPEN);
        assertEq(job.totalBurned(), OPEN);
        assertEq(job.totalLiability(), 0);
        assertEq(job.runs(1).bounty, OPEN);
        assertEq(job.runs(1).share, 0);
        assertEq(job.claimable(1, alice), 0);
        vm.expectRevert(JobZero.NothingToClaim.selector);
        _claim(1, alice);
        (,,, uint256 failed) = job.workerStats(alice);
        assertEq(failed, 1);
    }

    function test_EqualClaimsExcludeFailedAndOutsidersAndPreventDoubleClaim() public {
        _open(alice);
        _handoff(bob);
        _handoff(carol);
        vm.expectRevert(JobZero.NothingToClaim.selector);
        _claim(1, alice);
        _close();
        uint256 share = 11_015 ether / 2;
        assertEq(job.claimable(1, alice), share);
        assertEq(job.claimable(1, bob), share);
        assertEq(job.claimable(1, carol), 0);
        assertEq(job.claimable(1, dave), 0);
        vm.expectRevert(JobZero.NothingToClaim.selector);
        _claim(1, carol);
        vm.expectRevert(JobZero.NothingToClaim.selector);
        _claim(1, dave);
        uint256 before = token.balanceOf(bob);
        vm.expectEmit(true, true, false, true, address(job));
        emit JobZero.Claimed(1, bob, share);
        _claim(1, bob);
        assertEq(token.balanceOf(bob), before + share);
        assertTrue(job.claimed(1, bob));
        assertEq(job.claimable(1, bob), 0);
        vm.expectRevert(JobZero.NothingToClaim.selector);
        _claim(1, bob);
        _claim(1, alice);
        assertEq(job.runs(1).claimedCount, 2);
        assertEq(job.totalLiability(), 0);
        assertEq(token.balanceOf(address(job)), 0);
        (uint256 attempts, uint256 handoffs, uint256 earned,) = job.workerStats(bob);
        assertEq(attempts, 1);
        assertEq(handoffs, 1);
        assertEq(earned, share);
    }

    function test_CrossRunClaimsAndWorkerEligibilityRemainIndependent() public {
        _open(alice);
        _handoff(bob);
        _close();
        _open(alice);
        _handoff(bob);
        assertEq(job.currentRun(), 2);
        assertEq(job.claimable(1, alice), 10_500 ether);
        assertEq(job.claimable(2, alice), 0);
        _claim(1, alice);
        assertEq(token.balanceOf(address(job)), 10_500 ether);
        assertEq(job.totalLiability(), 10_500 ether);
        _close();
        _claim(2, alice);
        assertEq(token.balanceOf(address(job)), 0);
        (uint256 attempts, uint256 handoffs, uint256 earned,) = job.workerStats(alice);
        assertEq(attempts, 2);
        assertEq(handoffs, 2);
        assertEq(earned, 21_000 ether);
        (,,, uint256 failed) = job.workerStats(bob);
        assertEq(failed, 2);
    }

    function test_RoundingBurnsDustAndPaysIdenticalShares() public {
        _open(alice);
        _handoff(bob);
        _handoff(carol);
        _handoff(dave);
        uint256 bounty = job.runs(1).bounty;
        assertGt(bounty % 3, 0);
        uint256 before = job.totalBurned();
        _close();
        assertEq(job.totalBurned() - before, bounty % 3);
        assertEq(job.totalLiability(), (bounty / 3) * 3);
        _claim(1, carol);
        _claim(1, alice);
        _claim(1, bob);
        assertEq(job.totalLiability(), 0);
        assertEq(token.balanceOf(address(job)), 0);
        assertEq(token.balanceOf(BURN), job.totalBurned());
    }

    function test_LongestRunUsesDeadlineAndLiveElapsedTime() public {
        (uint256 id, uint256 duration) = job.longestRun();
        assertEq(id + duration, 0);
        _open(alice);
        vm.warp(vm.getBlockTimestamp() + 12 hours);
        (id, duration) = job.longestRun();
        assertEq(id, 1);
        assertEq(duration, 12 hours);
        _handoff(bob);
        uint256 expiry = job.deadline();
        vm.warp(expiry + 100 days);
        (id, duration) = job.longestRun();
        assertEq(duration, 36 hours);
        job.timeout();
        assertEq(job.runs(1).closedAt, vm.getBlockTimestamp());
        assertEq(job.getAttempts(1, 0, 1)[0].endedAt, expiry);
        _open(carol);
        _close();
        (id, duration) = job.longestRun();
        assertEq(id, 1);
        assertEq(duration, 36 hours);
        _open(carol);
        vm.warp(vm.getBlockTimestamp() + 20 hours);
        _handoff(dave);
        vm.warp(vm.getBlockTimestamp() + 20 hours);
        (id, duration) = job.longestRun();
        assertEq(id, 3);
        assertEq(duration, 40 hours);
        _close();
        (id, duration) = job.longestRun();
        assertEq(id, 3);
        assertEq(duration, 44 hours);
    }

    function test_UnsolicitedTokensCannotChangeBountyOrBeWithdrawnByOwner() public {
        _open(alice);
        token.transfer(address(job), 123 ether);
        assertEq(job.runs(1).bounty, OPEN);
        _close();
        assertEq(token.balanceOf(address(job)), 123 ether);
        assertEq(job.totalLiability(), 0);
        vm.prank(owner);
        (bool success,) = address(job).call(abi.encodeWithSignature("withdraw(address,uint256)", owner, 123 ether));
        assertFalse(success);
    }

    function test_RejectsETHIncludingWithValidCalldata() public {
        vm.deal(alice, 1 ether);
        vm.startPrank(alice);
        (bool direct,) = address(job).call{value: 1}("");
        (bool payableOpen,) = address(job).call{value: 1}(abi.encodeCall(JobZero.open, ()));
        (bool unknownSelector,) = address(job).call(hex"12345678");
        vm.stopPrank();
        assertFalse(direct);
        assertFalse(payableOpen);
        assertFalse(unknownSelector);
        assertEq(address(job).balance, 0);
    }

    function testFuzz_FeeAndFundsConservation(uint8 handoffsSeed) public {
        uint256 count = bound(handoffsSeed, 1, 120);
        _open(alice);
        uint256 expectedBounty = OPEN;
        uint256 expectedBurn;
        uint256 expectedFee = FIRST_FEE;
        address[] memory workers = new address[](count + 1);
        workers[0] = alice;
        for (uint256 i; i < count; ++i) {
            address next = address(uint160(0x100000 + i));
            _fund(next, expectedFee * 2);
            _handoff(next);
            workers[i + 1] = next;
            expectedBounty += expectedFee - expectedFee / 2;
            expectedBurn += expectedFee / 2;
            expectedFee = expectedFee * 103 / 100;
            assertEq(job.handoffFee(), expectedFee);
            assertEq(job.runs(1).bounty, expectedBounty);
            assertEq(token.balanceOf(address(job)), expectedBounty);
            assertEq(job.totalBurned(), expectedBurn);
        }
        _close();
        uint256 share = expectedBounty / count;
        expectedBurn += expectedBounty % count;
        for (uint256 i; i < count; ++i) {
            assertEq(job.claimable(1, workers[i]), share);
            _claim(1, workers[i]);
        }
        assertEq(job.claimable(1, workers[count]), 0);
        assertEq(job.totalLiability(), 0);
        assertEq(token.balanceOf(address(job)), 0);
        assertEq(token.balanceOf(BURN), expectedBurn);
        assertEq(token.totalSupply(), 1e27);
    }
}

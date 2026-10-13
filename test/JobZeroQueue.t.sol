// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {JobZeroFixture} from "./helpers/JobZeroFixture.sol";
import {JobZero} from "../src/JobZero.sol";

contract JobZeroQueueTest is JobZeroFixture {
    function test_QueueJoinBurnsFeeAndIsNewestFirst() public {
        _open(alice);
        uint256 before = token.balanceOf(bob);
        vm.prank(bob);
        token.approve(address(job), ONLINE);
        vm.expectEmit(true, true, false, true, address(job));
        emit JobZero.Online(1, bob, vm.getBlockTimestamp());
        vm.prank(bob);
        job.goOnline();
        vm.warp(vm.getBlockTimestamp() + 60);
        _online(carol);
        JobZero.QueueEntry[] memory page = job.getQueue(1, 0, 100);
        assertEq(page.length, 2);
        assertEq(page[0].worker, carol);
        assertEq(page[0].onlineAt, vm.getBlockTimestamp());
        assertEq(page[1].worker, bob);
        assertEq(page[1].onlineAt, vm.getBlockTimestamp() - 60);
        assertEq(token.balanceOf(bob), before - ONLINE);
        assertEq(job.totalBurned(), ONLINE * 2);
        assertEq(token.balanceOf(BURN), ONLINE * 2);
        assertEq(token.balanceOf(address(job)), OPEN);
        assertEq(job.totalLiability(), OPEN);
        assertEq(job.queueLength(1), 2);
        assertTrue(job.isOnline(1, bob));
        assertTrue(job.hasJoinedQueue(1, bob));
    }

    function test_QueueRejectsCurrentPastAndDuplicateWorkers() public {
        _open(alice);
        vm.expectRevert(JobZero.AlreadyHeld.selector);
        vm.prank(alice);
        job.goOnline();
        _online(carol);
        vm.expectRevert(JobZero.AlreadyJoined.selector);
        vm.prank(carol);
        job.goOnline();
        _handoff(bob);
        vm.expectRevert(JobZero.AlreadyHeld.selector);
        vm.prank(alice);
        job.goOnline();
        vm.expectRevert(JobZero.AlreadyHeld.selector);
        vm.prank(bob);
        job.goOnline();
        assertEq(job.queueLength(1), 1);
    }

    function test_OfflineHasNoRefundAndEntryCannotBeReused() public {
        _open(alice);
        _online(bob);
        uint256 before = token.balanceOf(bob);
        vm.expectEmit(true, true, false, true, address(job));
        emit JobZero.Offline(1, bob);
        vm.prank(bob);
        job.goOffline();
        assertFalse(job.isOnline(1, bob));
        assertTrue(job.hasJoinedQueue(1, bob));
        assertEq(job.queueLength(1), 0);
        assertEq(token.balanceOf(bob), before);
        vm.expectRevert(JobZero.NotOnline.selector);
        vm.prank(bob);
        job.goOffline();
        vm.expectRevert(JobZero.AlreadyJoined.selector);
        vm.prank(bob);
        job.goOnline();
        // Queue membership is optional: an offline wallet can still receive the job.
        _handoff(bob);
        assertEq(job.worker(), bob);
    }

    function test_RemovesMiddleHeadAndTailInConstantWork() public {
        _open(alice);
        _online(bob);
        _online(carol);
        _online(dave);
        vm.prank(carol);
        job.goOffline();
        JobZero.QueueEntry[] memory page = job.getQueue(1, 0, 100);
        assertEq(page.length, 2);
        assertEq(page[0].worker, dave);
        assertEq(page[1].worker, bob);
        vm.prank(alice);
        token.approve(address(job), FIRST_FEE);
        vm.expectEmit(true, true, false, true, address(job));
        emit JobZero.Offline(1, dave);
        vm.prank(alice);
        job.handoff(dave);
        assertEq(job.queueLength(1), 1);
        assertEq(job.getQueue(1, 0, 1)[0].worker, bob);
        _handoff(bob);
        assertEq(job.queueLength(1), 0);
        assertFalse(job.isOnline(1, bob));
        assertFalse(job.isOnline(1, dave));
        assertEq(job.getQueue(1, 0, 100).length, 0);
    }

    function test_TailAndMiddleAutomaticRemovalPreserveOrder() public {
        _open(alice);
        _online(bob);
        _online(carol);
        _online(dave);
        _handoff(carol);
        _handoff(bob);
        JobZero.QueueEntry[] memory page = job.getQueue(1, 0, 100);
        assertEq(page.length, 1);
        assertEq(page[0].worker, dave);
        vm.prank(dave);
        job.goOffline();
        _online(makeFundedWorker());
        assertEq(job.queueLength(1), 1);
    }

    function makeFundedWorker() private returns (address wallet) {
        wallet = makeAddr("fresh queue worker");
        _fund(wallet, ONLINE);
    }

    function test_UnpaidJoinDoesNotConsumeEligibility() public {
        _open(alice);
        vm.expectRevert();
        vm.prank(bob);
        job.goOnline();
        assertFalse(job.hasJoinedQueue(1, bob));
        assertFalse(job.isOnline(1, bob));
        assertEq(job.queueLength(1), 0);
        assertEq(job.totalBurned(), 0);
        _online(bob);
        assertTrue(job.isOnline(1, bob));
    }

    function test_UnpaidHandoffPreservesQueueAndAttempt() public {
        _open(alice);
        _online(bob);
        vm.expectRevert();
        vm.prank(alice);
        job.handoff(bob);
        assertTrue(job.isOnline(1, bob));
        assertEq(job.queueLength(1), 1);
        assertEq(job.worker(), alice);
        assertFalse(job.hasHeld(1, bob));
        assertEq(job.runs(1).attempts, 1);
        assertEq(job.runs(1).bounty, OPEN);
    }

    function test_ExpiryBlocksJoiningButAllowsLeavingAndClosureClearsQueue() public {
        _open(alice);
        _online(bob);
        _online(carol);
        vm.warp(job.deadline());
        vm.expectRevert(JobZero.DeadlinePassed.selector);
        vm.prank(dave);
        job.goOnline();
        vm.prank(bob);
        job.goOffline();
        assertEq(job.queueLength(1), 1);
        job.timeout();
        assertEq(job.queueLength(1), 0);
        assertFalse(job.isOnline(1, carol));
        assertTrue(job.hasJoinedQueue(1, carol));
        assertEq(job.getQueue(1, 0, 100).length, 0);
        vm.expectRevert(JobZero.NoOpenRun.selector);
        vm.prank(carol);
        job.goOffline();
        _open(alice);
        _online(carol);
        assertTrue(job.isOnline(2, carol));
        assertEq(job.queueLength(2), 1);
        assertEq(job.queueLength(1), 0);
    }

    function test_PaginationBoundariesAndUnknownRuns() public {
        _open(alice);
        _online(bob);
        _online(carol);
        _online(dave);
        JobZero.QueueEntry[] memory page = job.getQueue(1, 1, 1);
        assertEq(page.length, 1);
        assertEq(page[0].worker, carol);
        assertEq(job.getQueue(1, 2, 100)[0].worker, bob);
        assertEq(job.getQueue(1, 3, 100).length, 0);
        assertEq(job.getQueue(1, type(uint256).max, 100).length, 0);
        assertEq(job.getQueue(1, 0, 0).length, 0);
        assertEq(job.getQueue(99, 0, 100).length, 0);
        vm.expectRevert(JobZero.PageTooLarge.selector);
        job.getQueue(1, 0, 101);
        _handoff(bob);
        _handoff(carol);
        JobZero.Attempt[] memory attempts = job.getAttempts(1, 1, 1);
        assertEq(attempts.length, 1);
        assertEq(attempts[0].worker, bob);
        assertEq(job.getAttempts(1, 2, 100)[0].worker, alice);
        assertEq(job.getAttempts(1, 3, 100).length, 0);
        assertEq(job.getAttempts(1, type(uint256).max, 100).length, 0);
        assertEq(job.getAttempts(1, 0, 0).length, 0);
        assertEq(job.getAttempts(99, 0, 100).length, 0);
        vm.expectRevert(JobZero.PageTooLarge.selector);
        job.getAttempts(1, 0, 101);
    }

    function test_HundredEntryPageAndNoScanningRemovedNodes() public {
        _open(alice);
        for (uint256 i; i < 105; i++) {
            address wallet = address(uint160(0x200000 + i));
            _fund(wallet, ONLINE);
            _online(wallet);
        }
        assertEq(job.getQueue(1, 0, 100).length, 100);
        assertEq(job.getQueue(1, 100, 100).length, 5);
        for (uint256 i; i < 104; i++) {
            vm.prank(address(uint160(0x200000 + i)));
            job.goOffline();
        }
        JobZero.QueueEntry[] memory page = job.getQueue(1, 0, 100);
        assertEq(page.length, 1);
        assertEq(page[0].worker, address(uint160(0x200000 + 104)));
        assertEq(job.queueLength(1), 1);
    }
}

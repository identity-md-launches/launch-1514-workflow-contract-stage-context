// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {JobZero} from "../src/JobZero.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

/// @dev Independent ledger of users' payments and ordered participation across arbitrarily interleaved runs.
contract JobZeroHandler is Test {
    JobZero public immutable job;
    LaunchToken public immutable token;
    address[8] public actors;
    uint256 public payments;
    uint256 public burns;
    uint256 public payouts;
    uint256 public donations;
    uint256 public runCount;
    uint256 public currentFee;
    mapping(uint256 => uint256) public bounty;
    mapping(uint256 => bool) public closed;
    mapping(uint256 => address[]) private _workers;
    mapping(uint256 => address[]) private _joinOrder;
    mapping(uint256 => mapping(address => bool)) public held;
    mapping(uint256 => mapping(address => bool)) public joined;
    mapping(uint256 => mapping(address => bool)) public online;
    mapping(uint256 => mapping(address => bool)) public paid;
    mapping(address => uint256) public attempts;
    mapping(address => uint256) public handoffs;
    mapping(address => uint256) public earned;
    mapping(address => uint256) public spent;
    mapping(address => uint256) public failures;
    mapping(uint256 => uint256[]) private _startedAt;
    mapping(uint256 => uint256) public closedAt;
    mapping(uint256 => uint256) public closingFee;
    mapping(uint256 => mapping(address => uint256)) public joinedAt;

    constructor(JobZero job_, LaunchToken token_) {
        job = job_;
        token = token_;
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = address(uint160(uint256(keccak256(abi.encode("invariant worker", i)))));
        }
    }

    function open(uint256 seed) external {
        if (runCount != 0 && !closed[runCount]) return;
        address wallet = actors[seed % actors.length];
        vm.startPrank(wallet);
        token.approve(address(job), 10_000 ether);
        job.open();
        vm.stopPrank();
        ++runCount;
        currentFee = 1_000 ether;
        bounty[runCount] = 10_000 ether;
        payments += 10_000 ether;
        spent[wallet] += 10_000 ether;
        _recordWorker(wallet);
    }

    function handoff(uint256 seed) external {
        if (!_canAct()) return;
        address to = actors[seed % actors.length];
        if (held[runCount][to]) return;
        address from = _workers[runCount][_workers[runCount].length - 1];
        vm.startPrank(from);
        token.approve(address(job), currentFee);
        job.handoff(to);
        vm.stopPrank();
        payments += currentFee;
        spent[from] += currentFee;
        burns += currentFee / 2;
        bounty[runCount] += currentFee - currentFee / 2;
        currentFee = currentFee * 103 / 100;
        handoffs[from]++;
        _recordWorker(to);
        online[runCount][to] = false;
    }

    function join(uint256 seed) external {
        if (!_canAct()) return;
        address wallet = actors[seed % actors.length];
        if (held[runCount][wallet] || joined[runCount][wallet]) return;
        vm.startPrank(wallet);
        token.approve(address(job), 10 ether);
        job.goOnline();
        vm.stopPrank();
        joined[runCount][wallet] = true;
        online[runCount][wallet] = true;
        joinedAt[runCount][wallet] = vm.getBlockTimestamp();
        _joinOrder[runCount].push(wallet);
        payments += 10 ether;
        spent[wallet] += 10 ether;
        burns += 10 ether;
    }

    function leave(uint256 seed) external {
        if (runCount == 0 || closed[runCount]) return;
        address wallet = actors[seed % actors.length];
        if (!online[runCount][wallet]) return;
        vm.prank(wallet);
        job.goOffline();
        online[runCount][wallet] = false;
    }

    function advanceTime(uint256 secondsSeed) external {
        vm.warp(vm.getBlockTimestamp() + (secondsSeed % 2 days));
    }

    function expireAndTimeout(uint256 delaySeed) external {
        if (runCount == 0 || closed[runCount]) return;
        uint256 expiry = _expectedDeadline();
        if (vm.getBlockTimestamp() < expiry) vm.warp(expiry);
        vm.warp(vm.getBlockTimestamp() + (delaySeed % 3 days));
        job.timeout();
        closed[runCount] = true;
        closedAt[runCount] = vm.getBlockTimestamp();
        closingFee[runCount] = currentFee;
        uint256 length = _workers[runCount].length;
        failures[_workers[runCount][length - 1]]++;
        burns += length == 1 ? bounty[runCount] : bounty[runCount] % (length - 1);
    }

    function claim(uint256 runSeed, uint256 workerSeed) external {
        if (runCount == 0) return;
        uint256 id = 1 + runSeed % runCount;
        if (!closed[id]) return;
        uint256 length = _workers[id].length;
        if (length <= 1) return;
        address wallet = _workers[id][workerSeed % (length - 1)];
        if (paid[id][wallet]) return;
        vm.prank(wallet);
        job.claim(id);
        paid[id][wallet] = true;
        uint256 amount = bounty[id] / (length - 1);
        payouts += amount;
        earned[wallet] += amount;
    }

    function donate(uint256 seed) external {
        uint256 amount = seed % 10 ether;
        vm.prank(actors[seed % actors.length]);
        token.transfer(address(job), amount);
        donations += amount;
        spent[actors[seed % actors.length]] += amount;
    }

    function workers(uint256 id) external view returns (address[] memory) {
        return _workers[id];
    }

    function joinOrder(uint256 id) external view returns (address[] memory) {
        return _joinOrder[id];
    }

    function startedAt(uint256 id) external view returns (uint256[] memory) {
        return _startedAt[id];
    }

    /// @dev Invalid transitions are exercised between successful operations, not filtered out.
    /// Reverts must match the specific guard; the ledger deliberately remains unchanged.
    function rejectInvalidAction(uint256 seed) external {
        address wallet = actors[seed % actors.length];
        uint256 action = (seed / actors.length) % 8;
        if (action == 0) {
            address configuredOwner = job.owner();
            vm.expectRevert(JobZero.TokenAlreadySet.selector);
            vm.prank(configuredOwner);
            job.setToken(address(token));
        } else if (action == 1) {
            vm.expectRevert(JobZero.Unauthorized.selector);
            vm.prank(wallet);
            job.setToken(address(token));
        } else if (runCount == 0 || closed[runCount]) {
            vm.expectRevert(JobZero.NoOpenRun.selector);
            vm.prank(wallet);
            if (action % 3 == 0) job.timeout();
            else if (action % 3 == 1) job.handoff(wallet);
            else job.goOnline();
        } else if (action == 2) {
            vm.expectRevert(JobZero.RunAlreadyOpen.selector);
            vm.prank(wallet);
            job.open();
        } else if (action == 3) {
            address current = _workers[runCount][_workers[runCount].length - 1];
            if (wallet == current) wallet = actors[(seed % actors.length + 1) % actors.length];
            vm.expectRevert(JobZero.NotWorker.selector);
            vm.prank(wallet);
            job.handoff(current);
        } else if (action == 4) {
            vm.expectRevert(JobZero.NothingToClaim.selector);
            vm.prank(wallet);
            job.claim(runCount);
        } else if (action == 5 && _canAct()) {
            vm.expectRevert(JobZero.DeadlineNotReached.selector);
            vm.prank(wallet);
            job.timeout();
        } else {
            address current = _workers[runCount][_workers[runCount].length - 1];
            address first = _workers[runCount][0];
            bytes4 reason = !_canAct()
                ? JobZero.DeadlinePassed.selector
                : first == current ? JobZero.InvalidRecipient.selector : JobZero.AlreadyHeld.selector;
            vm.expectRevert(reason);
            vm.prank(current);
            job.handoff(first);
        }
    }

    function _canAct() private view returns (bool) {
        return runCount != 0 && !closed[runCount] && vm.getBlockTimestamp() < _expectedDeadline();
    }

    function _expectedDeadline() private view returns (uint256) {
        uint256[] storage times = _startedAt[runCount];
        return times[times.length - 1] + 1 days;
    }

    function _recordWorker(address wallet) private {
        _workers[runCount].push(wallet);
        _startedAt[runCount].push(vm.getBlockTimestamp());
        held[runCount][wallet] = true;
        attempts[wallet]++;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract JobZeroInvariantTest is Test {
    LaunchToken private token;
    JobZero private job;
    JobZeroHandler private handler;
    address private constant BURN = 0x000000000000000000000000000000000000dEaD;

    function setUp() public {
        vm.warp(1_000_000);
        token = new LaunchToken();
        job = new JobZero(address(this));
        job.setToken(address(token));
        handler = new JobZeroHandler(job, token);
        for (uint256 i; i < 8; i++) {
            token.transfer(handler.actors(i), 5_000_000 ether);
        }
        // Begin with both a historical entitlement and a live run. Even short sequences
        // exercise cross-run isolation; the existing unit tests cover the empty state.
        handler.open(0);
        handler.join(1);
        handler.handoff(1);
        handler.expireAndTimeout(0);
        handler.open(2);
        handler.join(3);
        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = handler.open.selector;
        selectors[1] = handler.handoff.selector;
        selectors[2] = handler.join.selector;
        selectors[3] = handler.leave.selector;
        selectors[4] = handler.advanceTime.selector;
        selectors[5] = handler.expireAndTimeout.selector;
        selectors[6] = handler.claim.selector;
        selectors[7] = handler.donate.selector;
        selectors[8] = handler.rejectInvalidAction.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_ConservationAndExactLiabilities() public view {
        assertEq(token.totalSupply(), 1e27);
        assertEq(job.totalBurned(), handler.burns());
        assertEq(token.balanceOf(BURN), handler.burns());
        uint256 liabilities = handler.payments() - handler.burns() - handler.payouts();
        assertEq(job.totalLiability(), liabilities);
        assertEq(token.balanceOf(address(job)), liabilities + handler.donations());
        uint256 userBalances;
        for (uint256 i; i < 8; i++) {
            address wallet = handler.actors(i);
            uint256 balance = token.balanceOf(wallet);
            assertEq(balance, 5_000_000 ether + handler.earned(wallet) - handler.spent(wallet));
            userBalances += balance;
        }
        assertEq(userBalances, 40_000_000 ether - handler.payments() - handler.donations() + handler.payouts());
    }

    /// @dev Every randomized sequence can finish with all legitimate obligations paid, without an administrator.
    function afterInvariant() public {
        handler.expireAndTimeout(0);
        for (uint256 id = 1; id <= handler.runCount(); id++) {
            address[] memory workers = handler.workers(id);
            for (uint256 i; i + 1 < workers.length; i++) {
                handler.claim(id - 1, i);
            }
        }
        assertFalse(job.isOpen());
        assertEq(job.totalLiability(), 0);
        assertEq(token.balanceOf(address(job)), handler.donations());
        assertEq(handler.payments(), handler.burns() + handler.payouts());
        invariant_ConservationAndExactLiabilities();
        invariant_RunRecordsClaimEligibilityAndWalletStatsMatchHistory();
        invariant_AttemptHistoryDeadlinesAndRecordsMatchTheClock();
    }

    function invariant_RunRecordsClaimEligibilityAndWalletStatsMatchHistory() public view {
        uint256 outstanding;
        assertEq(job.currentRun(), handler.runCount());
        assertEq(job.isOpen(), !handler.closed(handler.runCount()));
        if (!job.isOpen()) {
            assertEq(job.worker(), address(0));
            assertEq(job.deadline(), 0);
            assertEq(job.handoffFee(), 1_000 ether);
        }
        for (uint256 id = 1; id <= handler.runCount(); ++id) {
            address[] memory workers = handler.workers(id);
            JobZero.Run memory run = job.runs(id);
            assertEq(run.attempts, workers.length);
            assertEq(run.bounty, handler.bounty(id));
            assertEq(run.closed, handler.closed(id));
            uint256 claims;
            for (uint256 i; i < workers.length; i++) {
                address wallet = workers[i];
                assertTrue(job.hasHeld(id, wallet));
                assertEq(job.claimed(id, wallet), handler.paid(id, wallet));
                uint256 expected;
                if (run.closed && i != workers.length - 1 && !handler.paid(id, wallet)) {
                    expected = handler.bounty(id) / (workers.length - 1);
                }
                assertEq(job.claimable(id, wallet), expected);
                outstanding += expected;
                if (handler.paid(id, wallet)) claims++;
            }
            assertEq(run.claimedCount, claims);
            uint256 expectedShare = run.closed && workers.length > 1 ? handler.bounty(id) / (workers.length - 1) : 0;
            assertEq(run.share, expectedShare);
            assertEq(run.worker, workers[workers.length - 1]);
            if (run.closed) {
                assertEq(run.failedWorker, workers[workers.length - 1]);
                assertEq(run.fee, handler.closingFee(id));
            } else {
                outstanding += handler.bounty(id);
                assertEq(run.failedWorker, address(0));
                assertEq(id, handler.runCount());
                assertTrue(job.isOpen());
                assertEq(job.worker(), workers[workers.length - 1]);
                assertEq(job.handoffFee(), handler.currentFee());
            }
        }
        assertEq(job.totalLiability(), outstanding);
        for (uint256 i; i < 8; i++) {
            address wallet = handler.actors(i);
            (uint256 attempts, uint256 handoffs, uint256 earned, uint256 failed) = job.workerStats(wallet);
            assertEq(attempts, handler.attempts(wallet));
            assertEq(handoffs, handler.handoffs(wallet));
            assertEq(earned, handler.earned(wallet));
            assertEq(failed, handler.failures(wallet));
        }
    }

    function invariant_QueueContainsOnlyEligibleOnlineWorkersInReverseJoinOrder() public view {
        for (uint256 id = 1; id <= handler.runCount(); ++id) {
            JobZero.QueueEntry[] memory entries = job.getQueue(id, 0, 100);
            if (handler.closed(id)) {
                assertEq(entries.length, 0);
                assertEq(job.queueLength(id), 0);
            } else {
                address[] memory order = handler.joinOrder(id);
                uint256 count;
                for (uint256 i = order.length; i > 0; i--) {
                    address wallet = order[i - 1];
                    if (handler.online(id, wallet)) {
                        assertLt(count, entries.length);
                        assertEq(entries[count].worker, wallet);
                        assertEq(entries[count].onlineAt, handler.joinedAt(id, wallet));
                        assertFalse(job.hasHeld(id, wallet));
                        count++;
                    }
                }
                assertEq(entries.length, count);
                assertEq(job.queueLength(id), count);
            }
            for (uint256 i; i < 8; i++) {
                address wallet = handler.actors(i);
                assertEq(job.hasJoinedQueue(id, wallet), handler.joined(id, wallet));
                assertEq(job.isOnline(id, wallet), !handler.closed(id) && handler.online(id, wallet));
            }
        }
    }

    /// @dev Expected times come from handler calls, not JobZero's own deadline or attempt views.
    function invariant_AttemptHistoryDeadlinesAndRecordsMatchTheClock() public view {
        uint256 largestBounty;
        uint256 mostHandoffs;
        uint256 longestId;
        uint256 longestDuration;
        for (uint256 id = 1; id <= handler.runCount(); ++id) {
            address[] memory workers = handler.workers(id);
            uint256[] memory times = handler.startedAt(id);
            JobZero.Run memory run = job.runs(id);
            uint256 expectedDeadline = times[times.length - 1] + 1 days;
            assertEq(run.openedAt, times[0]);
            assertEq(run.deadline, expectedDeadline);
            assertEq(run.closedAt, handler.closedAt(id));
            if (!run.closed) assertEq(job.deadline(), expectedDeadline);
            JobZero.Attempt[] memory page = job.getAttempts(id, 0, 100);
            assertEq(page.length, workers.length);
            for (uint256 i; i < workers.length; ++i) {
                JobZero.Attempt memory attempt = page[workers.length - 1 - i];
                assertEq(attempt.worker, workers[i]);
                assertEq(attempt.startedAt, times[i]);
                if (i + 1 < workers.length) {
                    assertEq(uint256(attempt.status), uint256(JobZero.Status.HandedOff));
                    assertEq(attempt.endedAt, times[i + 1]);
                    assertLt(attempt.endedAt, attempt.startedAt + 1 days);
                } else {
                    assertEq(
                        uint256(attempt.status), uint256(run.closed ? JobZero.Status.Failed : JobZero.Status.Holding)
                    );
                    assertEq(attempt.endedAt, run.closed ? expectedDeadline : 0);
                }
            }
            if (handler.bounty(id) > largestBounty) largestBounty = handler.bounty(id);
            if (workers.length - 1 > mostHandoffs) mostHandoffs = workers.length - 1;
            uint256 end =
                run.closed || vm.getBlockTimestamp() > expectedDeadline ? expectedDeadline : vm.getBlockTimestamp();
            uint256 duration = end - times[0];
            if (longestId == 0 || duration > longestDuration) {
                longestId = id;
                longestDuration = duration;
            }
        }
        assertEq(job.biggestBounty(), largestBounty);
        assertEq(job.mostHandoffs(), mostHandoffs);
        (uint256 recordedId, uint256 recordedDuration) = job.longestRun();
        assertEq(recordedId, longestId);
        assertEq(recordedDuration, longestDuration);
    }
}

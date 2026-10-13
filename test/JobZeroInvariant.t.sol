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
    mapping(address => uint256) public failures;

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
        _joinOrder[runCount].push(wallet);
        payments += 10 ether;
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
        uint256 expiry = job.deadline();
        if (vm.getBlockTimestamp() < expiry) vm.warp(expiry);
        vm.warp(vm.getBlockTimestamp() + (delaySeed % 3 days));
        job.timeout();
        closed[runCount] = true;
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
    }

    function workers(uint256 id) external view returns (address[] memory) {
        return _workers[id];
    }

    function joinOrder(uint256 id) external view returns (address[] memory) {
        return _joinOrder[id];
    }

    function _canAct() private view returns (bool) {
        return runCount != 0 && !closed[runCount] && vm.getBlockTimestamp() < job.deadline();
    }

    function _recordWorker(address wallet) private {
        _workers[runCount].push(wallet);
        held[runCount][wallet] = true;
        attempts[wallet]++;
    }
}

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
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.open.selector;
        selectors[1] = handler.handoff.selector;
        selectors[2] = handler.join.selector;
        selectors[3] = handler.leave.selector;
        selectors[4] = handler.advanceTime.selector;
        selectors[5] = handler.expireAndTimeout.selector;
        selectors[6] = handler.claim.selector;
        selectors[7] = handler.donate.selector;
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
            userBalances += token.balanceOf(handler.actors(i));
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
    }

    function invariant_RunRecordsClaimEligibilityAndWalletStatsMatchHistory() public view {
        assertEq(job.currentRun(), handler.runCount());
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
                if (handler.paid(id, wallet)) claims++;
            }
            assertEq(run.claimedCount, claims);
            if (run.closed) {
                assertEq(run.failedWorker, workers[workers.length - 1]);
            } else {
                assertEq(id, handler.runCount());
                assertTrue(job.isOpen());
                assertEq(job.worker(), workers[workers.length - 1]);
                assertEq(job.handoffFee(), handler.currentFee());
            }
        }
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
}

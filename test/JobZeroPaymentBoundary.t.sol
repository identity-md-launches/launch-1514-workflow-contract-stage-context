// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {JobZeroFixture} from "./helpers/JobZeroFixture.sol";
import {JobZero} from "src/JobZero.sol";

contract JobZeroPaymentBoundaryTest is JobZeroFixture {
    function test_OpenWithBalanceOneUnitShort() public {
        _checkFailedPayment(0, 1, false);
    }

    function test_OpenWithAllowanceOneUnitShort() public {
        _checkFailedPayment(0, 1, true);
    }

    function test_HandoffWithBalanceOneUnitShort() public {
        _checkFailedPayment(1, 1, false);
    }

    function test_HandoffWithAllowanceOneUnitShort() public {
        _checkFailedPayment(1, 1, true);
    }

    function test_QueueWithBalanceOneUnitShort() public {
        _checkFailedPayment(2, 1, false);
    }

    function test_QueueWithAllowanceOneUnitShort() public {
        _checkFailedPayment(2, 1, true);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_UnderfundedActionsPreserveAllStateAndCanRetry(
        uint8 actionSeed,
        uint256 shortfallSeed,
        bool insufficientAllowance
    ) public {
        _checkFailedPayment(actionSeed % 3, shortfallSeed, insufficientAllowance);
    }

    function _checkFailedPayment(uint256 action, uint256 shortfallSeed, bool insufficientAllowance) private {
        address payer = alice;
        uint256 fee = OPEN;
        if (action != 0) {
            _open(alice);
            _online(bob);
            if (action == 1) {
                fee = FIRST_FEE;
            } else {
                payer = carol;
                fee = ONLINE;
            }
        }
        uint256 shortfall = bound(shortfallSeed, 1, fee);
        uint256 available = fee - shortfall;
        if (!insufficientAllowance) {
            uint256 toRemove = token.balanceOf(payer) - available;
            vm.prank(payer);
            token.transfer(dave, toRemove);
        }
        vm.prank(payer);
        token.approve(address(job), insufficientAllowance ? available : fee);
        bytes32 beforeState = _stateDigest();
        bytes memory expectedError = insufficientAllowance
            ? abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(job), available, fee)
            : abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, payer, available, fee);
        vm.expectRevert(expectedError);
        vm.prank(payer);
        _execute(action);
        assertEq(_stateDigest(), beforeState, "failed collection changed records, queue, balances or allowance");

        // Retry with precisely enough balance/allowance, not an unlimited approval.
        if (!insufficientAllowance) _fund(payer, shortfall);
        vm.prank(payer);
        token.approve(address(job), fee);
        vm.prank(payer);
        _execute(action);
        assertEq(token.allowance(payer, address(job)), 0);
        if (!insufficientAllowance) assertEq(token.balanceOf(payer), 0);
        if (action == 0) {
            assertEq(job.currentRun(), 1);
            assertEq(job.worker(), alice);
            assertEq(job.runs(1).bounty, OPEN);
        } else if (action == 1) {
            assertEq(job.worker(), bob);
            assertEq(job.runs(1).attempts, 2);
            assertFalse(job.isOnline(1, bob));
            assertEq(job.queueLength(1), 0);
        } else {
            assertEq(job.queueLength(1), 2);
            assertEq(job.getQueue(1, 0, 1)[0].worker, carol);
        }
        assertEq(token.balanceOf(address(job)), job.totalLiability());
        assertEq(token.balanceOf(BURN), job.totalBurned());
        assertEq(token.totalSupply(), 1e27);
    }

    function _execute(uint256 action) private {
        if (action == 0) job.open();
        else if (action == 1) job.handoff(bob);
        else job.goOnline();
    }

    function _stateDigest() private view returns (bytes32 digest) {
        digest = keccak256(abi.encode(job.runs(1), job.getAttempts(1, 0, 100), job.getQueue(1, 0, 100)));
        digest = keccak256(
            abi.encode(
                digest,
                job.currentRun(),
                job.isOpen(),
                job.totalLiability(),
                job.totalBurned(),
                job.biggestBounty(),
                job.mostHandoffs(),
                job.queueLength(1),
                token.balanceOf(address(job)),
                token.balanceOf(BURN)
            )
        );
        address[4] memory wallets = [alice, bob, carol, dave];
        for (uint256 i; i < wallets.length; ++i) {
            address wallet = wallets[i];
            JobZero.WorkerStats memory stats;
            (stats.attempts, stats.handoffs, stats.totalEarned, stats.timesFailed) = job.workerStats(wallet);
            digest = keccak256(
                abi.encode(
                    digest,
                    stats,
                    job.hasHeld(1, wallet),
                    job.hasJoinedQueue(1, wallet),
                    job.isOnline(1, wallet),
                    token.balanceOf(wallet),
                    token.allowance(wallet, address(job))
                )
            );
        }
    }
}

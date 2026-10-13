// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../../src/LaunchToken.sol";
import {JobZero} from "../../src/JobZero.sol";

abstract contract JobZeroFixture is Test {
    LaunchToken internal token;
    JobZero internal job;
    address internal owner = makeAddr("launch owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    uint256 internal constant OPEN = 10_000 ether;
    uint256 internal constant FIRST_FEE = 1_000 ether;
    uint256 internal constant ONLINE = 10 ether;
    address internal constant BURN = 0x000000000000000000000000000000000000dEaD;

    function setUp() public virtual {
        vm.warp(1_000_000);
        token = new LaunchToken();
        job = new JobZero(owner);
        vm.prank(owner);
        job.setToken(address(token));
        _fund(alice, 1_000_000 ether);
        _fund(bob, 1_000_000 ether);
        _fund(carol, 1_000_000 ether);
        _fund(dave, 1_000_000 ether);
    }

    function _fund(address wallet, uint256 amount) internal {
        token.transfer(wallet, amount);
    }

    function _open(address wallet) internal {
        vm.startPrank(wallet);
        token.approve(address(job), OPEN);
        job.open();
        vm.stopPrank();
    }

    function _handoff(address to) internal {
        address from = job.worker();
        uint256 fee = job.handoffFee();
        vm.startPrank(from);
        token.approve(address(job), fee);
        job.handoff(to);
        vm.stopPrank();
    }

    function _online(address wallet) internal {
        vm.startPrank(wallet);
        token.approve(address(job), ONLINE);
        job.goOnline();
        vm.stopPrank();
    }

    function _close() internal {
        vm.warp(job.deadline());
        job.timeout();
    }

    function _claim(uint256 id, address wallet) internal {
        vm.prank(wallet);
        job.claim(id);
    }
}

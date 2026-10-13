// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "src/LaunchToken.sol";

/// @dev All supply is distributed to four actors. No balance/allowance cheatcodes,
/// minting, or reads from the token are used to update the reference ledger.
contract LaunchTokenHandler is Test {
    LaunchToken public immutable token;
    address public constant BURN = 0x000000000000000000000000000000000000dEaD;
    address[4] public actors;
    mapping(address => uint256) public balances;
    mapping(address => mapping(address => uint256)) public allowances;
    uint256 public burned;

    constructor(LaunchToken token_) {
        token = token_;
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("token invariant actor ", vm.toString(i)));
            balances[actors[i]] = 1e27 / actors.length;
        }
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amountSeed) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 amount = bound(amountSeed, 0, balances[from]);
        vm.prank(from);
        assertTrue(token.transfer(to, amount));
        _move(from, to, amount);
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) public {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        vm.prank(owner);
        assertTrue(token.approve(spender, amount));
        allowances[owner][spender] = amount;
    }

    function transferFrom(uint256 ownerSeed, uint256 spenderSeed, uint256 toSeed, uint256 amountSeed) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 limit = balances[owner];
        if (allowances[owner][spender] < limit) limit = allowances[owner][spender];
        uint256 amount = bound(amountSeed, 0, limit);
        vm.prank(spender);
        assertTrue(token.transferFrom(owner, to, amount));
        if (allowances[owner][spender] != type(uint256).max) allowances[owner][spender] -= amount;
        _move(owner, to, amount);
    }

    function burn(uint256 actorSeed, uint256 amountSeed) external {
        address from = actors[actorSeed % actors.length];
        // Preserve circulating funds for long sequences; full-balance burns are pinned in unit tests.
        uint256 amount = bound(amountSeed, 0, balances[from] / 20);
        vm.prank(from);
        assertTrue(token.transfer(BURN, amount));
        balances[from] -= amount;
        burned += amount;
    }

    function rejectInvalidTransfer(uint256 fromSeed, uint256 toSeed, bool zeroRecipient) external {
        address from = actors[fromSeed % actors.length];
        address to = actors[toSeed % actors.length];
        uint256 amount = balances[from] + 1;
        if (zeroRecipient) {
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
            vm.prank(from);
            token.transfer(address(0), 0);
        } else {
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, from, balances[from], amount)
            );
            vm.prank(from);
            token.transfer(to, amount);
        }
    }

    function rejectInvalidTransferFrom(uint256 ownerSeed, uint256 spenderSeed, bool insufficientAllowance) external {
        address owner = actors[ownerSeed % actors.length];
        address spender = actors[spenderSeed % actors.length];
        address to = actors[(ownerSeed % actors.length + 1) % actors.length];
        uint256 amount = balances[owner] + 1;
        if (insufficientAllowance) {
            approve(ownerSeed, spenderSeed, 0);
            vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
            vm.prank(spender);
            token.transferFrom(owner, to, 1);
        } else {
            // The failed transfer must restore the allowance spent before the balance check.
            approve(ownerSeed, spenderSeed, amount);
            vm.expectRevert(
                abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, balances[owner], amount)
            );
            vm.prank(spender);
            token.transferFrom(owner, to, amount);
        }
    }

    function _move(address from, address to, uint256 amount) private {
        balances[from] -= amount;
        balances[to] += amount;
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract LaunchTokenInvariantTest is Test {
    LaunchToken private token;
    LaunchTokenHandler private handler;

    function setUp() public {
        token = new LaunchToken();
        handler = new LaunchTokenHandler(token);
        for (uint256 i; i < 4; ++i) {
            token.transfer(handler.actors(i), 1e27 / 4);
        }
        // Seed finite and infinite allowances so delegated transfers reach both branches
        // even before random approvals occur. Revocations can overwrite these later.
        handler.approve(0, 1, type(uint256).max);
        handler.approve(1, 2, 50_000 ether);
        handler.approve(2, 3, 1);
        handler.transferFrom(1, 2, 3, 1);
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.transferFrom.selector;
        selectors[3] = handler.burn.selector;
        selectors[4] = handler.rejectInvalidTransfer.selector;
        selectors[5] = handler.rejectInvalidTransferFrom.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_FixedSupplyBalancesAndAllowancesFollowOnlyAuthorizedTransfers() public view {
        uint256 total = token.balanceOf(handler.BURN());
        assertEq(total, handler.burned());
        for (uint256 i; i < 4; ++i) {
            address owner = handler.actors(i);
            assertEq(token.balanceOf(owner), handler.balances(owner));
            total += token.balanceOf(owner);
            for (uint256 j; j < 4; ++j) {
                address spender = handler.actors(j);
                assertEq(token.allowance(owner, spender), handler.allowances(owner, spender));
            }
        }
        assertEq(total, 1e27);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(0)), 0);
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(handler)), 0);
    }
}

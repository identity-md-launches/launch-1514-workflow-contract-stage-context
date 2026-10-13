// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken private token;
    address private factory = makeAddr("factory");
    address private recipient = makeAddr("recipient");
    address private spender = makeAddr("spender");

    function setUp() public {
        vm.prank(factory);
        token = new LaunchToken();
    }

    function test_MetadataAndFixedSupplyGoOnlyToFactory() public view {
        assertEq(token.name(), "Teyo");
        assertEq(token.symbol(), "TEYO");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(factory), 1e27);
        assertEq(token.balanceOf(address(this)), 0);
    }

    function testFuzz_TransferIsExact(uint256 amount) public {
        amount = bound(amount, 0, 1e27);
        vm.prank(factory);
        assertTrue(token.transfer(recipient, amount));
        assertEq(token.balanceOf(recipient), amount);
        assertEq(token.balanceOf(factory), 1e27 - amount);
        assertEq(token.totalSupply(), 1e27);
    }

    function test_AllowanceIsRequiredAndSpentExactly() public {
        vm.prank(factory);
        token.approve(spender, 55 ether);
        vm.prank(spender);
        token.transferFrom(factory, recipient, 55 ether);
        assertEq(token.allowance(factory, spender), 0);
        assertEq(token.balanceOf(recipient), 55 ether);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, spender, 0, 1));
        vm.prank(spender);
        token.transferFrom(factory, recipient, 1);
    }

    function test_InvalidTransfersRevert() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(factory);
        token.transfer(address(0), 1);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, recipient, 0, 1));
        vm.prank(recipient);
        token.transfer(factory, 1);
    }

    function test_NoAdministrationMintingOrETH() public {
        bytes[8] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", recipient, 1 ether),
            abi.encodeWithSignature("mint(uint256)", 1 ether),
            abi.encodeWithSignature("mint()"),
            abi.encodeWithSignature("transferOwnership(address)", recipient),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("initialize(address)", recipient),
            abi.encodeWithSignature("upgradeTo(address)", recipient),
            abi.encodeWithSignature("setMinter(address)", recipient)
        ];
        for (uint256 i; i < calls.length; i++) {
            vm.prank(factory);
            (bool success,) = address(token).call(calls[i]);
            assertFalse(success);
        }
        vm.deal(factory, 1 ether);
        vm.prank(factory);
        (bool accepted,) = address(token).call{value: 1 ether}("");
        assertFalse(accepted);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(factory), 1e27);
    }
}

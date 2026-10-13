// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {JobZero} from "../src/JobZero.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract DeploymentTest is Test {
    function test_FactoryDeploymentNeedsNoOtherContractsAndPreservesSupply() public {
        address factory = makeAddr("launch factory");
        address owner = makeAddr("explicit launch owner");
        vm.startPrank(factory);
        LaunchToken token = new LaunchToken{salt: keccak256("token")}();
        JobZero job = new JobZero{salt: keccak256("job")}(owner);
        vm.stopPrank();
        assertEq(job.owner(), owner);
        assertEq(address(job.token()), address(0));
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(factory), 1e27);
        assertEq(token.balanceOf(address(job)), 0);
        _checkRuntime(address(token));
        _checkRuntime(address(job));
    }

    function _checkRuntime(address deployed) private view {
        bytes memory code = deployed.code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
            else assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}

// SPDX-License-Identifier: AGPL-3.0-or-later
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Test} from "forge-std/Test.sol";

import {IouToken} from "../../../src/common/IouToken.sol";

contract IouTokenTest is Test {
    address public iouToken;
    address public owner = makeAddr("OWNER");
    uint8 internal constant RAY_DECIMALS = 27;

    function setUp() public {
        iouToken = address(new IouToken(owner));
    }

    function test_mint_withOwner(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != iouToken);

        uint256 balanceBefore = IouToken(iouToken).balanceOf(to);
        vm.prank(owner);
        IouToken(iouToken).mint(to, amount);
        uint256 balanceAfter = IouToken(iouToken).balanceOf(to);

        assertEq(balanceAfter, balanceBefore + amount, "balance mismatch");
    }

    function test_burn_withOwner(address from, uint256 initialAmount, uint256 burnAmount) public {
        vm.assume(from != address(0));
        burnAmount = bound(burnAmount, 0, initialAmount);
        vm.prank(owner);
        IouToken(iouToken).mint(from, initialAmount);

        uint256 balanceBefore = IouToken(iouToken).balanceOf(from);
        vm.prank(owner);
        IouToken(iouToken).burn(from, burnAmount);
        uint256 balanceAfter = IouToken(iouToken).balanceOf(from);

        assertEq(balanceAfter, balanceBefore - burnAmount, "balance mismatch");
    }

    function test_decimals() public view {
        assertEq(IouToken(iouToken).decimals(), RAY_DECIMALS, "decimals mismatch");
    }

    function test_name() public view {
        assertEq(IouToken(iouToken).name(), "IouToken", "name mismatch");
    }

    function test_symbol() public view {
        assertEq(IouToken(iouToken).symbol(), "IOU", "symbol mismatch");
    }

    function test_mint_reverts_if_not_owner(address nonOwner, address to, uint256 amount) public {
        vm.assume(nonOwner != owner && nonOwner != address(0));
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        IouToken(iouToken).mint(to, amount);
    }

    function test_burn_reverts_if_not_owner(address nonOwner, address from, uint256 burnAmount) public {
        vm.assume(nonOwner != owner && nonOwner != address(0) && nonOwner != from);
        vm.prank(nonOwner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        IouToken(iouToken).burn(from, burnAmount);
    }
}

// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.0;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Test} from "forge-std/Test.sol";

import {IouToken} from "src/core/ious/IouToken.sol";
import {Constants} from "src/types/Constants.sol";
import {Errors} from "src/types/Errors.sol";

contract IouTokenTest is Test {
    string internal constant TEST_IOU_NAME = "Test IOU: Aave USD Stable Vault";
    string internal constant TEST_IOU_SYMBOL = "test-IOU-USD";

    address public iouToken;
    address public owner = makeAddr("OWNER");

    function setUp() public {
        iouToken = address(new IouToken(owner, TEST_IOU_NAME, TEST_IOU_SYMBOL));
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
        assertEq(IouToken(iouToken).decimals(), Constants.RAY_DECIMALS, "decimals mismatch");
    }

    /// @dev `name()` returns the value passed to the constructor, allowing each IouToken deployment
    /// (USD, EUR, etc.) to set its own ERC20 metadata for off-chain display.
    function test_name_returnsValuePassedToConstructor() public view {
        assertEq(IouToken(iouToken).name(), TEST_IOU_NAME, "name mismatch");
    }

    /// @dev `symbol()` returns the value passed to the constructor.
    function test_symbol_returnsValuePassedToConstructor() public view {
        assertEq(IouToken(iouToken).symbol(), TEST_IOU_SYMBOL, "symbol mismatch");
    }

    function test_constructor_setsCustomNameAndSymbol(string memory customName, string memory customSymbol) public {
        vm.assume(bytes(customName).length > 0);
        vm.assume(bytes(customSymbol).length > 0);

        IouToken newIouToken = new IouToken(owner, customName, customSymbol);

        assertEq(newIouToken.name(), customName);
        assertEq(newIouToken.symbol(), customSymbol);
        assertEq(newIouToken.decimals(), Constants.RAY_DECIMALS);
    }

    function test_constructor_reverts_ifNameIsEmpty() public {
        vm.expectRevert(Errors.InvalidParameter.selector);
        new IouToken(owner, "", TEST_IOU_SYMBOL);
    }

    function test_constructor_reverts_ifSymbolIsEmpty() public {
        vm.expectRevert(Errors.InvalidParameter.selector);
        new IouToken(owner, TEST_IOU_NAME, "");
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

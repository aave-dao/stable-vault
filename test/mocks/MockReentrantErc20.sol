// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {MockErc20} from "test/mocks/MockErc20.sol";

/// @notice A reentrant ERC20 that calls back to a target contract during transfer/transferFrom.
/// @dev Used to test reentrancy protection in StableVault.
contract MockReentrantErc20 is MockErc20 {
    address public reentrantTarget;
    bytes public reentrantCalldata;
    bool public reentrancyOnTransferFrom;

    constructor(string memory name, string memory symbol, uint8 decimals) MockErc20(name, symbol, decimals) {}

    function setReentrantCall(address target, bytes memory data) external {
        reentrantTarget = target;
        reentrantCalldata = data;
    }

    function setReentrancyOnTransferFrom(bool enabled) external {
        reentrancyOnTransferFrom = enabled;
    }

    function clearReentrantCall() external {
        reentrantTarget = address(0);
        reentrantCalldata = "";
    }

    function transfer(address to, uint256 amount) public virtual override(ERC20, IERC20) returns (bool) {
        if (reentrantTarget != address(0) && !reentrancyOnTransferFrom) {
            _executeReentrantCall();
        }
        return super.transfer(to, amount);
    }

    function transferFrom(address from, address to, uint256 amount)
        public
        virtual
        override(ERC20, IERC20)
        returns (bool)
    {
        if (reentrantTarget != address(0) && reentrancyOnTransferFrom) {
            _executeReentrantCall();
        }
        return super.transferFrom(from, to, amount);
    }

    function _executeReentrantCall() internal {
        (bool success, bytes memory returnData) = reentrantTarget.call(reentrantCalldata);
        if (!success) {
            // Bubble up the error
            assembly {
                revert(add(returnData, 32), mload(returnData))
            }
        }
    }
}

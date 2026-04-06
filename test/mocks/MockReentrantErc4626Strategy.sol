// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

/// @notice An ERC4626 strategy that calls back to a target during withdraw/deposit.
/// @dev Used to test reentrancy protection in Allocator.
contract MockReentrantErc4626Strategy is ERC4626 {
    address public reentrantTarget;
    bytes public reentrantCalldata;
    bool public reentrancyOnWithdraw;
    bool public reentrancyOnDeposit;
    bool public reentrancyOnRedeem;

    constructor(IERC20 asset) ERC4626(asset) ERC20("Mock Reentrant Erc4626", "REENT4626") {}

    function setReentrantCall(address target, bytes memory data) external {
        reentrantTarget = target;
        reentrantCalldata = data;
    }

    function setReentrancyOnWithdraw(bool enabled) external {
        reentrancyOnWithdraw = enabled;
    }

    function setReentrancyOnDeposit(bool enabled) external {
        reentrancyOnDeposit = enabled;
    }

    function setReentrancyOnRedeem(bool enabled) external {
        reentrancyOnRedeem = enabled;
    }

    function clearReentrantCall() external {
        reentrantTarget = address(0);
        reentrantCalldata = "";
    }

    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        if (reentrantTarget != address(0) && reentrancyOnWithdraw) {
            _executeReentrantCall();
        }
        return super.withdraw(assets, receiver, owner);
    }

    function deposit(uint256 assets, address receiver) public override returns (uint256) {
        if (reentrantTarget != address(0) && reentrancyOnDeposit) {
            _executeReentrantCall();
        }
        return super.deposit(assets, receiver);
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        if (reentrantTarget != address(0) && reentrancyOnRedeem) {
            _executeReentrantCall();
        }
        return super.redeem(shares, receiver, owner);
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

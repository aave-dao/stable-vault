// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IAssetRegistry} from "../../src/interfaces/IAssetRegistry.sol";

/// @title MockAssetRegistry.
/// @notice Mock implementation of the AssetRegistry contract for testing purposes.
/// @dev By default it allows all assets to simplify testing. It must be explicitly mocked to disallow assets.
contract MockAssetRegistry is IAssetRegistry {
    mapping(address asset => bool isUserDepositAllowed) _isNotAllowedUserDeposit;
    mapping(address asset => bool isUserWithdrawalAllowed) _isNotAllowedToWithdraw;
    mapping(address asset => bool isDepositToAllocatorAllowed) _isNotAllowedToDepositIntoAllocator;
    mapping(address asset => bool isWithdrawalFromAllocatorAllowed) _isNotAllowedToWithdrawFromAllocator;
    mapping(address asset => bool isAllowedToSwapInputTokenInAllocator) _isNotAllowedToSwapInputTokenInAllocator;
    mapping(address asset => bool isAllowedToSwapOutputTokenInAllocator) _isNotAllowedToSwapOutputTokenInAllocator;

    function setAssetConfig(address asset, AssetConfig memory config) external override {}

    function disableDeposits(address asset, bool disableUserDeposits, bool disableAllocatorDeposits)
        external
        override
    {}

    function mockToAllowAssetDepositsIntoBBV(address asset) external {
        _isNotAllowedUserDeposit[asset] = false;
    }

    function mockToAllowAssetWithdrawalsFromBBV(address asset) external {
        _isNotAllowedToWithdraw[asset] = false;
    }

    function mockToDisallowAssetDepositsIntoBBV(address asset) external {
        _isNotAllowedUserDeposit[asset] = true;
    }

    function mockToDisallowAssetWithdrawalsFromBBV(address asset) external {
        _isNotAllowedToWithdraw[asset] = true;
    }

    function mockToDisallowAssetWithdrawals(address asset) external {
        _isNotAllowedToWithdraw[asset] = true;
    }

    function mockToAllowAssetDepositsIntoAllocator(address asset) external {
        _isNotAllowedToDepositIntoAllocator[asset] = false;
    }

    function mockToDisallowAssetDepositsIntoAllocator(address asset) external {
        _isNotAllowedToDepositIntoAllocator[asset] = true;
    }

    function mockToAllowAssetWithdrawalsFromAllocator(address asset) external {
        _isNotAllowedToWithdrawFromAllocator[asset] = false;
    }

    function mockToDisallowAssetWithdrawalsFromAllocator(address asset) external {
        _isNotAllowedToWithdrawFromAllocator[asset] = true;
    }

    function mockToDisallowSwapInputToken(address asset) external {
        _isNotAllowedToSwapInputTokenInAllocator[asset] = true;
    }

    function mockToDisallowSwapOutputToken(address asset) external {
        _isNotAllowedToSwapOutputTokenInAllocator[asset] = true;
    }

    function isUserDepositAllowed(address asset) external view override returns (bool) {
        return !_isNotAllowedUserDeposit[asset];
    }

    function isUserWithdrawalAllowed(address asset) external view override returns (bool) {
        return !_isNotAllowedToWithdraw[asset];
    }

    function isDepositToAllocatorAllowed(address asset) external view override returns (bool) {
        return !_isNotAllowedToDepositIntoAllocator[asset];
    }

    function isWithdrawalFromAllocatorAllowed(address asset) external view override returns (bool) {
        return !_isNotAllowedToWithdrawFromAllocator[asset];
    }

    function isSwapInputAllowed(address asset) external view override returns (bool) {
        return !_isNotAllowedToSwapInputTokenInAllocator[asset];
    }

    function isSwapOutputAllowed(address asset) external view override returns (bool) {
        return !_isNotAllowedToSwapOutputTokenInAllocator[asset];
    }
}

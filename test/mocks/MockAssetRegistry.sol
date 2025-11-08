// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IAssetRegistry} from "../../src/interfaces/IAssetRegistry.sol";

/// @title MockAssetRegistry.
/// @notice Mock implementation of the AssetRegistry contract for testing purposes.
/// @dev By default it allows all assets to simplify testing. It must be explicitly mocked to disallow assets.
contract MockAssetRegistry is IAssetRegistry {
    mapping(address asset => bool isAllowedToDepositIntoBBV) _isNotAllowedToDepositIntoBBV;
    mapping(address asset => bool isAllowedToWithdrawFromBBV) _isNotAllowedToWithdrawFromBBV;
    mapping(address asset => bool isAllowedToDepositIntoAllocator) _isNotAllowedToDepositIntoAllocator;
    mapping(address asset => bool isAllowedToWithdrawFromAllocator) _isNotAllowedToWithdrawFromAllocator;
    mapping(address asset => bool isAllowedToSwapInputTokenInAllocator) _isNotAllowedToSwapInputTokenInAllocator;
    mapping(address asset => bool isAllowedToSwapOutputTokenInAllocator) _isNotAllowedToSwapOutputTokenInAllocator;

    function setAssetConfig(address asset, AssetConfig memory config) external override {}

    function mockToAllowAssetDepositsIntoBBV(address asset) external {
        _isNotAllowedToDepositIntoBBV[asset] = false;
    }

    function mockToAllowAssetWithdrawalsFromBBV(address asset) external {
        _isNotAllowedToWithdrawFromBBV[asset] = false;
    }

    function mockToDisallowAssetDepositsIntoBBV(address asset) external {
        _isNotAllowedToDepositIntoBBV[asset] = true;
    }

    function mockToDisallowAssetWithdrawalsFromBBV(address asset) external {
        _isNotAllowedToWithdrawFromBBV[asset] = true;
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

    function isAllowedToDepositIntoBBV(address asset) external view override returns (bool) {
        return !_isNotAllowedToDepositIntoBBV[asset];
    }

    function isAllowedToWithdrawFromBBV(address asset) external view override returns (bool) {
        return !_isNotAllowedToWithdrawFromBBV[asset];
    }

    function isAllowedToDepositIntoAllocator(address asset) external view override returns (bool) {
        return !_isNotAllowedToDepositIntoAllocator[asset];
    }

    function isAllowedToWithdrawFromAllocator(address asset) external view override returns (bool) {
        return !_isNotAllowedToWithdrawFromAllocator[asset];
    }

    function isAllowedSwapInputToken(address asset) external view override returns (bool) {
        return !_isNotAllowedToSwapInputTokenInAllocator[asset];
    }

    function isAllowedSwapOutputToken(address asset) external view override returns (bool) {
        return !_isNotAllowedToSwapOutputTokenInAllocator[asset];
    }
}

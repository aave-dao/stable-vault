// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";

/// @title MockAssetRegistry.
/// @notice Mock implementation of the AssetRegistry contract for testing purposes.
/// @dev By default it allows all assets to simplify testing. It must be explicitly mocked to disallow assets.
contract MockAssetRegistry is IAssetRegistry {
    using EnumerableSet for EnumerableSet.AddressSet;
    mapping(address asset => bool isUserDepositAllowed) _isNotAllowedUserDeposit;
    mapping(address asset => bool isDepositToAllocatorAllowed) _isNotAllowedToDepositIntoAllocator;
    mapping(address asset => bool isAllowedToSwapInputTokenInAllocator) _isNotAllowedToSwapInputTokenInAllocator;
    mapping(address asset => bool isAllowedToSwapOutputTokenInAllocator) _isNotAllowedToSwapOutputTokenInAllocator;
    EnumerableSet.AddressSet _registeredAssets;
    EnumerableSet.AddressSet _trustedAssets;

    function setAssetConfig(address asset, AssetConfig memory config) external override {}

    function disableUserDeposits(address asset) external override {}

    function disableAllocatorDeposits(address asset) external override {}

    function disableSwapOutput(address asset) external override {}

    function disableSwapInput(address asset) external override {}

    function enableUserDeposits(address asset) external override {}

    function enableAllocatorDeposits(address asset) external override {}

    function enableSwapOutput(address asset) external override {}

    function enableSwapInput(address asset) external override {}

    function trustAsset(address asset) external override {
        _trustedAssets.add(asset);
    }

    function distrustAsset(address asset) external override {
        _trustedAssets.remove(asset);
    }

    function mockToAllowAssetDepositsIntoStableVault(address asset) external {
        _isNotAllowedUserDeposit[asset] = false;
    }

    function mockToDisallowAssetDepositsIntoStableVault(address asset) external {
        _isNotAllowedUserDeposit[asset] = true;
    }

    function mockToAllowAssetDepositsIntoAllocator(address asset) external {
        _isNotAllowedToDepositIntoAllocator[asset] = false;
    }

    function mockToDisallowAssetDepositsIntoAllocator(address asset) external {
        _isNotAllowedToDepositIntoAllocator[asset] = true;
    }

    function mockToDisallowSwapInputToken(address asset) external {
        _isNotAllowedToSwapInputTokenInAllocator[asset] = true;
    }

    function mockToDisallowSwapOutputToken(address asset) external {
        _isNotAllowedToSwapOutputTokenInAllocator[asset] = true;
    }

    function mockRegisteredAsset(address asset) external {
        _registeredAssets.add(asset);
        _trustedAssets.add(asset);
    }

    function isAssetRegistered(address asset) external view override returns (bool) {
        return _registeredAssets.contains(asset);
    }

    function mockDistrustedAsset(address asset) external {
        _trustedAssets.remove(asset);
    }

    function isAssetTrusted(address asset) external view override returns (bool) {
        return _trustedAssets.contains(asset);
    }

    function isUserDepositAllowed(address asset) external view override returns (bool) {
        return !_isNotAllowedUserDeposit[asset];
    }

    function isDepositToAllocatorAllowed(address asset) external view override returns (bool) {
        return !_isNotAllowedToDepositIntoAllocator[asset];
    }

    function isSwapInputAllowed(address asset) external view override returns (bool) {
        return !_isNotAllowedToSwapInputTokenInAllocator[asset];
    }

    function isSwapOutputAllowed(address asset) external view override returns (bool) {
        return !_isNotAllowedToSwapOutputTokenInAllocator[asset];
    }

    function getTrustedAssets() external view override returns (address[] memory) {
        return _trustedAssets.values();
    }
}

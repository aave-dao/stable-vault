// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAllocator} from "src/interfaces/IAllocator.sol";

contract MockAllocator is IAllocator {
    using SafeERC20 for IERC20;

    mapping(address asset => uint256 balance) _mockedAssetBalances;
    address[] _mockedAssets;

    function mockAssetBalance(address asset, uint256 amount) external {
        _mockedAssetBalances[asset] = amount;
        _mockedAssets.push(asset);
    }

    function getAssetBalance(address asset) external view override returns (uint256) {
        return _mockedAssetBalances[asset];
    }

    function getAssetBalanceInStrategy(
        address // strategy
    )
        external
        pure
        override
        returns (uint256)
    {
        revert("Not implemented");
    }

    function getAssetBalances() external view override returns (AllocatorBalance[] memory) {
        AllocatorBalance[] memory balances = new AllocatorBalance[](_mockedAssets.length);
        for (uint256 i = 0; i < _mockedAssets.length; i++) {
            balances[i] = AllocatorBalance({asset: _mockedAssets[i], amount: _mockedAssetBalances[_mockedAssets[i]]});
        }
        return balances;
    }

    address _transferHelper;
    address[] _assetsToPushToTransferHelperInNextCall;
    uint256[] _amountsToPushToTransferHelperInNextCall;

    function mockToPushToTransferHelperInNextCall(address asset, uint256 amount) external {
        _assetsToPushToTransferHelperInNextCall.push(asset);
        _amountsToPushToTransferHelperInNextCall.push(amount);
    }

    function mockTransferHelper(address transferHelper) external {
        _transferHelper = transferHelper;
    }

    function getDefaultStrategy(address asset) external view override returns (address) {}
    function isStrategySupportedForAsset(address asset, address strategy) external view override returns (bool) {}
    function isStrategySupported(address strategy) external view override returns (bool) {}
    function deposit(address asset, uint256 amount) external override {}
    function rebalance(RebalanceParams[] memory params) external override {}

    function withdraw(
        address, // asset
        uint256 // amount
    )
        external
        override
    {
        _pushToTransferHelper();
    }

    function addStrategy(address asset, address strategy) external override {}
    function removeStrategy(address strategy) external override {}
    function setDefaultStrategy(address asset, address strategy) external override {}
    function disableDepositsToStrategy(address strategy) external override {}
    function enableDepositsToStrategy(address strategy) external override {}

    function _pushToTransferHelper() internal {
        for (uint256 i = 0; i < _assetsToPushToTransferHelperInNextCall.length; i++) {
            IERC20(_assetsToPushToTransferHelperInNextCall[i])
                .safeTransfer(_transferHelper, _amountsToPushToTransferHelperInNextCall[i]);
        }
        _assetsToPushToTransferHelperInNextCall = new address[](0);
        _amountsToPushToTransferHelperInNextCall = new uint256[](0);
    }
}

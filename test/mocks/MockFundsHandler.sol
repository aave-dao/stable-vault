// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.4;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IFundsHandler} from "src/interfaces/IFundsHandler.sol";
import {ITransferHelper} from "src/interfaces/ITransferHelper.sol";

contract MockFundsHandler is IFundsHandler {
    using SafeERC20 for IERC20;

    mapping(address asset => uint256 balanceRay) _mockedAssetBalancesRay;
    address[] _mockedAssets;
    uint256 _mockedAggregatedBalance;
    uint256 _mockedAggregatedBalanceAfterWithdrawal;
    bool _hasMockedPostWithdrawalBalance;
    address _mockedTransferHelper;

    constructor(address transferHelper) {
        _mockedTransferHelper = transferHelper;
    }

    function mockAggregatedBalance(uint256 aggregatedBalance) external {
        _mockedAggregatedBalance = aggregatedBalance;
    }

    function mockAggregatedBalanceAfterWithdrawal(uint256 aggregatedBalance) external {
        _mockedAggregatedBalanceAfterWithdrawal = aggregatedBalance;
        _hasMockedPostWithdrawalBalance = true;
    }

    function mockAssetBalance(address asset, uint256 balanceRay) external {
        _mockedAssetBalancesRay[asset] = balanceRay;
    }

    function mockApprove(address spender, address asset, uint256 amount) external {
        IERC20(asset).forceApprove(spender, amount);
    }

    ////

    function addEarningChain(uint256 chainId) external override {}

    function removeEarningChain(uint256 chainId) external override {}

    function getAggregatedBalance() external view override returns (uint256) {
        return _mockedAggregatedBalance;
    }

    function processDeposit(address asset, uint256 amount) external override returns (uint256) {
        ITransferHelper(_mockedTransferHelper).pull(asset, amount);
        return amount;
    }

    function processWithdrawal(address asset, uint256 amount) external override {
        IERC20(asset).forceApprove(msg.sender, amount);
        if (_hasMockedPostWithdrawalBalance) {
            _mockedAggregatedBalance = _mockedAggregatedBalanceAfterWithdrawal;
            _hasMockedPostWithdrawalBalance = false;
        }
    }

    function pushFundsToChain(
        address asset,
        uint256 amount,
        uint256 chainId,
        address bridgeAdapter,
        uint256 gasLimit,
        bytes calldata bridgeAdapterData,
        bytes calldata policyData
    ) external payable override {}

    function fundsArrivedFromChainCallback(address asset, uint256 amount) external override {}
}

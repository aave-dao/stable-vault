// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.4;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {IFundsHandler} from "src/interfaces/IFundsHandler.sol";
import {ITransferHelper} from "src/interfaces/ITransferHelper.sol";

contract MockFundsHandler is IFundsHandler {
    using SafeERC20 for IERC20;

    mapping(address asset => uint256 balanceRay) _mockedAssetBalancesRay;
    address[] _mockedAssets;
    uint256 _mockedAggregatedBalance;
    address _mockedTransferHelper;

    constructor(address transferHelper) {
        _mockedTransferHelper = transferHelper;
    }

    function mockAggregatedBalance(uint256 aggregatedBalance) external {
        _mockedAggregatedBalance = aggregatedBalance;
    }

    function mockAssetBalance(address asset, uint256 balanceRay) external {
        _mockedAssetBalancesRay[asset] = balanceRay;
    }

    function mockApprove(address spender, address asset, uint256 amount) external {
        IERC20(asset).forceApprove(spender, amount);
    }

    ////

    function getAggregatedBalance() external view override returns (uint256) {
        return _mockedAggregatedBalance;
    }

    function getAssetBalances() external view override returns (AssetBalance[] memory) {}

    function processDeposit(address asset, uint256 amount) external override returns (uint256) {
        ITransferHelper(_mockedTransferHelper).pull(asset, amount);
        return amount;
    }

    function processWithdrawal(address asset, uint256 amount) external override {
        IERC20(asset).forceApprove(msg.sender, amount);
    }

    function pushFundsToChain(
        address asset,
        uint256 amount,
        uint256 chainId,
        IBridgeAdapter.BridgeParams memory bridgeParams
    ) external payable override {}

    function updateChainBalanceCallback(uint256 chainId, uint256 snapshotBalanceRay, uint256 snapshotTimestamp)
        external
        override
    {}

    function fundsArrivedFromChainCallback(address asset, uint256 amount) external override {}
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IFundsHandler} from "../../src/interfaces/IFundsHandler.sol";

contract MockFundsHandler is IFundsHandler {
    mapping(address asset => uint256 balanceRay) _mockedAssetBalancesRay;
    uint256 _mockedAggregatedBalance;

    function mockAggregatedBalance(uint256 aggregatedBalance) external {
        _mockedAggregatedBalance = aggregatedBalance;
    }

    function mockAssetBalances(AssetBalance[] memory assetBalances) external {
        for (uint256 i = 0; i < assetBalances.length; i++) {
            _mockedAssetBalancesRay[assetBalances[i].asset] = assetBalances[i].amountRay;
        }
    }

    ////
    function getAggregatedBalance() external view override returns (uint256) {
        return _mockedAggregatedBalance;
    }

    function getAssetBalances() external view override returns (AssetBalance[] memory) {}

    function processDeposit(address asset, uint256 amount) external override {}

    function processWithdrawal(address asset, uint256 amount) external override {}

    function pushFundsToChain(
        address asset,
        uint256 amount,
        uint256 chainId,
        address bridgeFeePayer,
        address bridgeFeeToken,
        uint256 bridgeFeeAmount
    ) external payable override {}

    function updateChainBalanceCallback(uint256 chainId, uint256 snapshotBalanceRay, uint256 snapshotTimestamp)
        external
        override
    {}

    function fundsArrivedFromChainCallback(address asset, uint256 amount) external override {}

    function pullFromLiquidity(address asset, uint256 amount) external override {}
}

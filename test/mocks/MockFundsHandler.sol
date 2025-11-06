// SPDX-License-Identifier: MIT
pragma solidity ^0.8.4;

import {IChainGateway} from "../../src/interfaces/IChainGateway.sol";
import {IFundsHandler} from "../../src/interfaces/IFundsHandler.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract MockFundsHandler is IFundsHandler {
    using SafeERC20 for IERC20;

    mapping(address asset => uint256 balanceRay) _mockedAssetBalancesRay;
    address[] _mockedAssets;
    uint256 _mockedAggregatedBalance;

    function mockAggregatedBalance(uint256 aggregatedBalance) external {
        _mockedAggregatedBalance = aggregatedBalance;
    }

    function mockAssetBalance(address asset, uint256 balanceRay) external {
        _mockedAssetBalancesRay[asset] = balanceRay;
    }

    ////

    function getAggregatedBalance() external view override returns (uint256) {
        return _mockedAggregatedBalance;
    }

    function getAssetBalances() external view override returns (AssetBalance[] memory) {}

    function processDeposit(address asset, uint256 amount) external override {}

    function processWithdrawal(address asset, uint256 amount) external override {
        IERC20(asset).forceApprove(msg.sender, amount);
    }

    function pushFundsToChain(
        address asset,
        uint256 amount,
        uint256 chainId,
        IChainGateway.BridgeParams memory bridgeParams
    ) external payable override {}

    function updateChainBalanceCallback(uint256 chainId, uint256 snapshotBalanceRay, uint256 snapshotTimestamp)
        external
        override
    {}

    function fundsArrivedFromChainCallback(address asset, uint256 amount) external override {}

    function pullFromLiquidity(address asset, uint256 amount) external override {}
}

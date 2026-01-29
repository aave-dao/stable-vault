// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IChainBalanceOracle} from "src/interfaces/IChainBalanceOracle.sol";

contract MockChainBalanceOracle is IChainBalanceOracle {
    mapping(uint256 chainId => uint256 balanceRay) internal _chainBalances;

    function mockChainBalance(uint256 chainId, uint256 balanceRay) external {
        _chainBalances[chainId] = balanceRay;
    }

    function getChainBalance(uint256 chainId) external view override returns (uint256) {
        return _chainBalances[chainId];
    }
}

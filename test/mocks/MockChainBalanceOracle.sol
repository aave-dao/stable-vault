// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IChainBalanceOracle} from "src/interfaces/IChainBalanceOracle.sol";

contract MockChainBalanceOracle is IChainBalanceOracle {
    mapping(uint256 chainId => IChainBalanceOracle.ChainBalance) internal _chainBalances;

    function mockChainBalance(
        uint256 chainId,
        uint256 balanceRay,
        uint256 lastUpdateTimestamp,
        uint256 sourceChainTimestamp,
        bool isStale
    ) external {
        mockChainBalance(chainId, balanceRay, lastUpdateTimestamp, sourceChainTimestamp, block.number, isStale);
    }

    function mockChainBalance(
        uint256 chainId,
        uint256 balanceRay,
        uint256 lastUpdateTimestamp,
        uint256 sourceChainTimestamp,
        uint256 sourceChainBlockNumber,
        bool isStale
    ) public {
        _chainBalances[chainId] = IChainBalanceOracle.ChainBalance({
            balanceRay: balanceRay,
            lastUpdateTimestamp: lastUpdateTimestamp,
            sourceChainTimestamp: sourceChainTimestamp,
            sourceChainBlockNumber: sourceChainBlockNumber,
            isStale: isStale
        });
    }

    function getChainBalance(uint256 chainId) external view override returns (IChainBalanceOracle.ChainBalance memory) {
        return _chainBalances[chainId];
    }
}

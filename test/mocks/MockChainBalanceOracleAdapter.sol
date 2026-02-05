// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IChainBalanceOracleAdapter} from "src/interfaces/IChainBalanceOracleAdapter.sol";

contract MockChainBalanceOracleAdapter is IChainBalanceOracleAdapter {
    mapping(uint256 chainId => OracleResponse) internal _responses;
    bool public shouldRevert;

    function mockResponse(uint256 chainId, uint256 balanceRay, uint256 lastUpdateTimestamp, bool isStale) external {
        _responses[chainId] =
            OracleResponse({balanceRay: balanceRay, lastUpdateTimestamp: lastUpdateTimestamp, isStale: isStale});
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function getChainBalance(uint256 chainId) external view override returns (OracleResponse memory) {
        if (shouldRevert) {
            revert InvalidChainId(chainId);
        }
        return _responses[chainId];
    }
}

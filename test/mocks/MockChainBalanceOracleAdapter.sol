// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IChainBalanceOracle} from "src/interfaces/IChainBalanceOracle.sol";
import {IChainBalanceOracleAdapter} from "src/interfaces/IChainBalanceOracleAdapter.sol";

contract MockChainBalanceOracleAdapter is IChainBalanceOracleAdapter {
    mapping(uint256 chainId => IChainBalanceOracle.ChainBalance) internal _responses;
    bool public shouldRevert;

    error SomethingWentWrong();

    function mockResponse(
        uint256 chainId,
        uint256 balanceRay,
        uint256 lastUpdateTimestamp,
        uint256 sourceChainTimestamp,
        bool isStale
    ) external {
        _responses[chainId] = IChainBalanceOracle.ChainBalance({
            balanceRay: balanceRay,
            lastUpdateTimestamp: lastUpdateTimestamp,
            sourceChainTimestamp: sourceChainTimestamp,
            // The block number is not used in the mock, so we set it to 0.
            sourceChainBlockNumber: 0,
            isStale: isStale
        });
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function getChainBalance(uint256 chainId) external view override returns (IChainBalanceOracle.ChainBalance memory) {
        if (shouldRevert) {
            revert SomethingWentWrong();
        }
        return _responses[chainId];
    }
}

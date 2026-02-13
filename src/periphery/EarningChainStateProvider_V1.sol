// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IEarningChainGateway} from "src/interfaces/IEarningChainGateway.sol";

/// @title EarningChainStateProvider_V1
/// @author Aave Labs
/// @notice Version 1 of the base for the Earning Chain State Provider.
/// @dev This contract is used to define the version and the Balance Snapshot struct.
contract EarningChainStateProvider_V1 {
    uint256 public constant VERSION = 1;

    address internal immutable EARNING_CHAIN_GATEWAY;

    constructor(address earningChainGateway) {
        EARNING_CHAIN_GATEWAY = earningChainGateway;
    }

    /// @notice The representation of the Balance Snapshot.
    /// @param balanceRay The balance of the Earning Chain in RAY.
    /// @param timestamp The timestamp of the Balance Snapshot.
    /// @param blockNumber The block number of the Balance Snapshot.
    /// @param chainId The chain id of the Balance Snapshot.
    struct BalanceSnapshot {
        uint256 balanceRay;
        uint256 timestamp;
        uint256 blockNumber;
        uint256 chainId;
    }

    function _getData() internal view returns (bytes memory) {
        uint256 balanceRay = IEarningChainGateway(EARNING_CHAIN_GATEWAY).getAggregatedBalance();
        return abi.encode(
            BalanceSnapshot({
                balanceRay: balanceRay, timestamp: block.timestamp, blockNumber: block.number, chainId: block.chainid
            })
        );
    }
}

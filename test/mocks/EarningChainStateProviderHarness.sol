// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IEarningChainGateway} from "src/interfaces/IEarningChainGateway.sol";
import {IEarningChainStateProvider} from "src/interfaces/IEarningChainStateProvider.sol";

/// @notice Test-only harness that mirrors EarningChainStateProvider while allowing a logical chain id override.
/// @dev Needed for single-chain E2E simulations where Accounting and Earning contracts share one EVM.
contract EarningChainStateProviderHarness is IEarningChainStateProvider {
    uint256 public constant VERSION = 1;

    address internal immutable EARNING_CHAIN_GATEWAY;
    uint256 internal immutable SNAPSHOT_CHAIN_ID;

    constructor(address earningChainGateway, uint256 snapshotChainId) {
        EARNING_CHAIN_GATEWAY = earningChainGateway;
        SNAPSHOT_CHAIN_ID = snapshotChainId;
    }

    function getState() external view returns (bytes memory) {
        uint256 balance = IEarningChainGateway(EARNING_CHAIN_GATEWAY).getAggregatedBalance();
        return abi.encode(
            State({
                version: VERSION,
                data: abi.encode(
                    BalanceSnapshot({
                        balanceRay: balance,
                        timestamp: block.timestamp,
                        blockNumber: block.number,
                        chainId: SNAPSHOT_CHAIN_ID
                    })
                )
            })
        );
    }
}

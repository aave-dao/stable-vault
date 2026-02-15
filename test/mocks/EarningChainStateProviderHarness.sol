// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IEarningChainStateProvider} from "src/interfaces/IEarningChainStateProvider.sol";
import {EarningChainStateProviderV1} from "src/periphery/EarningChainStateProviderV1.sol";

/// @notice Test-only harness that mirrors EarningChainStateProvider while allowing a logical chain id override.
/// @dev Needed for single-chain E2E simulations where Accounting and Earning contracts share one EVM.
contract EarningChainStateProviderHarness is EarningChainStateProviderV1, IEarningChainStateProvider {
    uint256 internal immutable SNAPSHOT_CHAIN_ID;

    constructor(address earningChainGateway, uint256 snapshotChainId) EarningChainStateProviderV1(earningChainGateway) {
        SNAPSHOT_CHAIN_ID = snapshotChainId;
    }

    function getState() external view returns (bytes memory) {
        BalanceSnapshot memory snapshot = abi.decode(_getData(), (BalanceSnapshot));
        snapshot.chainId = SNAPSHOT_CHAIN_ID;
        return abi.encode(State({version: VERSION, data: abi.encode(snapshot)}));
    }
}

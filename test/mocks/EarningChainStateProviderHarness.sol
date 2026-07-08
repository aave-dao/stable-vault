// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {EarningChainStateProvider} from "src/periphery/EarningChainStateProvider.sol";
import {SCHEMA_VERSION} from "src/periphery/EarningChainStateSchemaV1.sol";

/// @notice Test-only harness that mirrors EarningChainStateProvider while allowing a logical chain id override.
/// @dev Needed for single-chain E2E simulations where Accounting and Earning contracts share one EVM.
contract EarningChainStateProviderHarness is EarningChainStateProvider {
    uint256 internal immutable SNAPSHOT_CHAIN_ID;

    constructor(address earningChainGateway, uint256 snapshotChainId) EarningChainStateProvider(earningChainGateway) {
        SNAPSHOT_CHAIN_ID = snapshotChainId;
    }

    function getState() external view override returns (bytes memory) {
        BalanceSnapshot memory snapshot = abi.decode(_getData(), (BalanceSnapshot));
        snapshot.chainId = SNAPSHOT_CHAIN_ID;
        return abi.encode(State({version: SCHEMA_VERSION, data: abi.encode(snapshot)}));
    }
}

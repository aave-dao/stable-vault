// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IEarningChainStateProvider} from "src/interfaces/IEarningChainStateProvider.sol";
import {EarningChainStateProviderV1} from "src/periphery/EarningChainStateProviderV1.sol";

/// @title EarningChainStateProvider
/// @author Aave Labs
/// @notice Facilitates the publishing of the state of the Earning Chain to the Accounting Chain.
/// @dev This contract is intended to be deployed on the Earning Chain and called by an Oracle network which publishes
/// the state to the Accounting Chain.
/// @dev The state is published as a single ABI-encoded struct which contains the version and the data.
/// For this version, the data is encoded as a BalanceSnapshot struct which contains the balance in RAY, the timestamp
/// and the block number. The version is used to determine the encoding of the data on the Accounting Chain.
/// @dev This contract is upgradeable to allow exposing additional state in future versions.
contract EarningChainStateProvider is Initializable, EarningChainStateProviderV1, IEarningChainStateProvider {
    /// @dev Constructor.
    /// @param earningChainGateway Address of the EarningChainGateway contract.
    constructor(address earningChainGateway) EarningChainStateProviderV1(earningChainGateway) {
        _disableInitializers();
    }

    /// @inheritdoc IEarningChainStateProvider
    function getState() external view returns (bytes memory) {
        return abi.encode(State({version: _getVersion(), data: _getData()}));
    }
}

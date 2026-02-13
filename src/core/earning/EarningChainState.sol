// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

import {IEarningChainGateway} from "src/interfaces/IEarningChainGateway.sol";
import {IEarningChainState} from "src/interfaces/IEarningChainState.sol";

/// @title EarningChainState
/// @author Aave Labs
/// @notice Facilitates the publishing of the state of the Earning Chain to the Accounting Chain.
/// @dev This contract is intended to be deployed on the Earning Chain and called by an Oracle network which publishes
/// the state to the Accounting Chain.
/// @dev The state is published as a single bytes encoded struct which contains the version and the data.
/// For this version, the data is encoded as a BalanceSnapshot struct which contains the balance in RAY, the timestamp
/// and the block number. The version is used to determine the encoding of the data on the Accounting Chain.
/// @dev This contract is upgradeable to allow exposing additional state in future versions.
contract EarningChainState is Initializable, IEarningChainState {
    uint256 public constant VERSION = 1;

    address internal immutable EARNING_CHAIN_GATEWAY;

    /// @dev Constructor.
    /// @param earningChainGateway Address of the EarningChainGateway contract.
    constructor(address earningChainGateway) {
        _disableInitializers();
        EARNING_CHAIN_GATEWAY = earningChainGateway;
    }

    /// @inheritdoc IEarningChainState
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
                        chainId: block.chainid
                    })
                )
            })
        );
    }

    function getChainId() external view returns (uint256) {
        return block.chainid;
    }
}

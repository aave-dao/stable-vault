// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";

import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import {IChainBalanceOracle} from "src/interfaces/IChainBalanceOracle.sol";
import {IChainBalanceOracleAdapter} from "src/interfaces/IChainBalanceOracleAdapter.sol";

/// @title ChainBalanceOracle
/// @author Aave Labs
/// @notice Oracle contract for fetching chain aggregated balance values through an adapter to an underlying data
/// source. @dev This contract is only used on the Accounting Chain to inform the asset value vs. obligations
/// calculations.
/// @custom:upgradeable
contract ChainBalanceOracle is AccessManagedUpgradeable, IChainBalanceOracle {
    /// @custom:storage-location erc7201:aave.storage.ChainBalanceOracle
    struct ChainBalanceOracleStorage {
        mapping(uint256 chainId => address oracleAdapter) oracleAdapterByChainId;
    }

    // keccak256(abi.encode(uint256(keccak256("aave.storage.ChainBalanceOracle")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT_CHAIN_BALANCE_ORACLE =
        0x6ac612655afeb35ba61923fff96d549bb19989dc9aae5077165522d8540af500;

    function $storage() private pure returns (ChainBalanceOracleStorage storage _storage) {
        assembly {
            _storage.slot := STORAGE_SLOT_CHAIN_BALANCE_ORACLE
        }
    }

    /// @dev Constructor.
    constructor() {
        _disableInitializers();
    }

    /// @dev Initializer.
    /// @param accessManager The address of the IAccessManager contract used for handling access control.
    function initialize(address accessManager) external virtual initializer {
        __ChainBalanceOracle_init(accessManager);
    }

    function __ChainBalanceOracle_init(address accessManager) internal virtual onlyInitializing {
        IAccessManager(accessManager).canCall(address(0), address(0), bytes4(0));
        __AccessManaged_init(accessManager);
    }

    /// @inheritdoc IChainBalanceOracle
    /// @dev Wraps the adapter call in a try-catch to avoid disruption to the consumer.
    function getChainBalance(uint256 chainId) external view override returns (IChainBalanceOracle.ChainBalance memory) {
        require($storage().oracleAdapterByChainId[chainId] != address(0), ChainBalanceOracleAdapterNotFound(chainId));
        try IChainBalanceOracleAdapter($storage().oracleAdapterByChainId[chainId]).getChainBalance(chainId) returns (
            IChainBalanceOracle.ChainBalance memory chainBalance
        ) {
            return chainBalance;
        } catch {
            return IChainBalanceOracle.ChainBalance({
                balanceRay: 0, lastUpdateTimestamp: 0, sourceChainTimestamp: 0, sourceChainBlockNumber: 0, isStale: true
            });
        }
    }

    function getChainBalanceOracleAdapter(uint256 chainId) external view returns (address) {
        return $storage().oracleAdapterByChainId[chainId];
    }

    function setChainBalanceOracleAdapter(uint256 chainId, address adapter) external restricted {
        address currentAdapter = $storage().oracleAdapterByChainId[chainId];
        IChainBalanceOracleAdapter(adapter).supportsInterface(type(IChainBalanceOracleAdapter).interfaceId);
        $storage().oracleAdapterByChainId[chainId] = adapter;
        emit ChainBalanceAdapterSet(chainId, currentAdapter, adapter);
    }
}

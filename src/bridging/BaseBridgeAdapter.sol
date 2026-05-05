// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {TransferHelperClient} from "src/misc/TransferHelperClient.sol";
import {Errors} from "src/types/Errors.sol";

/// @title BaseBridgeAdapter
/// @author Aave Labs
/// @notice Base contract for bridge adapters.
abstract contract BaseBridgeAdapter is AccessManaged, TransferHelperClient, IBridgeAdapter {
    using SafeERC20 for IERC20;

    /// @dev Funds handling does not depend on the source chain id (only data handling does).
    /// @dev Assumes downstream ingestion of received funds does not expect a valid source chain id.
    uint256 internal constant RECEIVED_FUNDS_ONLY_SOURCE_CHAIN_ID = 0;

    address internal immutable GATEWAY;

    mapping(uint256 chainId => address destinationChainAdapter) internal _destinationChainAdapterOf;

    modifier onlyGateway() {
        require(msg.sender == GATEWAY, Errors.OnlyGateway());
        _;
    }

    /// @dev Constructor.
    /// @param accessManager Address of the IAccessManager contract used for handling access control.
    /// @param gateway Address of the Gateway contract.
    /// @param transferHelper Address of the TransferHelper.
    constructor(address accessManager, address gateway, address transferHelper)
        AccessManaged(accessManager)
        TransferHelperClient(transferHelper)
    {
        IAccessManager(accessManager).canCall(address(0), address(0), bytes4(0));
        require(gateway != address(0), Errors.ZeroAddress());
        GATEWAY = gateway;
    }

    /// @inheritdoc IBridgeAdapter
    function getGateway() external view override returns (address) {
        return GATEWAY;
    }

    /// @notice Getter for the destination chain adapter for a given chain id.
    /// @param chainId Chain id of the destination chain.
    /// @return The address of the destination chain adapter.
    function getDestinationChainAdapter(uint256 chainId) external view returns (address) {
        return _destinationChainAdapterOf[chainId];
    }

    /// @inheritdoc IBridgeAdapter
    function publishMessageToChainWithFeePayer(
        uint256 destinationChainId,
        address asset,
        uint256 amount,
        bytes memory data,
        address feePayer,
        uint256 gasLimit,
        bytes memory bridgeParamsEncoded
    ) external payable virtual override;

    function setDestinationChainAdapter(uint256 chainId, address destinationChainAdapter) external override restricted {
        require(chainId != 0 && chainId != block.chainid, Errors.InvalidParameter());
        _destinationChainAdapterOf[chainId] = destinationChainAdapter;
        emit DestinationChainAdapterSet(chainId, destinationChainAdapter);
    }
}

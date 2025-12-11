// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {ErrorsLib} from "src/libraries/ErrorsLib.sol";
import {TransferHelperClient} from "src/misc/TransferHelperClient.sol";

/// @title BaseBridgeAdapter
/// @author Aave Labs
/// @notice Base contract for bridge adapters.
abstract contract BaseBridgeAdapter is AccessManaged, TransferHelperClient, IBridgeAdapter {
    using SafeERC20 for IERC20;

    /// @dev Funds handling does not depend on the source chain id (only data handling does).
    /// @dev Assumes downstream ingestion of received funds does not expect a valid source chain id.
    uint256 internal immutable RECEIVED_FUNDS_ONLY_SOURCE_CHAIN_ID = 0;

    address internal immutable GATEWAY;

    mapping(uint256 chainId => address destinationChainAdapter) internal _destinationChainAdapterOf;

    modifier onlyGateway() {
        require(msg.sender == GATEWAY, ErrorsLib.OnlyGateway());
        _;
    }

    modifier onlySelf() {
        if (msg.sender != address(this)) {
            revert ErrorsLib.OnlySelf();
        }
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
        GATEWAY = gateway;
    }

    /// @inheritdoc IBridgeAdapter
    function getGateway() external view override returns (address) {
        return GATEWAY;
    }

    /// @inheritdoc IBridgeAdapter
    function publishMessageToChainWithFeePayer(
        uint256 destinationChainId,
        IBridgeAdapter.BridgeAsset[] memory assets,
        bytes memory data,
        IBridgeAdapter.BridgeParams memory bridgeParams
    ) external payable virtual override;

    function setDestinationChainAdapter(uint256 chainId, address destinationChainAdapter) external override restricted {
        _destinationChainAdapterOf[chainId] = destinationChainAdapter;
    }

    /// @inheritdoc IBridgeAdapter
    function replayFundsReceiving(IBridgeAdapter.BridgeAsset[] memory assets) public virtual override {
        _processReceivedFunds(assets);
    }

    function _processReceivedFunds(IBridgeAdapter.BridgeAsset[] memory assets)
        internal
        assertingTransferHelperBalanceForBridgeAssets(assets)
    {
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i].asset;
            uint256 amount = assets[i].amount;
            _transferToTransferHelper(asset, amount);
        }
        IChainGateway(GATEWAY).receiveMessage(RECEIVED_FUNDS_ONLY_SOURCE_CHAIN_ID, assets, "");
    }

    receive() external payable {}
}

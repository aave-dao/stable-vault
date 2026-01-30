// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseChainGateway} from "src/core/BaseChainGateway.sol";
import {IAccountingChainGateway} from "src/interfaces/IAccountingChainGateway.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {IFundsHandler} from "src/interfaces/IFundsHandler.sol";
import {IIouTokenManager} from "src/interfaces/IIouTokenManager.sol";
import {Constants} from "src/types/Constants.sol";

/// @title AccountingChainGateway
/// @author Aave Labs
/// @notice Facilitates cross chain messaging one or more Earning Chains.
contract AccountingChainGateway is BaseChainGateway, IAccountingChainGateway {
    using SafeERC20 for IERC20;

    address internal immutable FUNDS_HANDLER;

    modifier onlyFundsHandler() {
        require(msg.sender == FUNDS_HANDLER, OnlyFundsHandler());
        _;
    }

    /// @dev Constructor.
    /// @param fundsHandler The address of the FundsHandler contract.
    /// @param iouTokenManager The address of the IOU token manager contract.
    constructor(address fundsHandler, address iouTokenManager) BaseChainGateway(iouTokenManager) {
        _disableInitializers();
        FUNDS_HANDLER = fundsHandler;
    }

    /// @dev Initializer.
    /// @param accessManager The address of the IAccessManager contract used for handling access control.
    function initialize(address accessManager) external virtual initializer {
        __AccountingChainGateway_init(accessManager);
    }

    function __AccountingChainGateway_init(address accessManager) internal virtual onlyInitializing {
        __BaseChainGateway_init(accessManager);
    }

    function getFundsHandler() external view returns (address) {
        return FUNDS_HANDLER;
    }

    /// @inheritdoc IAccountingChainGateway
    function sendPushFundsToChainMessage(
        address asset,
        uint256 amount,
        uint256 targetChainId,
        IBridgeAdapter.BridgeParams memory bridgeParams
    ) external payable override onlyFundsHandler {
        address adapter = $BaseChainGateway().defaultBridgeAdapter[asset][targetChainId];
        require(adapter != address(0), AdapterNotFound());
        _sendCrossChainMessage(targetChainId, adapter, asset, amount, "", bridgeParams);
    }

    function _receiveFunds(IBridgeAdapter.BridgeAsset[] memory assets) internal override {
        for (uint256 i = 0; i < assets.length; i++) {
            IFundsHandler(FUNDS_HANDLER).fundsArrivedFromChainCallback(assets[i].asset, assets[i].amount);
        }
    }

    function _receiveData(uint256 sourceChainId, bytes memory data) internal override {
        _onlyAdapter(Constants.ASSET_FOR_DATA_ONLY_BRIDGE, sourceChainId);
        IChainGateway.CrossChainMessage memory crossChainMessage = abi.decode(data, (IChainGateway.CrossChainMessage));
        if (crossChainMessage.messageType == IChainGateway.MessageType.BALANCE_SNAPSHOT) {
            _updateChainBalanceSnapshot(sourceChainId, crossChainMessage.data);
        } else if (crossChainMessage.messageType == IChainGateway.MessageType.BRIDGE_IOU_TOKEN) {
            _bridgeIouTokenFromEarningChain(crossChainMessage.data);
        } else if (crossChainMessage.messageType == IChainGateway.MessageType.BURN_IOU_TOKEN) {
            _burnIouToken(sourceChainId, crossChainMessage.data);
        } else {
            revert IChainGateway.InvalidMessageType();
        }
    }

    function _bridgeIouTokenFromEarningChain(bytes memory data) internal {
        IChainGateway.IouTokenBridgeMessage memory iouTokenBridgeMessage =
            abi.decode(data, (IChainGateway.IouTokenBridgeMessage));
        IIouTokenManager(IOU_TOKEN_MANAGER).releaseTokens(iouTokenBridgeMessage.recipient, iouTokenBridgeMessage.amount);
    }

    function _burnIouToken(uint256 sourceChainId, bytes memory data) internal {
        IChainGateway.BurnIouTokenMessage memory burnIouTokenMessage =
            abi.decode(data, (IChainGateway.BurnIouTokenMessage));
        IIouTokenManager(IOU_TOKEN_MANAGER).burnLockedTokens(burnIouTokenMessage.iouTokenAmountBurnedRay);
        IFundsHandler(FUNDS_HANDLER)
            .updateChainBalanceCallback(
                sourceChainId,
                burnIouTokenMessage.balanceSnapshotTotalAssetsInRay,
                burnIouTokenMessage.chainBalanceSnapshotNonce
            );
    }

    function _updateChainBalanceSnapshot(uint256 sourceChainId, bytes memory data) internal {
        IChainGateway.BalanceSnapshot memory balanceSnapshot = abi.decode(data, (IChainGateway.BalanceSnapshot));
        IFundsHandler(FUNDS_HANDLER)
            .updateChainBalanceCallback(sourceChainId, balanceSnapshot.totalAssetsInRay, balanceSnapshot.nonce);
    }
}

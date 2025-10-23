// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseChainGateway} from "../common/BaseChainGateway.sol";
import {IAccountingChainGateway} from "../interfaces/IAccountingChainGateway.sol";
import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "../interfaces/IChainGateway.sol";
import {IFundsHandler} from "../interfaces/IFundsHandler.sol";
import {IIouTokenManager} from "../interfaces/IIouTokenManager.sol";

/// @title AccountingChainGateway
/// @notice Facilitates cross chain messaging one or more Earning Chains.
contract AccountingChainGateway is IAccountingChainGateway, BaseChainGateway {
    using SafeERC20 for IERC20;

    modifier onlyFundsHandler() {
        require(msg.sender == _fundsHandler, NotFundsHandler());
        _;
    }

    address internal _fundsHandler;

    constructor(address admin, address fundsHandler, address iouTokenManager) BaseChainGateway(admin, iouTokenManager) {
        _fundsHandler = fundsHandler;
    }

    function sendPushFundsToChainMessage(address asset, uint256 amount, uint256 targetChainId)
        external
        onlyFundsHandler
    {
        address adapter = _bridgeAdapter[asset][targetChainId];
        require(adapter != address(0), UnsupportedAdapter());
        // Pull funds from caller into this contract
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        // Approve the bridge adapter to spend the funds
        IERC20(asset).forceApprove(adapter, amount);
        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: asset, amount: amount});
        IBridgeAdapter(adapter).publishMessageToChain(targetChainId, assets, "");
    }

    /// @dev Assume for Emergency withdrawal only - Earning chain will send whatever asset it prefers.
    /// @param amountRay The `amount` must be in RAY to be token agnostic.
    /// @param targetChainId The destination chainId.
    function sendPullFundsFromChainMessage(uint256 amountRay, uint256 targetChainId) external onlyFundsHandler {
        IBridgeAdapter(_bridgeAdapter[ASSET_FOR_DATA_ONLY_BRIDGE][targetChainId])
            .publishMessageToChain(targetChainId, new IBridgeAdapter.BridgeAsset[](0), abi.encode(amountRay));
    }

    function _receiveFunds(IBridgeAdapter.BridgeAsset[] memory assets) internal override {
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i].asset;
            uint256 amount = assets[i].amount;
            IERC20(asset).safeTransferFrom(msg.sender, _fundsHandler, amount);
            IFundsHandler(_fundsHandler).fundsArrivedFromChainCallback(asset, amount);
        }
    }

    function _receiveData(uint256 sourceChainId, bytes memory data) internal override {
        _onlyAdapter(ASSET_FOR_DATA_ONLY_BRIDGE, sourceChainId);
        IChainGateway.CrossChainMessage memory crossChainMessage = abi.decode(data, (IChainGateway.CrossChainMessage));
        if (crossChainMessage.messageType == IChainGateway.MessageType.BALANCE_SNAPSHOT) {
            _updateChainBalanceSnapshot(sourceChainId, crossChainMessage.data);
        } else if (crossChainMessage.messageType == IChainGateway.MessageType.BRIDGE_IOUTOKEN) {
            _bridgeIouTokenFromEarningChain(sourceChainId, crossChainMessage.data);
        } else if (crossChainMessage.messageType == IChainGateway.MessageType.BURN_IOUTOKEN) {
            _burnIouToken(sourceChainId, crossChainMessage.data);
        } else {
            revert IChainGateway.InvalidMessageType();
        }
    }

    // TODO: I think we need to verify who is sending the messages on the source chain.
    // Not only this, but all of the messages we need to restrict.
    function _bridgeIouTokenFromEarningChain(uint256 sourceChainId, bytes memory data) internal {
        IChainGateway.IouTokenBridgeMessage memory iouTokenBridgeMessage =
            abi.decode(data, (IChainGateway.IouTokenBridgeMessage));
        IIouTokenManager(IOU_TOKEN_MANAGER).releaseTokens(iouTokenBridgeMessage.recipient, iouTokenBridgeMessage.amount);
    }

    function _burnIouToken(uint256 sourceChainId, bytes memory data) internal {
        IChainGateway.BurnIouTokenMessage memory burnIouTokenMessage =
            abi.decode(data, (IChainGateway.BurnIouTokenMessage));
        IIouTokenManager(IOU_TOKEN_MANAGER).burnLockedTokens(burnIouTokenMessage.iouTokenAmountBurnedRay);
        IFundsHandler(_fundsHandler)
            .updateChainBalanceCallback(
                sourceChainId,
                burnIouTokenMessage.balanceSnapshotTotalAssetsInRay,
                burnIouTokenMessage.balanceSnapshotTimestamp
            );
    }

    function _updateChainBalanceSnapshot(uint256 sourceChainId, bytes memory data) internal {
        IChainGateway.BalanceSnapshot memory balanceSnapshot = abi.decode(data, (IChainGateway.BalanceSnapshot));
        IFundsHandler(_fundsHandler)
            .updateChainBalanceCallback(sourceChainId, balanceSnapshot.totalAssetsInRay, balanceSnapshot.timestamp);
    }
}

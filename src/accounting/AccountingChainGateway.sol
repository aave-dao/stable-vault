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
contract AccountingChainGateway is BaseChainGateway, IAccountingChainGateway {
    using SafeERC20 for IERC20;

    modifier onlyFundsHandler() {
        require(msg.sender == FUNDS_HANDLER, NotFundsHandler());
        _;
    }

    address internal immutable FUNDS_HANDLER;

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
        BridgeParams memory bridgeParams
    ) external payable override onlyFundsHandler {
        address adapter = $BaseChainGateway().defaultBridgeAdapter[asset][targetChainId];
        require(adapter != address(0), AdapterNotFound());

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        // The FundsHandler will have pulled the fee token from the caller to itself.
        // Pull the fee token from the FundsHandler to this contract.
        _prepareBridgeFeeForAdapter(adapter, msg.sender, bridgeParams.feeToken, bridgeParams.feeAmount);
        _sendCrossChainMessage(targetChainId, adapter, asset, amount, "", bridgeParams);
    }

    function _receiveFunds(IBridgeAdapter.BridgeAsset[] memory assets) internal override {
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i].asset;
            uint256 amount = assets[i].amount;
            IERC20(asset).safeTransferFrom(msg.sender, FUNDS_HANDLER, amount);
            IFundsHandler(FUNDS_HANDLER).fundsArrivedFromChainCallback(asset, amount);
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

    function _bridgeIouTokenFromEarningChain(
        uint256,
        /* sourceChainId */
        bytes memory data
    )
        internal
    {
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

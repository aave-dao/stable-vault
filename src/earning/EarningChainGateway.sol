// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseChainGateway} from "../common/BaseChainGateway.sol";
import {IAllocator} from "../interfaces/IAllocator.sol";
import {IAllocator} from "../interfaces/IAllocator.sol";
import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "../interfaces/IChainGateway.sol";
import {IEarningChainGateway} from "../interfaces/IEarningChainGateway.sol";
import {IIouTokenManager} from "../interfaces/IIouTokenManager.sol";
import {AssetLib} from "../libraries/AssetLib.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {EventLib} from "../libraries/EventLib.sol";

import {console} from "forge-std/console.sol";

/// @title EarningChainGateway
/// @notice Facilitates cross chain messaging with exactly one Accounting Chain.
contract EarningChainGateway is IEarningChainGateway, BaseChainGateway {
    using SafeERC20 for IERC20;
    using AssetLib for uint256;

    modifier onlyManager() {
        require(msg.sender == _manager, ErrorsLib.NotManager());
        _;
    }

    uint256 internal immutable ACCOUNTING_CHAIN_ID;
    address internal _allocator;
    address internal _manager;
    uint256 internal _balanceSnapshotNonce;

    constructor(address admin, uint256 accountingChainId, address iouTokenManager)
        BaseChainGateway(admin, iouTokenManager)
    {
        ACCOUNTING_CHAIN_ID = accountingChainId;
    }

    function getAdmin() external view returns (address) {
        return _admin;
    }

    function getManager() external view returns (address) {
        return _manager;
    }

    function getIouTokenManager() external view returns (address) {
        return IOU_TOKEN_MANAGER;
    }

    /// @inheritdoc IEarningChainGateway
    function getAccountingChainId() external view override returns (uint256) {
        return ACCOUNTING_CHAIN_ID;
    }

    /// @inheritdoc IEarningChainGateway
    function getAggregatedBalance() external view override returns (uint256) {
        return _getTotalAssetsInRay();
    }

    function setManager(address manager) external onlyAdmin {
        require(manager != address(0), ErrorsLib.ZeroAddress());
        _manager = manager;
        emit EventLib.ManagerSet(manager);
    }

    function setAllocator(address allocator) external onlyAdmin {
        require(allocator != address(0), ErrorsLib.ZeroAddress());
        _allocator = allocator;
        emit EventLib.AllocatorSet(allocator);
    }

    /// @inheritdoc IEarningChainGateway
    function sendBalanceUpdate() external override onlyManager {
        _sendBalanceUpdate();
    }

    /// @inheritdoc IEarningChainGateway
    function sendBalanceUpdateWithFeePayer(address bridgeFeePayer, address bridgeFeeToken, uint256 bridgeFeeAmount)
        external
        payable
        override
    {
        IBridgeAdapter(_bridgeAdapter[ASSET_FOR_DATA_ONLY_BRIDGE][ACCOUNTING_CHAIN_ID])
        .publishMessageToChainWithFeePayer{
            value: msg.value
        }(
            bridgeFeePayer,
            bridgeFeeToken,
            bridgeFeeAmount,
            ACCOUNTING_CHAIN_ID,
            new IBridgeAdapter.BridgeAsset[](0),
            _getBalanceSnapshotData()
        );
    }

    /// @inheritdoc IEarningChainGateway
    function exchangeIouTokens(
        uint256 iouTokenAmountRay,
        address tokenOut,
        address tokenOutReceiver,
        address bridgeFeePayer,
        address bridgeFeeToken,
        uint256 bridgeFeeAmount
    ) external payable override returns (uint256) {
        require(iouTokenAmountRay > 0, ErrorsLib.ZeroAmount());
        require(bridgeFeeAmount > 0, ErrorsLib.ZeroAmount());
        if (bridgeFeeToken == address(0)) {
            require(msg.value >= bridgeFeeAmount, ErrorsLib.InsufficientFunds());
        }
        // TODO: apply a withdrawal fee here?
        IIouTokenManager(IOU_TOKEN_MANAGER).burnTokens(msg.sender, iouTokenAmountRay);
        uint256 amountOut = iouTokenAmountRay.rayToAssetDecimals(tokenOut);
        IAllocator(_allocator).withdraw(tokenOut, amountOut);
        IERC20(tokenOut).safeTransfer(tokenOutReceiver, amountOut);
        console.log("iou token amount burned ray: ", iouTokenAmountRay);
        console.log("chain balance snapshot nonce: ", _balanceSnapshotNonce);
        console.log("balance snapshot total assets in ray: ", _getTotalAssetsInRay());
        bytes memory data = abi.encode(
            IChainGateway.CrossChainMessage({
                messageType: IChainGateway.MessageType.BURN_IOUTOKEN,
                data: abi.encode(
                    IChainGateway.BurnIouTokenMessage({
                        iouTokenAmountBurnedRay: iouTokenAmountRay,
                        chainBalanceSnapshotNonce: _balanceSnapshotNonce++,
                        balanceSnapshotTotalAssetsInRay: _getTotalAssetsInRay()
                    })
                )
            })
        );
        IBridgeAdapter(_bridgeAdapter[ASSET_FOR_DATA_ONLY_BRIDGE][ACCOUNTING_CHAIN_ID])
        .publishMessageToChainWithFeePayer{
            value: msg.value
        }(
            bridgeFeePayer,
            bridgeFeeToken,
            bridgeFeeAmount,
            ACCOUNTING_CHAIN_ID,
            new IBridgeAdapter.BridgeAsset[](0),
            data
        );
        // TODO: emit event?
        return amountOut;
    }

    /// @inheritdoc IEarningChainGateway
    function exit(address asset, uint256 amount) external override onlyManager {
        require(amount > 0, ErrorsLib.ZeroAmount());
        IAllocator(_allocator).withdraw(asset, amount);
        _returnFunds(asset, amount);
    }

    function _receiveFunds(IBridgeAdapter.BridgeAsset[] memory assets) internal override {
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i].asset;
            uint256 amount = assets[i].amount;
            IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
            IERC20(asset).forceApprove(_allocator, amount);
            IAllocator(_allocator).deposit(asset, amount);
        }
        // TODO: should this callback be gated behind a flag sent from the Accounting Chain? or should we check gas
        // left?
        _sendBalanceUpdate();
    }

    function _receiveData(uint256 sourceChainId, bytes memory data) internal override {
        _onlyAdapter(ASSET_FOR_DATA_ONLY_BRIDGE, sourceChainId);
        IChainGateway.CrossChainMessage memory crossChainMessage = abi.decode(data, (IChainGateway.CrossChainMessage));
        if (crossChainMessage.messageType == IChainGateway.MessageType.BRIDGE_IOUTOKEN) {
            _bridgeIouTokenFromAccountingChain(sourceChainId, crossChainMessage.data);
        } else {
            revert IChainGateway.InvalidMessageType();
        }
    }

    function _bridgeIouTokenFromAccountingChain(
        uint256,
        /* sourceChainId */
        bytes memory data
    )
        internal
    {
        IChainGateway.IouTokenBridgeMessage memory iouTokenBridgeMessage =
            abi.decode(data, (IChainGateway.IouTokenBridgeMessage));
        IIouTokenManager(IOU_TOKEN_MANAGER).mintTokens(iouTokenBridgeMessage.recipient, iouTokenBridgeMessage.amount);
        // TODO: emit event?
    }

    function _returnFunds(address asset, uint256 amount) internal {
        address adapter = _bridgeAdapter[asset][ACCOUNTING_CHAIN_ID];
        IERC20(asset).forceApprove(adapter, amount);
        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: asset, amount: amount});
        IBridgeAdapter(adapter).publishMessageToChain(ACCOUNTING_CHAIN_ID, assets, _getBalanceSnapshotData());
    }

    function _sendBalanceUpdate() internal {
        IBridgeAdapter(_bridgeAdapter[ASSET_FOR_DATA_ONLY_BRIDGE][ACCOUNTING_CHAIN_ID])
            .publishMessageToChain(ACCOUNTING_CHAIN_ID, new IBridgeAdapter.BridgeAsset[](0), _getBalanceSnapshotData());
    }

    function _getTotalAssetsInRay() internal view returns (uint256) {
        IAllocator.AllocatorBalance[] memory allocatorBalances = IAllocator(_allocator).getAssetBalances();
        uint256 totalAssetsInRay;
        for (uint256 i = 0; i < allocatorBalances.length; i++) {
            totalAssetsInRay += allocatorBalances[i].amount.assetDecimalsToRay(allocatorBalances[i].asset);
        }
        return totalAssetsInRay;
    }

    function _getBalanceSnapshotData() internal returns (bytes memory) {
        return abi.encode(
            IChainGateway.CrossChainMessage({
                messageType: IChainGateway.MessageType.BALANCE_SNAPSHOT,
                data: abi.encode(
                    IChainGateway.BalanceSnapshot({
                        totalAssetsInRay: _getTotalAssetsInRay(), nonce: _balanceSnapshotNonce++
                    })
                )
            })
        );
    }
}

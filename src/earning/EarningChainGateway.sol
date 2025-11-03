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

/// @title EarningChainGateway
/// @notice Facilitates cross chain messaging with exactly one Accounting Chain.
contract EarningChainGateway is BaseChainGateway, IEarningChainGateway {
    using SafeERC20 for IERC20;
    using AssetLib for uint256;

    uint256 internal immutable ACCOUNTING_CHAIN_ID;
    address internal immutable ALLOCATOR;
    uint256 internal _balanceSnapshotNonce;

    /// @dev Constructor.
    /// @param accountingChainId The Chain ID of the Accounting Chain.
    /// @param allocator The address of the Allocator contract.
    /// @param iouTokenManager The address of the IOU token manager contract.
    constructor(uint256 accountingChainId, address allocator, address iouTokenManager)
        BaseChainGateway(iouTokenManager)
    {
        _disableInitializers();
        ACCOUNTING_CHAIN_ID = accountingChainId;
        ALLOCATOR = allocator;
    }

    /// @dev Initializer.
    /// @param accessManager The address of the IAccessManager contract used for handling access control.
    function initialize(address accessManager) external virtual initializer {
        __EarningChainGateway_init(accessManager);
    }

    function __EarningChainGateway_init(address accessManager) internal virtual onlyInitializing {
        __BaseChainGateway_init(accessManager);
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

    /// @inheritdoc IEarningChainGateway
    function sendBalanceUpdateWithFeePayer(address bridgeFeePayer, address bridgeFeeToken, uint256 bridgeFeeAmount)
        external
        payable
        override
    {
        require(bridgeFeeAmount > 0, ErrorsLib.ZeroAmount());
        address adapter = _defaultBridgeAdapter[ASSET_FOR_DATA_ONLY_BRIDGE][ACCOUNTING_CHAIN_ID];
        require(adapter != address(0), UnsupportedAdapter());
        if (bridgeFeeToken == address(0)) {
            require(msg.value >= bridgeFeeAmount, ErrorsLib.InsufficientFunds());
        } else {
            IERC20(bridgeFeeToken).safeTransferFrom(bridgeFeePayer, address(this), bridgeFeeAmount);
            IERC20(bridgeFeeToken).forceApprove(adapter, bridgeFeeAmount);
        }
        IBridgeAdapter(adapter).publishMessageToChainWithFeePayer{value: msg.value}(
            ACCOUNTING_CHAIN_ID,
            new IBridgeAdapter.BridgeAsset[](0),
            _getBalanceSnapshotData(),
            bridgeFeePayer,
            bridgeFeeToken,
            bridgeFeeAmount
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
        IIouTokenManager(IOU_TOKEN_MANAGER).burnTokens(msg.sender, iouTokenAmountRay);

        require(bridgeFeeAmount > 0, ErrorsLib.ZeroAmount());

        address adapter = _defaultBridgeAdapter[ASSET_FOR_DATA_ONLY_BRIDGE][ACCOUNTING_CHAIN_ID];
        require(adapter != address(0), UnsupportedAdapter());

        if (bridgeFeeToken == address(0)) {
            require(msg.value >= bridgeFeeAmount, ErrorsLib.InsufficientFunds());
        } else {
            IERC20(bridgeFeeToken).safeTransferFrom(bridgeFeePayer, address(this), bridgeFeeAmount);
            IERC20(bridgeFeeToken).forceApprove(adapter, bridgeFeeAmount);
        }

        // TODO: apply a withdrawal fee here?
        uint256 amountOut = iouTokenAmountRay.rayToAssetDecimals(tokenOut);
        IAllocator(ALLOCATOR).withdraw(tokenOut, amountOut);
        IERC20(tokenOut).safeTransfer(tokenOutReceiver, amountOut);
        bytes memory data = abi.encode(
            IChainGateway.CrossChainMessage({
                messageType: IChainGateway.MessageType.BURN_IOUTOKEN,
                data: abi.encode(
                    IChainGateway.BurnIouTokenMessage({
                        iouTokenAmountBurnedRay: iouTokenAmountRay,
                        chainBalanceSnapshotNonce: _getAndUpdateBalanceSnapshotNonce(),
                        balanceSnapshotTotalAssetsInRay: _getTotalAssetsInRay()
                    })
                )
            })
        );
        IBridgeAdapter(adapter).publishMessageToChainWithFeePayer{value: msg.value}(
            ACCOUNTING_CHAIN_ID,
            new IBridgeAdapter.BridgeAsset[](0),
            data,
            bridgeFeePayer,
            bridgeFeeToken,
            bridgeFeeAmount
        );
        // TODO: emit event?
        return amountOut;
    }

    /// @inheritdoc IEarningChainGateway
    function pushFundsToAccountingChain(
        address asset,
        uint256 amount,
        address bridgeFeePayer,
        address bridgeFeeToken,
        uint256 bridgeFeeAmount
    ) external payable override restricted {
        require(amount > 0, ErrorsLib.ZeroAmount());
        require(bridgeFeeAmount > 0, ErrorsLib.ZeroAmount());
        if (bridgeFeeToken == address(0)) {
            require(msg.value >= bridgeFeeAmount, ErrorsLib.InsufficientFunds());
        }
        IAllocator(ALLOCATOR).withdraw(asset, amount);
        _returnFunds(asset, amount, bridgeFeePayer, bridgeFeeToken, bridgeFeeAmount);
    }

    function _receiveFunds(IBridgeAdapter.BridgeAsset[] memory assets) internal override {
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i].asset;
            uint256 amount = assets[i].amount;
            IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
            IERC20(asset).forceApprove(ALLOCATOR, amount);
            IAllocator(ALLOCATOR).deposit(asset, amount);
        }
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

    function _returnFunds(
        address asset,
        uint256 amount,
        address bridgeFeePayer,
        address bridgeFeeToken,
        uint256 bridgeFeeAmount
    ) internal {
        address adapter = _defaultBridgeAdapter[asset][ACCOUNTING_CHAIN_ID];
        IERC20(asset).forceApprove(adapter, amount);
        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: asset, amount: amount});
        IBridgeAdapter(adapter).publishMessageToChainWithFeePayer{value: msg.value}(
            ACCOUNTING_CHAIN_ID, assets, _getBalanceSnapshotData(), bridgeFeePayer, bridgeFeeToken, bridgeFeeAmount
        );
    }

    function _getTotalAssetsInRay() internal view returns (uint256) {
        IAllocator.AllocatorBalance[] memory allocatorBalances = IAllocator(ALLOCATOR).getAssetBalances();
        uint256 totalAssetsInRay;
        for (uint256 i = 0; i < allocatorBalances.length; i++) {
            totalAssetsInRay += allocatorBalances[i].amount.assetDecimalsToRay(allocatorBalances[i].asset);
        }
        return totalAssetsInRay;
    }

    /// @dev Increments the balance snapshot nonce and returns the new nonce
    /// @dev Assumes the Accounting Chain does not allow non-replayable nonces, so the new nonce sent is always higher
    /// than the previous nonce stored on Accounting Chain.
    function _getAndUpdateBalanceSnapshotNonce() internal returns (uint256) {
        return ++_balanceSnapshotNonce;
    }

    function _getBalanceSnapshotData() internal returns (bytes memory) {
        return abi.encode(
            IChainGateway.CrossChainMessage({
                messageType: IChainGateway.MessageType.BALANCE_SNAPSHOT,
                data: abi.encode(
                    IChainGateway.BalanceSnapshot({
                        totalAssetsInRay: _getTotalAssetsInRay(), nonce: _getAndUpdateBalanceSnapshotNonce()
                    })
                )
            })
        );
    }
}

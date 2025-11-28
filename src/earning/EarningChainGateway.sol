// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseChainGateway} from "../common/BaseChainGateway.sol";
import {TransferHelperClient} from "../common/TransferHelperClient.sol";
import {IAllocator} from "../interfaces/IAllocator.sol";
import {IAllocator} from "../interfaces/IAllocator.sol";
import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "../interfaces/IChainGateway.sol";
import {IEarningChainGateway} from "../interfaces/IEarningChainGateway.sol";
import {IIouTokenManager} from "../interfaces/IIouTokenManager.sol";
import {ITransferHelper} from "../interfaces/ITransferHelper.sol";
import {IWithdrawalPolicy} from "../interfaces/IWithdrawalPolicy.sol";
import {AssetLib} from "../libraries/AssetLib.sol";
import {ConstantsLib} from "../libraries/ConstantsLib.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";

/// @title EarningChainGateway
/// @notice Facilitates cross chain messaging with exactly one Accounting Chain.
contract EarningChainGateway is BaseChainGateway, TransferHelperClient, IEarningChainGateway {
    using AssetLib for uint256;

    uint256 internal immutable ACCOUNTING_CHAIN_ID;
    address internal immutable ALLOCATOR;
    address internal immutable WITHDRAWAL_POLICY;

    /// @custom:storage-location erc7201:aave.storage.EarningChainGateway
    struct EarningChainGatewayStorage {
        uint256 balanceSnapshotNonce;
    }

    // keccak256(abi.encode(uint256(keccak256("aave.storage.EarningChainGateway")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT_EARNING_CHAIN_GATEWAY =
        0x5a762c9d6afe1d5e726c4d055708c9f75f61c70b417d4c903b07b242b2457100;

    function $EarningChainGateway() private pure returns (EarningChainGatewayStorage storage _storage) {
        assembly {
            _storage.slot := STORAGE_SLOT_EARNING_CHAIN_GATEWAY
        }
    }

    /// @dev Constructor.
    /// @param accountingChainId The Chain ID of the Accounting Chain.
    /// @param allocator Address of the Allocator contract.
    /// @param iouTokenManager Address of the IOU token manager contract used to mint and burn bridged or exchanged IOU tokens.
    /// @param transferHelper Address of the TransferHelper contract used to transfer assets across components.
    /// @param withdrawalPolicy Address of the WithdrawalPolicy contract used to check withdrawal policies and fees.
    constructor(
        uint256 accountingChainId,
        address allocator,
        address iouTokenManager,
        address transferHelper,
        address withdrawalPolicy
    ) TransferHelperClient(transferHelper) BaseChainGateway(iouTokenManager) {
        _disableInitializers();
        ACCOUNTING_CHAIN_ID = accountingChainId;
        ALLOCATOR = allocator;
        WITHDRAWAL_POLICY = withdrawalPolicy;
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

    function getAccountingChainId() external view returns (uint256) {
        return ACCOUNTING_CHAIN_ID;
    }

    /// @inheritdoc IEarningChainGateway
    function getAggregatedBalance() external view override returns (uint256) {
        return _getTotalAssetsInRay();
    }

    /// @inheritdoc IEarningChainGateway
    function sendBalanceUpdateWithFeePayer(IBridgeAdapter.BridgeParams memory bridgeParams)
        external
        payable
        override
        assertingTransferHelperBalanceFor(bridgeParams.feeToken)
    {
        address adapter = $BaseChainGateway()
        .defaultBridgeAdapter[ConstantsLib.ASSET_FOR_DATA_ONLY_BRIDGE][ACCOUNTING_CHAIN_ID];
        require(adapter != address(0), AdapterNotFound());

        _transferBridgeFeeToTransferHelper(bridgeParams);

        _sendCrossChainMessage(
            ACCOUNTING_CHAIN_ID,
            adapter,
            ConstantsLib.ASSET_FOR_DATA_ONLY_BRIDGE,
            0,
            _getBalanceSnapshotData(),
            bridgeParams
        );
    }

    /// @inheritdoc IEarningChainGateway
    function exchangeIouTokens(
        uint256 iouTokenAmountRay,
        address tokenOut,
        address tokenOutReceiver,
        IBridgeAdapter.BridgeParams memory bridgeParams,
        bytes memory data
    )
        external
        payable
        override
        assertingTransferHelperBalanceFor(bridgeParams.feeToken)
        assertingTransferHelperBalanceFor(tokenOut)
        returns (uint256)
    {
        require(iouTokenAmountRay > 0, ErrorsLib.ZeroAmount());
        IIouTokenManager(IOU_TOKEN_MANAGER).burnTokens(msg.sender, iouTokenAmountRay);

        address adapter =
            $BaseChainGateway().defaultBridgeAdapter[ConstantsLib.ASSET_FOR_DATA_ONLY_BRIDGE][ACCOUNTING_CHAIN_ID];
        require(adapter != address(0), AdapterNotFound());

        (uint256 withdrawalFeeRay,) =
            IWithdrawalPolicy(WITHDRAWAL_POLICY).previewWithdrawal(msg.sender, tokenOut, iouTokenAmountRay, data);
        uint256 amountOut = (iouTokenAmountRay - withdrawalFeeRay).rayToAssetDecimals(tokenOut);
        require(amountOut > 0, ErrorsLib.InsufficientAmountOut());
        IAllocator(ALLOCATOR).withdraw(tokenOut, amountOut);
        ITransferHelper(TRANSFER_HELPER).transfer(tokenOut, amountOut, tokenOutReceiver);

        _transferBridgeFeeToTransferHelper(bridgeParams);

        // Send data to synchronize the Accounting Chain's state.
        _sendBurnIouTokenMessage(iouTokenAmountRay, adapter, bridgeParams);

        return amountOut;
    }

    // This function is just needed to prevent StackTooDeep
    function _sendBurnIouTokenMessage(
        uint256 iouTokenAmountRay,
        address adapter,
        IBridgeAdapter.BridgeParams memory bridgeParams
    ) internal {
        // Prepare data to synchronize the Accounting Chain's state.
        bytes memory burnIouTokenMessageEncoded = abi.encode(
            IChainGateway.CrossChainMessage({
                messageType: IChainGateway.MessageType.BURN_IOU_TOKEN,
                data: abi.encode(
                    IChainGateway.BurnIouTokenMessage({
                        iouTokenAmountBurnedRay: iouTokenAmountRay,
                        chainBalanceSnapshotNonce: _getAndUpdateBalanceSnapshotNonce(),
                        balanceSnapshotTotalAssetsInRay: _getTotalAssetsInRay()
                    })
                )
            })
        );

        _sendCrossChainMessage(
            ACCOUNTING_CHAIN_ID,
            adapter,
            ConstantsLib.ASSET_FOR_DATA_ONLY_BRIDGE,
            0,
            burnIouTokenMessageEncoded,
            bridgeParams
        );
    }

    /// @inheritdoc IEarningChainGateway
    function pushFundsToAccountingChain(address asset, uint256 amount, IBridgeAdapter.BridgeParams memory bridgeParams)
        external
        payable
        override
        restricted
        assertingTransferHelperBalanceFor(bridgeParams.feeToken)
        assertingTransferHelperBalanceFor(asset)
    {
        require(amount > 0, ErrorsLib.ZeroAmount());
        // Transfer the bridge fee to the TransferHelper.
        _transferBridgeFeeToTransferHelper(bridgeParams);

        // Pull funds from liquidity into the TransferHelper.
        IAllocator(ALLOCATOR).withdraw(asset, amount);

        _returnFundsWithBalanceSnapshot(asset, amount, bridgeParams);
    }

    function _receiveFunds(IBridgeAdapter.BridgeAsset[] memory assets) internal override {
        for (uint256 i = 0; i < assets.length; i++) {
            IAllocator(ALLOCATOR).deposit(assets[i].asset, assets[i].amount);
        }
    }

    function _receiveData(uint256 sourceChainId, bytes memory data) internal override {
        _onlyAdapter(ConstantsLib.ASSET_FOR_DATA_ONLY_BRIDGE, sourceChainId);
        IChainGateway.CrossChainMessage memory crossChainMessage = abi.decode(data, (IChainGateway.CrossChainMessage));
        if (crossChainMessage.messageType == IChainGateway.MessageType.BRIDGE_IOU_TOKEN) {
            _bridgeIouTokenFromAccountingChain(crossChainMessage.data);
        } else {
            revert IChainGateway.InvalidMessageType();
        }
    }

    function _bridgeIouTokenFromAccountingChain(bytes memory data) internal {
        IChainGateway.IouTokenBridgeMessage memory iouTokenBridgeMessage =
            abi.decode(data, (IChainGateway.IouTokenBridgeMessage));
        IIouTokenManager(IOU_TOKEN_MANAGER).mintTokens(iouTokenBridgeMessage.recipient, iouTokenBridgeMessage.amount);
    }

    function _returnFundsWithBalanceSnapshot(
        address asset,
        uint256 amount,
        IBridgeAdapter.BridgeParams memory bridgeParams
    ) internal {
        address bridgeAdapter = $BaseChainGateway().defaultBridgeAdapter[asset][ACCOUNTING_CHAIN_ID];
        require(bridgeAdapter != address(0), AdapterNotFound());

        // Sends a single cross chain message with the asset and the balance snapshot. The bridge must support both
        // assets and arbitrary data.
        _sendCrossChainMessage(
            ACCOUNTING_CHAIN_ID, bridgeAdapter, asset, amount, _getBalanceSnapshotData(), bridgeParams
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
        return ++$EarningChainGateway().balanceSnapshotNonce;
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

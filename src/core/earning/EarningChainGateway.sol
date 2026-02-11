// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {
    ReentrancyGuardTransientUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";

import {BaseChainGateway} from "src/core/BaseChainGateway.sol";
import {LocalBalanceAggregator} from "src/core/LocalBalanceAggregator.sol";
import {IAllocator} from "src/interfaces/IAllocator.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {IEarningChainGateway} from "src/interfaces/IEarningChainGateway.sol";
import {IIouTokenManager} from "src/interfaces/IIouTokenManager.sol";
import {ITransferHelper} from "src/interfaces/ITransferHelper.sol";
import {IWithdrawalPolicy} from "src/interfaces/IWithdrawalPolicy.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {TransferHelperClient} from "src/misc/TransferHelperClient.sol";
import {Constants} from "src/types/Constants.sol";
import {Errors} from "src/types/Errors.sol";

/// @title EarningChainGateway
/// @notice Facilitates cross chain messaging with exactly one Accounting Chain.
contract EarningChainGateway is
    BaseChainGateway,
    TransferHelperClient,
    ReentrancyGuardTransientUpgradeable,
    LocalBalanceAggregator,
    IEarningChainGateway
{
    using AssetLib for uint256;

    uint256 internal immutable ACCOUNTING_CHAIN_ID;
    address internal immutable WITHDRAWAL_POLICY;

    /// @dev Constructor.
    /// @param accountingChainId The Chain ID of the Accounting Chain.
    /// @param allocator Address of the Allocator contract.
    /// @param priceOracle Address of the PriceOracle contract.
    /// @param iouTokenManager Address of the IOU token manager contract used to mint and burn bridged or exchanged IOU
    /// tokens.
    /// @param transferHelper Address of the TransferHelper contract used to transfer assets across components.
    /// @param withdrawalPolicy Address of the contract ensuring protocol's withdrawal requirements are met.
    constructor(
        uint256 accountingChainId,
        address allocator,
        address priceOracle,
        address iouTokenManager,
        address transferHelper,
        address withdrawalPolicy
    )
        TransferHelperClient(transferHelper)
        BaseChainGateway(iouTokenManager)
        LocalBalanceAggregator(allocator, priceOracle)
    {
        _disableInitializers();
        ACCOUNTING_CHAIN_ID = accountingChainId;
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

    function getBalanceSnapshot() external view returns (bytes memory) {
        return abi.encode(
            IChainGateway.BalanceSnapshot({totalBalanceInRay: _getLocalAggregatedBalance(), timestamp: block.timestamp})
        );
    }

    /// @inheritdoc IEarningChainGateway
    function getAggregatedBalance() external view override returns (uint256) {
        return _getLocalAggregatedBalance();
    }

    /// @inheritdoc IEarningChainGateway
    function exchangeIouTokens(
        uint256 iouTokenAmountRay,
        address assetOut,
        uint256 minAmountOut,
        address receiver,
        IBridgeAdapter.BridgeParams memory bridgeParams,
        bytes memory data
    )
        external
        payable
        override
        nonReentrant
        assertingTransferHelperBalanceFor(bridgeParams.feeToken)
        assertingTransferHelperBalanceFor(assetOut)
        returns (uint256)
    {
        require(iouTokenAmountRay > 0, Errors.ZeroAmount());
        IIouTokenManager(IOU_TOKEN_MANAGER).burnTokens(msg.sender, iouTokenAmountRay);

        uint256 amountOutRay = IWithdrawalPolicy(WITHDRAWAL_POLICY)
            .applyWithdrawalPolicy(
                IWithdrawalPolicy.WithdrawalRequest({
                    user: msg.sender, assetOut: assetOut, iouAmountRay: iouTokenAmountRay, data: data
                })
            );
        // Note: The rayToAssetDecimals conversion truncates, so the user may burn slightly more IOUs than the
        // exact RAY-equivalent of the assets received. This "dust" loss is at most 10^(27-decimals)-1 RAY per
        // withdrawal, which is economically negligible (e.g., <$0.000001 for 6-decimal stablecoins; it would take
        // >1,000,000 withdrawals to accumulate $1 of loss). The gas cost of preventing this (~1,600 gas for an extra
        // conversion) exceeds the value of the dust, so we accept this minor rounding in favor of the protocol.
        uint256 amountOut = amountOutRay.rayToAssetDecimals(assetOut);
        require(amountOut != 0 && amountOut >= minAmountOut, Errors.InsufficientAmountOut());
        IAllocator(ALLOCATOR).withdraw(assetOut, amountOut);

        _transferBridgeFeeToTransferHelper(bridgeParams);

        address adapter =
            $BaseChainGateway().defaultBridgeAdapter[Constants.ASSET_FOR_DATA_ONLY_BRIDGE][ACCOUNTING_CHAIN_ID];
        require(adapter != address(0), AdapterNotFound());

        // Send data to synchronize the Accounting Chain's state.
        _sendBurnIouTokenMessage(iouTokenAmountRay, adapter, bridgeParams);

        ITransferHelper(TRANSFER_HELPER).transfer(assetOut, amountOut, receiver);
        emit AssetOutflow(assetOut, amountOut);

        return amountOut;
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
        require(amount > 0, Errors.ZeroAmount());
        // Transfer the bridge fee to the TransferHelper.
        _transferBridgeFeeToTransferHelper(bridgeParams);

        // Pull funds from liquidity into the TransferHelper.
        IAllocator(ALLOCATOR).withdraw(asset, amount);

        _returnFunds(asset, amount, bridgeParams);
        emit AssetOutflow(asset, amount);
    }

    function _bridgeIouTokenFromAccountingChain(bytes memory data) internal {
        IChainGateway.IouTokenBridgeMessage memory iouTokenBridgeMessage =
            abi.decode(data, (IChainGateway.IouTokenBridgeMessage));
        IIouTokenManager(IOU_TOKEN_MANAGER).mintTokens(iouTokenBridgeMessage.recipient, iouTokenBridgeMessage.amount);
    }

    function _receiveData(
        uint256, // sourceChainId
        bytes memory data
    )
        internal
        override
    {
        IChainGateway.CrossChainMessage memory crossChainMessage = abi.decode(data, (IChainGateway.CrossChainMessage));
        if (crossChainMessage.messageType == IChainGateway.MessageType.BRIDGE_IOU_TOKEN) {
            _bridgeIouTokenFromAccountingChain(crossChainMessage.data);
        } else {
            revert IChainGateway.InvalidMessageType();
        }
    }

    function _receiveFunds(address asset, uint256 amount) internal override {
        IAllocator(ALLOCATOR).depositAllowIdle(asset, amount);
    }

    function _returnFunds(address asset, uint256 amount, IBridgeAdapter.BridgeParams memory bridgeParams) internal {
        address bridgeAdapter = $BaseChainGateway().defaultBridgeAdapter[asset][ACCOUNTING_CHAIN_ID];
        require(bridgeAdapter != address(0), AdapterNotFound());
        // Include the timestamp of when the message is published to the Accounting Chain, so that the Accounting Chain
        // can reference it to decide if Earning Chain's balance from the data feed captures the outflow of assets from
        // the Earning Chain.
        bytes memory returnFundsMessageEncoded = abi.encode(
            IChainGateway.CrossChainMessage({
                messageType: IChainGateway.MessageType.RETURN_FUNDS,
                data: abi.encode(IChainGateway.ReturnFundsMessage({timestamp: block.timestamp}))
            })
        );
        _sendCrossChainMessage(
            ACCOUNTING_CHAIN_ID, bridgeAdapter, asset, amount, returnFundsMessageEncoded, bridgeParams
        );
    }

    /// @dev This function is just needed to prevent StackTooDeep
    function _sendBurnIouTokenMessage(
        uint256 iouTokenAmountRay,
        address adapter,
        IBridgeAdapter.BridgeParams memory bridgeParams
    ) internal {
        // Prepare data to synchronize the Accounting Chain's state.
        // Include the timestamp of when the message is published to the Accounting Chain, so that the Accounting Chain
        // can reference it to decide if Earning Chain's balance from the data feed captures the IOU exchange i.e.
        // withdrawal of assets. This is to avoid decremening obligations by burning IOUs on the Accounting Chain while
        // the feed reflects a balance that still includes the withdrawn assets.
        bytes memory burnIouTokenMessageEncoded = abi.encode(
            IChainGateway.CrossChainMessage({
                messageType: IChainGateway.MessageType.BURN_IOU_TOKEN,
                data: abi.encode(
                    IChainGateway.BurnIouTokenMessage({
                        iouTokenAmountBurnedRay: iouTokenAmountRay, timestamp: block.timestamp
                    })
                )
            })
        );

        _sendCrossChainMessage(
            ACCOUNTING_CHAIN_ID,
            adapter,
            Constants.ASSET_FOR_DATA_ONLY_BRIDGE,
            0,
            burnIouTokenMessageEncoded,
            bridgeParams
        );
    }
}

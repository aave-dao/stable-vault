// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {
    ReentrancyGuardTransientUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";

import {BridgeParamsCodec} from "src/bridging/BridgeParamsCodec.sol";
import {BaseChainGateway} from "src/core/BaseChainGateway.sol";
import {LocalBalanceAggregator} from "src/core/LocalBalanceAggregator.sol";
import {IAllocator} from "src/interfaces/IAllocator.sol";
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
/// @author Aave Labs
/// @notice Facilitates cross chain messaging with exactly one Accounting Chain.
/// @custom:upgradeable
contract EarningChainGateway is
    BaseChainGateway,
    TransferHelperClient,
    ReentrancyGuardTransientUpgradeable,
    LocalBalanceAggregator,
    IEarningChainGateway
{
    using AssetLib for uint256;

    /// @notice Minimum destination gas limit required for the Accounting Chain to process a
    /// `BURN_IOU_TOKEN` message.
    /// @dev Set to 120k gas units based on gas-snapshot tests of the full destination execution path.
    /// The gas tests measured ~106.6k gas consumed and about 110k as the minimum exact-gas
    /// value that succeeds under `CallWithExactGas` delivery semantics. 120k adds around 10% safety margin on top.
    uint256 internal constant MIN_BURN_IOU_TOKEN_GAS_LIMIT = 120_000;

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
        require(withdrawalPolicy != address(0), Errors.ZeroAddress());
        require(accountingChainId != 0 && accountingChainId != block.chainid, Errors.InvalidParameter());
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

    function getAccountingChainId() external view returns (uint256) {
        return ACCOUNTING_CHAIN_ID;
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
        address bridgeAdapter,
        bytes calldata bridgeParamsEncoded,
        bytes memory data
    ) external payable virtual override nonReentrant assertingTransferHelperBalanceFor(assetOut) returns (uint256) {
        require(iouTokenAmountRay > 0, Errors.ZeroAmount());
        // Narrow gateway-side decode for one load-bearing safety invariant: the destination gas limit
        // must meet the minimum needed to successfully process a BURN_IOU_TOKEN message on the
        // Accounting Chain. Insufficient gasLimit would cause a destination revert with the CCIP
        // message dropped while IOUs are already burned locally — silent IOU loss with no compensating
        // effect on the Accounting Chain's obligation accounting. The adapter owns all fee handling;
        // this is the only gateway-side `BridgeParams` field read.
        require(
            BridgeParamsCodec.decode(bridgeParamsEncoded).gasLimit >= MIN_BURN_IOU_TOKEN_GAS_LIMIT,
            Errors.InvalidGasLimit()
        );
        _validateBridgeAdapterIsSupported(Constants.ASSET_FOR_DATA_ONLY_BRIDGE, ACCOUNTING_CHAIN_ID, bridgeAdapter);
        IIouTokenManager(IOU_TOKEN_MANAGER).burnTokens(msg.sender, iouTokenAmountRay);

        uint256 amountOut = _getWithdrawalAmountOut(iouTokenAmountRay, assetOut, minAmountOut, data);
        IAllocator(ALLOCATOR).withdraw(assetOut, amountOut);

        // Send data to synchronize the Accounting Chain's state.
        // NOTE: Oracle-bridge propagation asymmetry (by design). The Earning Chain balance reduction is reflected in
        // the next Chainlink oracle update (order of seconds via AssetOutflow event), while this BURN_IOU_TOKEN
        // message reducing obligations may take longer depending on the source chain. During this window, the
        // Accounting Chain sees reduced assets but unchanged IOU obligations, temporarily lowering available surplus.
        // This is the conservative
        // direction: _validateInboundMessageBlockNumber() on the Accounting Chain ensures the burn message is only
        // accepted after the oracle snapshot reflects this outflow, preventing the reverse (obligations reduced while
        // assets are still overstated). Operators are expected to account for this transient state when scheduling
        // claimSurplusInterest() calls.
        _sendBurnIouTokenMessage(iouTokenAmountRay, bridgeAdapter, msg.sender, bridgeParamsEncoded);

        ITransferHelper(TRANSFER_HELPER).transfer(assetOut, amountOut, receiver);
        emit AssetOutflow(assetOut, amountOut);

        return amountOut;
    }

    /// @inheritdoc IEarningChainGateway
    function pushFundsToAccountingChain(
        address asset,
        uint256 amount,
        address bridgeAdapter,
        bytes calldata bridgeParamsEncoded
    ) external payable override restricted assertingTransferHelperBalanceFor(asset) {
        require(amount > 0, Errors.ZeroAmount());
        // Pull funds from liquidity into the TransferHelper. Bridge-fee staging is owned by the adapter.
        IAllocator(ALLOCATOR).withdraw(asset, amount);
        _returnFunds(asset, amount, bridgeAdapter, msg.sender, bridgeParamsEncoded);
        emit AssetOutflow(asset, amount);
    }

    function _mintBridgedIouTokens(bytes memory data) internal {
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
            _mintBridgedIouTokens(crossChainMessage.data);
        } else {
            revert IChainGateway.InvalidMessageType();
        }
    }

    function _receiveFunds(address asset, uint256 amount) internal override {
        IAllocator(ALLOCATOR).depositAllowIdle(asset, amount);
    }

    function _returnFunds(
        address asset,
        uint256 amount,
        address bridgeAdapter,
        address feePayer,
        bytes calldata bridgeParamsEncoded
    ) internal {
        _validateBridgeAdapterIsSupported(asset, ACCOUNTING_CHAIN_ID, bridgeAdapter);
        // Include the message block number (and timestamp metadata) so the Accounting Chain can verify the chain
        // balance snapshot includes this asset outflow.
        bytes memory returnFundsMessageEncoded = abi.encode(
            IChainGateway.CrossChainMessage({
                messageType: IChainGateway.MessageType.RETURN_FUNDS,
                data: abi.encode(
                    IChainGateway.ReturnFundsMessage({timestamp: block.timestamp, blockNumber: block.number})
                )
            })
        );
        _sendCrossChainMessage(
            ACCOUNTING_CHAIN_ID, bridgeAdapter, asset, amount, returnFundsMessageEncoded, feePayer, bridgeParamsEncoded
        );
    }

    function _getWithdrawalAmountOut(
        uint256 iouTokenAmountRay,
        address assetOut,
        uint256 minAmountOut,
        bytes memory data
    ) internal returns (uint256) {
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
        return amountOut;
    }

    /// @dev This function is just needed to prevent StackTooDeep
    function _sendBurnIouTokenMessage(
        uint256 iouTokenAmountRay,
        address bridgeAdapter,
        address feePayer,
        bytes calldata bridgeParamsEncoded
    ) internal {
        // Prepare data to synchronize the Accounting Chain's state.
        // Include the message block number (and timestamp metadata) so the Accounting Chain can verify the chain
        // balance snapshot includes this IOU exchange outflow. This avoids decrementing obligations by burning IOUs on
        // the Accounting Chain while the feed still reflects pre-withdrawal balance.
        bytes memory burnIouTokenMessageEncoded = abi.encode(
            IChainGateway.CrossChainMessage({
                messageType: IChainGateway.MessageType.BURN_IOU_TOKEN,
                data: abi.encode(
                    IChainGateway.BurnIouTokenMessage({
                        iouTokenAmountBurnedRay: iouTokenAmountRay,
                        timestamp: block.timestamp,
                        blockNumber: block.number
                    })
                )
            })
        );

        _sendCrossChainMessage(
            ACCOUNTING_CHAIN_ID,
            bridgeAdapter,
            Constants.ASSET_FOR_DATA_ONLY_BRIDGE,
            0,
            burnIouTokenMessageEncoded,
            feePayer,
            bridgeParamsEncoded
        );
    }
}

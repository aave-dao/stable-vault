// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {
    ReentrancyGuardTransientUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";

import {BaseChainGateway} from "src/core/BaseChainGateway.sol";
import {LocalBalanceAggregator} from "src/core/LocalBalanceAggregator.sol";
import {IAllocator} from "src/interfaces/IAllocator.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {IEarningChainGateway} from "src/interfaces/IEarningChainGateway.sol";
import {IFundsBridgingPolicy} from "src/interfaces/IFundsBridgingPolicy.sol";
import {IIouTokenManager} from "src/interfaces/IIouTokenManager.sol";
import {IPolicyRegistry} from "src/interfaces/IPolicyRegistry.sol";
import {ITransferHelper} from "src/interfaces/ITransferHelper.sol";
import {IWithdrawalExecutionPolicy} from "src/interfaces/IWithdrawalExecutionPolicy.sol";
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
    address internal immutable POLICY_REGISTRY;

    // keccak256("aave.stable-vault.EarningChainGateway.policy.bridge")
    bytes32 internal constant BRIDGE_POLICY_ID = 0x537fb58e71f5b54dc09d8afff5cbf9bf5e630233f65f0531590f8cfa4a81bc6c;
    // keccak256("aave.stable-vault.EarningChainGateway.policy.withdrawal-execution")
    bytes32 internal constant WITHDRAWAL_EXECUTION_POLICY_ID =
        0xf213893b1e253163c05de458d1c9283d3155b096d439aab98ea90b491dce4bfb;

    /// @dev Constructor.
    /// @param accountingChainId The Chain ID of the Accounting Chain.
    /// @param allocator Address of the Allocator contract.
    /// @param priceOracle Address of the PriceOracle contract.
    /// @param iouTokenManager Address of the IOU token manager contract used to mint and burn bridged or exchanged IOU
    /// tokens.
    /// @param transferHelper Address of the TransferHelper contract used to transfer assets across components.
    /// @param policyRegistry Address of the PolicyRegistry contract used to look up policies by ID.
    constructor(
        uint256 accountingChainId,
        address allocator,
        address priceOracle,
        address iouTokenManager,
        address transferHelper,
        address policyRegistry
    )
        TransferHelperClient(transferHelper)
        BaseChainGateway(iouTokenManager)
        LocalBalanceAggregator(allocator, priceOracle)
    {
        require(policyRegistry != address(0), Errors.ZeroAddress());
        require(accountingChainId != 0 && accountingChainId != block.chainid, Errors.InvalidParameter());
        _disableInitializers();
        ACCOUNTING_CHAIN_ID = accountingChainId;
        POLICY_REGISTRY = policyRegistry;
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
        uint256 gasLimit,
        bytes calldata bridgeAdapterData,
        bytes memory withdrawalExecutionPolicyData
    ) external payable virtual override nonReentrant assertingTransferHelperBalanceFor(assetOut) returns (uint256) {
        require(iouTokenAmountRay > 0, Errors.ZeroAmount());
        // An insufficient destination gasLimit would cause the BURN_IOU_TOKEN message to be dropped while
        // IOUs are already burned locally — silent IOU loss with no compensating obligation reduction.
        require(gasLimit >= MIN_BURN_IOU_TOKEN_GAS_LIMIT, Errors.InvalidGasLimit());
        IIouTokenManager(IOU_TOKEN_MANAGER).burnTokens(msg.sender, iouTokenAmountRay);

        uint256 amountOut =
            _getWithdrawalAmountOut(iouTokenAmountRay, assetOut, minAmountOut, withdrawalExecutionPolicyData);
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
        _sendBurnIouTokenMessage(iouTokenAmountRay, bridgeAdapter, msg.sender, gasLimit, bridgeAdapterData);

        ITransferHelper(TRANSFER_HELPER).transfer(assetOut, amountOut, receiver);
        emit AssetOutflow(assetOut, amountOut);

        return amountOut;
    }

    /// @inheritdoc IEarningChainGateway
    function pushFundsToAccountingChain(
        address asset,
        uint256 amount,
        address bridgeAdapter,
        uint256 gasLimit,
        bytes calldata bridgeAdapterData,
        bytes calldata policyData
    ) external payable override restricted assertingTransferHelperBalanceFor(asset) {
        require(amount > 0, Errors.ZeroAmount());
        _applyFundsBridgingPolicy(ACCOUNTING_CHAIN_ID, bridgeAdapter, asset, amount, policyData);
        // Pull funds from liquidity into the TransferHelper.
        IAllocator(ALLOCATOR).withdraw(asset, amount);
        _returnFunds(asset, amount, bridgeAdapter, msg.sender, gasLimit, bridgeAdapterData);
        emit AssetOutflow(asset, amount);
    }

    function _receiveData(
        uint256, // sourceChainId
        bytes memory data
    )
        internal
        override
    {
        IChainGateway.CrossChainMessage memory crossChainMessage = abi.decode(data, (IChainGateway.CrossChainMessage));
        _receiveCrossChainMessage(crossChainMessage);
    }

    function _receiveFunds(address asset, uint256 amount) internal override {
        IAllocator(ALLOCATOR).depositAllowIdle(asset, amount);
    }

    function _receiveCrossChainMessage(IChainGateway.CrossChainMessage memory crossChainMessage) private {
        if (crossChainMessage.messageType == IChainGateway.MessageType.BRIDGE_IOU_TOKEN) {
            _mintBridgedIouTokens(crossChainMessage.data);
        } else {
            revert IChainGateway.InvalidMessageType();
        }
    }

    function _mintBridgedIouTokens(bytes memory data) private {
        IChainGateway.IouTokenBridgeMessage memory iouTokenBridgeMessage =
            abi.decode(data, (IChainGateway.IouTokenBridgeMessage));
        IIouTokenManager(IOU_TOKEN_MANAGER).mintTokens(iouTokenBridgeMessage.recipient, iouTokenBridgeMessage.amount);
    }

    function _returnFunds(
        address asset,
        uint256 amount,
        address bridgeAdapter,
        address feePayer,
        uint256 gasLimit,
        bytes calldata bridgeAdapterData
    ) private {
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
            ACCOUNTING_CHAIN_ID,
            bridgeAdapter,
            asset,
            amount,
            returnFundsMessageEncoded,
            feePayer,
            gasLimit,
            bridgeAdapterData
        );
    }

    function _getWithdrawalAmountOut(
        uint256 iouTokenAmountRay,
        address assetOut,
        uint256 minAmountOut,
        bytes memory withdrawalExecutionPolicyData
    ) private returns (uint256) {
        address policy = IPolicyRegistry(POLICY_REGISTRY).getPolicy(WITHDRAWAL_EXECUTION_POLICY_ID);
        require(policy != address(0), Errors.ZeroAddress());
        uint256 amountOutRay = IWithdrawalExecutionPolicy(policy)
            .applyWithdrawalExecutionPolicy(
                IWithdrawalExecutionPolicy.WithdrawalExecutionIntent({
                user: msg.sender,
                assetOut: assetOut,
                iouAmountRay: iouTokenAmountRay,
                policyData: withdrawalExecutionPolicyData
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

    function _applyFundsBridgingPolicy(
        uint256 destChainId,
        address bridgeAdapter,
        address asset,
        uint256 amount,
        bytes calldata policyData
    ) internal {
        address policy = IPolicyRegistry(POLICY_REGISTRY).getPolicy(BRIDGE_POLICY_ID);
        if (policy == address(0)) {
            return;
        }
        IFundsBridgingPolicy(policy)
            .applyFundsBridgingPolicy(
                IFundsBridgingPolicy.FundsBridgingIntent({
                caller: msg.sender,
                bridgeAdapter: bridgeAdapter,
                destChainId: destChainId,
                asset: asset,
                amount: amount,
                policyData: policyData
            })
            );
    }

    function _sendBurnIouTokenMessage(
        uint256 iouTokenAmountRay,
        address bridgeAdapter,
        address feePayer,
        uint256 gasLimit,
        bytes calldata bridgeAdapterData
    ) private {
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
            gasLimit,
            bridgeAdapterData
        );
    }
}

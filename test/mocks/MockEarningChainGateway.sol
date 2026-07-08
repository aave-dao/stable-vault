// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IEarningChainGateway} from "src/interfaces/IEarningChainGateway.sol";
import {ITransferHelper} from "src/interfaces/ITransferHelper.sol";
import {Constants} from "src/types/Constants.sol";

contract MockEarningChainGateway is IEarningChainGateway {
    address internal immutable TRANSFER_HELPER;

    constructor(address transferHelper) {
        TRANSFER_HELPER = transferHelper;
    }

    function getIouTokenManager() external view returns (address) {}

    function getAggregatedBalance() external view returns (uint256) {}

    function sendBalanceUpdateWithFeePayer(bytes calldata bridgeAdapterData) external payable {}

    function pushFundsToAccountingChain(
        address asset,
        uint256 amount,
        address bridgeAdapter,
        uint256 gasLimit,
        bytes calldata bridgeAdapterData,
        bytes calldata policyData
    ) external payable {}

    function exchangeIouTokens(
        uint256 iouTokenAmountRay,
        address assetOut,
        uint256 minAmountOut,
        address receiver,
        address bridgeAdapter,
        uint256 gasLimit,
        bytes calldata bridgeAdapterData,
        bytes memory policyData
    ) external payable returns (uint256) {}

    function sendPushFundsToChainMessage(
        address asset,
        uint256 amount,
        uint256 targetChainId,
        address bridgeAdapter,
        address feePayer,
        uint256 gasLimit,
        bytes calldata bridgeAdapterData
    ) external payable {}

    function addFundsBridgeAdapter(address asset, uint256 chainId, address bridgeAdapter) external {}

    function removeFundsBridgeAdapter(address asset, uint256 chainId, address bridgeAdapter) external {}

    function addDataOnlyBridgeAdapter(uint256 chainId, address bridgeAdapter) external {}

    function initiateDataOnlyBridgeAdapterRemoval(uint256 chainId, address bridgeAdapter)
        external
        returns (bytes32 removalId)
    {}

    function finalizeDataOnlyBridgeAdapterRemoval(uint256 chainId, address bridgeAdapter, bytes32 removalId) external {}

    /// @dev Called by Bridge Adapters which use the TransferHelper modifiers that assert no funds left in the
    /// TransferHelper.
    function receiveMessage(uint256 sourceChainId, address asset, uint256 amount, bytes memory data) external {
        (sourceChainId, data);
        if (asset != Constants.ASSET_FOR_DATA_ONLY_BRIDGE && amount > 0) {
            ITransferHelper(TRANSFER_HELPER).transfer(asset, amount, address(this));
        }
    }

    function sendBridgeIouTokenMessageWithFeePayer(
        uint256 destinationChainId,
        address iouTokenRecipient,
        uint256 iouTokenAmountRay,
        address bridgeAdapter,
        address feePayer,
        uint256 gasLimit,
        bytes calldata bridgeAdapterData
    ) external payable {}
}

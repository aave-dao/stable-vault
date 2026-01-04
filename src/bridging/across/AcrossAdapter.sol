// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {EfficientHashLib} from "@solady/utils/EfficientHashLib.sol";

import {BaseBridgeAdapter} from "src/bridging/BaseBridgeAdapter.sol";
import {IAcrossSpokePoolV3} from "src/bridging/across/IAcrossSpokePoolV3.sol";
import {IAcrossV3Receiver} from "src/bridging/across/IAcrossV3Receiver.sol";
import {IAcrossBridgeAdapter} from "src/interfaces/IAcrossBridgeAdapter.sol";
import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {ITransferHelper} from "src/interfaces/ITransferHelper.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {Errors} from "src/types/Errors.sol";

/// @title AcrossAdapter
/// @author Aave Labs
/// @notice Adapter for sending and receiving messages via Across.
/// @dev Requires tokens to be bridged with/without an arbitrary message. Fees are paid in the token being bridged.
contract AcrossAdapter is BaseBridgeAdapter, IAcrossBridgeAdapter, IERC165 {
    using SafeERC20 for IERC20;
    using AssetLib for uint256;

    /// @notice The representation of a message to bridge tokens/data with Across.
    /// @param sourceChainId The chain id of the source chain where deposit was made.
    /// @param messageId The message ID generated for the message used to trace
    /// the message from source to destination.
    struct AcrossPacket {
        uint256 sourceChainId;
        bytes32 messageId;
    }

    bool internal immutable IS_ACCOUNTING_CHAIN;
    address internal immutable ACROSS_SPOKE_POOL;
    address internal immutable ASSET_REGISTRY;
    mapping(address localToken => mapping(uint256 destinationChainId => address destinationChainToken)) internal
        _destinationChainAsset;
    mapping(bytes32 messageId => bool processed) internal _publishedMessageIds;

    modifier onlySpokePool() {
        require(msg.sender == ACROSS_SPOKE_POOL, OnlySpokePool());
        _;
    }

    /// @dev Constructor.
    /// @param isAccountingChain Boolean indicating whether the local chain is the Accounting Chain.
    /// @param acrossSpokePool Address of the Across Spoke Pool.
    /// @param accessManager Address of the IAccessManager contract used for handling access control.
    /// @param gateway Address of the Gateway contract.
    /// @param transferHelper Address of the TransferHelper.
    /// @param assetRegistry Address of the AssetRegistry contract used to check if a received asset is registered.
    constructor(
        bool isAccountingChain,
        address acrossSpokePool,
        address accessManager,
        address gateway,
        address transferHelper,
        address assetRegistry
    ) BaseBridgeAdapter(accessManager, gateway, transferHelper) {
        IS_ACCOUNTING_CHAIN = isAccountingChain;
        ACROSS_SPOKE_POOL = acrossSpokePool;
        ASSET_REGISTRY = assetRegistry;
    }

    /// @inheritdoc IAcrossBridgeAdapter
    function getSpokePool() external view override returns (address) {
        return ACROSS_SPOKE_POOL;
    }

    /// @inheritdoc IAcrossBridgeAdapter
    function getDestinationChainAsset(address localAsset, uint256 destinationChainId)
        external
        view
        override
        returns (address)
    {
        return _destinationChainAsset[localAsset][destinationChainId];
    }

    function supportsInterface(bytes4 interfaceId) public pure virtual override returns (bool) {
        return interfaceId == type(IAcrossV3Receiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @inheritdoc IBridgeAdapter
    function publishMessageToChainWithFeePayer(
        uint256 destinationChainId,
        BridgeAsset[] memory assets,
        bytes memory data,
        IBridgeAdapter.BridgeParams memory bridgeParams
    ) external payable override(BaseBridgeAdapter, IBridgeAdapter) onlyGateway {
        // Bridging high-risk/sensitive data cross chain via Across should not be trusted. Using an off-chain signer and
        // validating the signature on the destination chain is an option, but puts a strong trust assumption on the
        // signer.
        require(data.length == 0, ArbitraryDataNotAllowed());
        // Across only supports bridging one token at a time.
        // Across can not bridge data alone (it must be accompanied by a token).
        require(assets.length == 1, InvalidAssetsLength(1, assets.length));
        // Across requires an asset to be bridged as that is how fees are paid.
        require(assets[0].amount > 0, Errors.ZeroAmount());

        address asset = assets[0].asset;
        // The fee is paid as a percentage of the input token amount.
        require(bridgeParams.feeToken == asset, InvalidFeeToken(asset, bridgeParams.feeToken));
        uint256 amountToBridge = assets[0].amount;
        uint256 totalInputAmount = amountToBridge + bridgeParams.feeAmount;
        _publishMessage(destinationChainId, asset, totalInputAmount, amountToBridge, bridgeParams.data);
    }

    /// @inheritdoc IAcrossV3Receiver
    function handleV3AcrossMessage(
        address token,
        uint256 amount,
        address, // relayer
        bytes memory message
    )
        external
        override
        onlySpokePool
    {
        AcrossPacket memory acrossPacket = abi.decode(message, (AcrossPacket));
        emit MessageReceived(acrossPacket.messageId);

        if (IS_ACCOUNTING_CHAIN) {
            // Do not update snapshot state if an asset will be rejected by the Allocator.
            require(IAssetRegistry(ASSET_REGISTRY).isDepositToAllocatorAllowed(token), Errors.UnsupportedAsset(token));
            bytes memory decrementBalanceSnapshotMessage = abi.encode(
                IChainGateway.CrossChainMessage({
                    messageType: IChainGateway.MessageType.DECREMENT_BALANCE_SNAPSHOT,
                    data: abi.encode(
                        IChainGateway.DecrementBalanceSnapshotMessage({amountRay: amount.assetDecimalsToRay(token)})
                    )
                })
            );
            // This call must succeed before processing the received funds.
            // If the message processing fails, but the funds receiving succeeds the state of the Accounting Chain can
            // reflect a duplication of assets (snapshot stays undecremented while funds get reflected in the
            // Allocator's balance).
            IChainGateway(GATEWAY)
                .receiveMessage(
                    acrossPacket.sourceChainId, new IBridgeAdapter.BridgeAsset[](0), decrementBalanceSnapshotMessage
                );
        }

        try this.processReceivedFunds(token, amount) {}
        catch (bytes memory err) {
            emit TokenReceptionFailed(acrossPacket.messageId, acrossPacket.sourceChainId, token, amount);
            emit BridgedFundsProcessingFailed(
                acrossPacket.messageId, acrossPacket.sourceChainId, abi.encode(acrossPacket), err
            );
        }
    }

    function processReceivedFunds(address asset, uint256 amount) external onlySelf {
        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: asset, amount: amount});
        _processReceivedFunds(assets);
    }

    //////////////////////////////// RESTRICTED FUNCTIONS ////////////////////////////////

    /// @inheritdoc BaseBridgeAdapter
    /// @dev This function should not be called if funds have been delivered, but arbitrary message handling via
    /// handleV3AcrossMessage() is still pending or will never be executed because the data has been intentionally
    /// omitted by the relayer.
    /// @dev A malicious relayer could intentionally omit the AcrossPacket data and have funds
    /// arrive on the adapter contract then proceed to invoke the overriden `replayFundsReceiving` function which would
    /// cause the Accounting Chain to double count the amount (the snapshot is not decremented). The malicious relayer
    /// would not receive a refund if the message is omitted, but it is not safe to assume malicious actors are
    /// economically rational.
    function replayFundsReceiving(BridgeAsset[] memory assets)
        external
        override(BaseBridgeAdapter, IBridgeAdapter)
        restricted
    {
        _processReceivedFunds(assets);
    }

    /// @inheritdoc IAcrossBridgeAdapter
    function setDestinationChainAssets(AssetMapping[] memory assetMappings) external restricted {
        for (uint256 i = 0; i < assetMappings.length; i++) {
            _destinationChainAsset[assetMappings[i].localAsset][assetMappings[i].destinationChainId] =
            assetMappings[i].destinationChainAsset;
            emit DestinationChainAssetSet(
                assetMappings[i].localAsset, assetMappings[i].destinationChainId, assetMappings[i].destinationChainAsset
            );
        }
    }

    //////////////////////////////// INTERNAL FUNCTIONS ////////////////////////////////

    function _publishMessage(
        uint256 destinationChainId,
        address asset,
        uint256 inputAmount,
        uint256 outputAmount,
        bytes memory acrossBridgeParamsData
    ) internal {
        AcrossBridgeParams memory acrossBridgeParams = abi.decode(acrossBridgeParamsData, (AcrossBridgeParams));
        require(
            acrossBridgeParams.spokePoolAddress == ACROSS_SPOKE_POOL,
            InvalidSpokePool(ACROSS_SPOKE_POOL, acrossBridgeParams.spokePoolAddress)
        );
        require(acrossBridgeParams.fillDeadline >= block.timestamp, FillDeadlineExpired());
        _prepareFundsToBridge(asset, inputAmount);
        _depositToSpokePool(destinationChainId, asset, inputAmount, outputAmount, acrossBridgeParams);
    }

    function _prepareFundsToBridge(address asset, uint256 inputAmount) internal {
        // Pull the funds to bridge from the TransferHelper.
        // The fee amount should have been pulled from the fee payer into the TransferHelper.
        // The actual output amount would have been pushed from the Allocator into the TransferHelper.
        ITransferHelper(TRANSFER_HELPER).pull(asset, inputAmount);

        // Approve the spoke pool to spend the token.
        IERC20(asset).forceApprove(ACROSS_SPOKE_POOL, inputAmount);
    }

    function _depositToSpokePool(
        uint256 destinationChainId,
        address asset,
        uint256 inputAmount,
        uint256 outputAmount,
        AcrossBridgeParams memory acrossBridgeParams
    ) internal {
        bytes32 messageId = _buildMessageId(destinationChainId, asset, inputAmount);
        require(!_publishedMessageIds[messageId], MessageAlreadyPublished());
        _publishedMessageIds[messageId] = true;
        bytes memory packet = abi.encode(AcrossPacket({sourceChainId: block.chainid, messageId: messageId}));

        address destinationChainAsset = _destinationChainAsset[asset][destinationChainId];
        require(destinationChainAsset != address(0), UnsupportedDestinationChainAsset(asset, destinationChainId));

        IAcrossSpokePoolV3(ACROSS_SPOKE_POOL)
            .depositV3(
                address(this),
                _destinationChainAdapterOf[destinationChainId],
                asset,
                destinationChainAsset,
                inputAmount,
                outputAmount,
                destinationChainId,
                acrossBridgeParams.exclusiveRelayer,
                acrossBridgeParams.quoteTimestamp,
                acrossBridgeParams.fillDeadline,
                acrossBridgeParams.exclusivityDeadline,
                packet
            );
        emit MessagePublished(messageId);
    }

    /// @dev Builds a message ID for a published message which limits bridging the same asset and amount to the same
    /// destination chain more than once per source chain block.
    function _buildMessageId(uint256 destinationChainId, address asset, uint256 amount)
        internal
        view
        returns (bytes32)
    {
        return EfficientHashLib.hash(
            abi.encode(block.chainid, block.timestamp, address(this), destinationChainId, asset, amount)
        );
    }
}

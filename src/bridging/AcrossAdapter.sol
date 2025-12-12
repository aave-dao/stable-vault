// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {EfficientHashLib} from "@solady/utils/EfficientHashLib.sol";

import {BaseBridgeAdapter} from "src/bridging/BaseBridgeAdapter.sol";
import {IAcrossSpokePoolV3} from "src/dependencies/across/IAcrossSpokePoolV3.sol";
import {IAcrossV3Receiver} from "src/dependencies/across/IAcrossV3Receiver.sol";
import {IAcrossBridgeAdapter} from "src/interfaces/IAcrossBridgeAdapter.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {ITransferHelper} from "src/interfaces/ITransferHelper.sol";
import {ErrorsLib} from "src/libraries/ErrorsLib.sol";

/// @title AcrossAdapter
/// @author Aave Labs
/// @notice Adapter for sending and receiving messages via Across.
/// @dev Requires tokens to be bridged with/without an arbitrary message. Fees are paid in the token being bridged.
/// @dev Signature verification is not performed if no arbitrary message is bridged. This assumes the Earning Chain will
/// always include a snapshot message with funds bridged to the Accounting Chain.
contract AcrossAdapter is BaseBridgeAdapter, EIP712, IAcrossBridgeAdapter, IERC165 {
    using SafeERC20 for IERC20;

    /// @notice The representation of a message to bridge tokens/data with Across.
    /// @param message The underlying cross-chain message data passed to the Gateway contract.
    /// @param sourceChainId The chain id of the source chain where deposit was made.
    /// @param signatureNonce Nonce used to add entropy to the signing payload (gets consumed on the destination chain).
    /// @param signatureExpirationTs Valid until timestamp for the signature (if ts is expired by the time validation
    /// occurs on destination chain, the signature is invalid).
    /// @param signature Signature from the signer over bridged
    /// message content's typed data hash which gets verified on
    /// the destination chain's AcrossAdapter.
    /// @param messageId The message ID generated for the message used to trace
    /// the message from source to destination.
    struct AcrossPacket {
        bytes message;
        uint256 sourceChainId;
        uint256 signatureNonce;
        uint256 signatureExpirationTs;
        bytes signature;
        bytes32 messageId;
    }

    // EIP-712 typeHash:
    // keccak256("AcrossMessage(uint256 sourceChainId,uint256 signatureNonce,uint256 signatureExpirationTs,address
    // asset,uint256 amount)").
    bytes32 public constant ACROSS_MESSAGE_TYPEHASH =
        0x1d8d0d4179c7761b145b81435f1b1fd5cf68b155e84e1567c795ff1e37405699;

    address internal immutable ACROSS_SPOKE_POOL;
    mapping(address account => bool isSigner) internal _isSigner;
    mapping(address signer => mapping(uint256 nonce => bool consumed)) internal _wasNonceConsumed;

    modifier onlySpokePool() {
        require(msg.sender == ACROSS_SPOKE_POOL, OnlySpokePool());
        _;
    }

    /// @dev Constructor.
    /// @param acrossSpokePool Address of the Across Spoke Pool.
    /// @param accessManager Address of the IAccessManager contract used for handling access control.
    /// @param gateway Address of the Gateway contract.
    /// @param transferHelper Address of the TransferHelper.
    constructor(address acrossSpokePool, address accessManager, address gateway, address transferHelper)
        BaseBridgeAdapter(accessManager, gateway, transferHelper)
        EIP712("AcrossAdapter", "1")
    {
        ACROSS_SPOKE_POOL = acrossSpokePool;
    }

    /// @inheritdoc IAcrossBridgeAdapter
    function getSpokePool() external view override returns (address) {
        return ACROSS_SPOKE_POOL;
    }

    /// @inheritdoc IAcrossBridgeAdapter
    function getSigningPayload(
        uint256 sourceChainId,
        uint256 signatureNonce,
        uint256 signatureExpirationTs,
        address tokenToBridge,
        uint256 amountToBridge
    ) external view override returns (bytes32) {
        return _encodeSigningPayload(
            sourceChainId, signatureNonce, signatureExpirationTs, tokenToBridge, amountToBridge
        );
    }

    /// @inheritdoc IAcrossBridgeAdapter
    function isNonceUsed(address signer, uint256 nonce) external view override returns (bool) {
        return _wasNonceConsumed[signer][nonce];
    }

    /// @notice Getter for whether a signer is whitelisted.
    /// @param signer Address of the signer to check.
    /// @return isSigner Whether the signer is whitelisted.
    function isSigner(address signer) external view returns (bool) {
        return _isSigner[signer];
    }

    function supportsInterface(bytes4 interfaceId) public pure virtual override returns (bool) {
        return interfaceId == type(IAcrossV3Receiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    /// @notice Allows a whitelisted signer to invalidate their own nonce.
    /// @dev Useful for cancelling a signed message before it's used.
    /// @param signer The signer whose nonce to invalidate (must be msg.sender).
    /// @param nonce The nonce to invalidate.
    function invalidateNonce(address signer, uint256 nonce) external {
        require(msg.sender == signer, ErrorsLib.NotAuthorized());
        require(_isSigner[signer], ErrorsLib.NotAuthorized());
        _consumeNonce(signer, nonce);
    }

    /// @inheritdoc IBridgeAdapter
    function publishMessageToChainWithFeePayer(
        uint256 destinationChainId,
        BridgeAsset[] memory assets,
        bytes memory data,
        IBridgeAdapter.BridgeParams memory bridgeParams
    ) external payable override(BaseBridgeAdapter, IBridgeAdapter) onlyGateway {
        // Across only supports bridging one token at a time.
        // Across can not bridge data alone (it must be accompanied by a token).
        require(assets.length == 1, InvalidAssetsLength(1, assets.length));
        // Across requires an asset to be bridged as that is how fees are paid.
        require(assets[0].amount > 0, ErrorsLib.ZeroAmount());

        address asset = assets[0].asset;
        // The fee is paid as a percentage of the input token amount.
        require(bridgeParams.feeToken == asset, InvalidFeeToken(asset, bridgeParams.feeToken));
        uint256 amountToBridge = assets[0].amount;
        uint256 totalInputAmount = amountToBridge + bridgeParams.feeAmount;
        _publishMessage(destinationChainId, asset, totalInputAmount, amountToBridge, data, bridgeParams.data);
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

        bytes memory underlyingMessage = acrossPacket.message;
        if (underlyingMessage.length > 0) {
            require(acrossPacket.signatureExpirationTs >= block.timestamp, ErrorsLib.SignatureTimestampExpired());
            address signer = _recoverSigner(
                acrossPacket.signature,
                acrossPacket.sourceChainId,
                acrossPacket.signatureNonce,
                acrossPacket.signatureExpirationTs,
                token,
                amount
            );
            require(_isSigner[signer], ErrorsLib.InvalidSignature());
            _consumeNonce(signer, acrossPacket.signatureNonce);
            // This is required to succeed before handling received funds. We should not handle funds if a message
            // containing data for a state update is not successfully processed.
            IChainGateway(GATEWAY)
                .receiveMessage(acrossPacket.sourceChainId, new IBridgeAdapter.BridgeAsset[](0), underlyingMessage);
        }

        try this.processReceivedFunds(token, amount) {}
        catch (bytes memory err) {
            emit TokenReceptionFailed(acrossPacket.sourceChainId, token, amount);
            emit BridgedFundsProcessingFailed(acrossPacket.sourceChainId, abi.encode(acrossPacket), err);
        }
    }

    function processReceivedFunds(address asset, uint256 amount) external onlySelf {
        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: asset, amount: amount});
        _processReceivedFunds(assets);
    }

    //////////////////////////////// RESTRICTED FUNCTIONS ////////////////////////////////

    /// @notice Sets the signer to be used for signature verification.
    /// @param signer Address of the signer to set.
    /// @param whitelistedSigner Whether the signer is enabled for signature verification.
    function setSigner(address signer, bool whitelistedSigner) external restricted {
        _isSigner[signer] = whitelistedSigner;
        emit SignerUpdated(signer, whitelistedSigner);
    }

    /// @inheritdoc BaseBridgeAdapter
    /// @dev This function should not be called if funds have been delivered, but arbitrary message handling via
    /// handleV3AcrossMessage() is still pending.
    /// @dev Has restricted modifier because it is possible for a balance
    /// snapshot message to arrive in a separate transaction after the funds have been received on the adapter.
    /// @dev If funds are received from Earning Chain to Accounting Chain and pushed into the Allocator while the
    /// balance snapshot message still has not been processed then this will lead to the Accounting Chain's balance
    /// reflecting a duplicate amount of the funds that were received.
    function replayFundsReceiving(BridgeAsset[] memory assets)
        public
        override(BaseBridgeAdapter, IBridgeAdapter)
        restricted
    {
        super.replayFundsReceiving(assets);
    }

    //////////////////////////////// INTERNAL FUNCTIONS ////////////////////////////////

    function _recoverSigner(
        bytes memory signature,
        uint256 sourceChainId,
        uint256 signatureNonce,
        uint256 signatureExpirationTs,
        address asset,
        uint256 amount
    ) internal view returns (address) {
        bytes32 payload = _encodeSigningPayload(sourceChainId, signatureNonce, signatureExpirationTs, asset, amount);
        return ECDSA.recover(payload, signature);
    }

    function _encodeSigningPayload(
        uint256 sourceChainId,
        uint256 signatureNonce,
        uint256 signatureExpirationTs,
        address asset,
        uint256 amount
    ) internal view returns (bytes32) {
        // Note _hashTypedDataV4() reads `block.chainid`.
        bytes32 typedDataHash = EfficientHashLib.hash(
            abi.encode(ACROSS_MESSAGE_TYPEHASH, sourceChainId, signatureNonce, signatureExpirationTs, asset, amount)
        );
        return _hashTypedDataV4(typedDataHash);
    }

    function _consumeNonce(address signer, uint256 nonce) internal {
        require(!_wasNonceConsumed[signer][nonce], ErrorsLib.SignatureNonceAlreadyConsumed(signer, nonce));
        _wasNonceConsumed[signer][nonce] = true;
        emit NonceConsumed(signer, nonce);
    }

    function _publishMessage(
        uint256 destinationChainId,
        address asset,
        uint256 inputAmount,
        uint256 outputAmount,
        bytes memory bridgeData,
        bytes memory acrossBridgeParamsData
    ) internal {
        AcrossBridgeParams memory acrossBridgeParams = abi.decode(acrossBridgeParamsData, (AcrossBridgeParams));
        require(
            acrossBridgeParams.spokePoolAddress == ACROSS_SPOKE_POOL,
            InvalidSpokePool(ACROSS_SPOKE_POOL, acrossBridgeParams.spokePoolAddress)
        );
        require(acrossBridgeParams.signatureExpirationTs >= block.timestamp, ErrorsLib.SignatureTimestampExpired());
        require(acrossBridgeParams.fillDeadline >= block.timestamp, FillDeadlineExpired());
        _prepareFundsToBridge(asset, inputAmount);
        _depositToSpokePool(destinationChainId, asset, inputAmount, outputAmount, bridgeData, acrossBridgeParams);
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
        bytes memory bridgeData,
        AcrossBridgeParams memory acrossBridgeParams
    ) internal {
        bytes32 messageId = EfficientHashLib.hash(acrossBridgeParams.signature);
        bytes memory packet = abi.encode(
            AcrossPacket({
                message: bridgeData,
                sourceChainId: block.chainid,
                signatureNonce: acrossBridgeParams.signatureNonce,
                signatureExpirationTs: acrossBridgeParams.signatureExpirationTs,
                signature: acrossBridgeParams.signature,
                messageId: messageId
            })
        );

        IAcrossSpokePoolV3(ACROSS_SPOKE_POOL)
            .depositV3(
                address(this),
                _destinationChainAdapterOf[destinationChainId],
                asset,
                asset,
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
}

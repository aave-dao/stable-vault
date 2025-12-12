// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IAcrossV3Receiver} from "src/bridging/across/IAcrossV3Receiver.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";

/// @title IAcrossBridgeAdapter
/// @author Aave Labs
/// @notice Interface for the AcrossAdapter contract.
interface IAcrossBridgeAdapter is IBridgeAdapter, IAcrossV3Receiver {
    /// @notice Thrown when the fill deadline is expired before deposit is made.
    /// @custom:selector 0x89503ebb
    error FillDeadlineExpired();

    /// @notice Thrown when the number of assets is not expected.
    /// @custom:selector 0x84d9d915
    error InvalidAssetsLength(uint256 expected, uint256 actual);

    /// @notice Thrown when the fee token is not expected.
    /// @custom:selector 0x574c3180
    error InvalidFeeToken(address expected, address actual);

    /// @notice Thrown when the spoke pool address is not expected.
    /// @custom:selector 0xd5148c8b
    error InvalidSpokePool(address expected, address actual);

    /// @notice Thrown when the caller is not the Across Spoke Pool.
    /// @custom:selector 0xc62b9196
    error OnlySpokePool();

    /// @notice Emitted when a signer is updated.
    /// @param signer Address of the signer.
    /// @param isSigner Whether the signer is enabled for signature verification.
    event SignerUpdated(address indexed signer, bool isSigner);

    /// @notice Emitted when a nonce is consumed.
    /// @param signer Address of the signer.
    /// @param nonce The signer's nonce that was consumed.
    event NonceConsumed(address indexed signer, uint256 nonce);

    /// @notice The parameters for the Across bridge adapter.
    /// @param spokePoolAddress Address of the Across Spoke Pool.
    /// @param quoteTimestamp Timestamp of the quote.
    /// @param fillDeadline Deadline for the fill.
    /// @param exclusiveRelayer Address of the exclusive relayer.
    /// @param exclusivityDeadline Deadline for the exclusivity.
    /// @param signatureNonce Nonce used to add entropy to the signing payload (gets consumed on the destination chain).
    /// @param signatureExpirationTs Valid until timestamp for the signature (if ts is expired by the time validation
    /// occurs on destination chain, the signature is invalid). @param signature Signature of from the signer over
    /// bridged message content's typed data hash. The signer must be
    /// whitelisted on the destination chain's AcrossAdapter.
    struct AcrossBridgeParams {
        address spokePoolAddress;
        uint32 quoteTimestamp;
        uint32 fillDeadline;
        address exclusiveRelayer;
        uint32 exclusivityDeadline;
        uint256 signatureNonce;
        uint256 signatureExpirationTs;
        bytes signature;
    }

    /// @notice Getter for the address of the Across Spoke Pool.
    /// @return address of the Across Spoke Pool.
    function getSpokePool() external view returns (address);

    /// @notice Getter for the signing payload.
    /// @dev Signer should call this on the destination chain to obtain the signature broadcasted on the source chain.
    /// @param sourceChainId Chain id of the source chain where deposit was made.
    /// @param signatureNonce Nonce used to add entropy to the signing payload (consumed on the destination chain).
    /// @param signatureExpirationTs Valid until timestamp for the signature (if ts is expired by the time validation
    /// occurs on destination chain, the signature is invalid).
    /// @param tokenToBridge Address of the token being bridged.
    /// @param amountToBridge Amount of the token being bridged (excluding fees).
    /// @return bytes32 hash of typed data to be signed.
    function getSigningPayload(
        uint256 sourceChainId,
        uint256 signatureNonce,
        uint256 signatureExpirationTs,
        address tokenToBridge,
        uint256 amountToBridge
    ) external view returns (bytes32);

    /// @notice Getter for whether a nonce has been consumed by a signer.
    /// @param signer Address of the signer to check.
    /// @param nonce The nonce to check.
    /// @return used Whether the nonce has been used.
    function isNonceUsed(address signer, uint256 nonce) external view returns (bool);
}

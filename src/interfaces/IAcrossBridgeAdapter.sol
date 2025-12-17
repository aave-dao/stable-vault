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

    /// @notice Thrown when the message ID has already been published.
    /// @custom:selector 0x8a2f440d
    error MessageAlreadyPublished();

    /// @notice Thrown when the caller is not the Across Spoke Pool.
    /// @custom:selector 0xc62b9196
    error OnlySpokePool();

    /// @notice Thrown when the destination chain asset address is not supported for an input asset.
    /// @custom:selector 0xfc00c614
    error UnsupportedDestinationChainAsset(address localAsset, uint256 destinationChainId);

    /// @notice Emitted when the mapping of an asset on the local chain to an asset on the destination chain is set.
    /// @param localAsset Address of the asset on the local chain.
    /// @param destinationChainId Chain id of the destination chain.
    /// @param destinationChainAsset Address of the asset on the destination chain.
    event DestinationChainAssetSet(
        address indexed localAsset, uint256 indexed destinationChainId, address indexed destinationChainAsset
    );

    /// @notice The parameters for the Across bridge adapter.
    /// @param spokePoolAddress Address of the Across Spoke Pool.
    /// @param quoteTimestamp Timestamp of the quote.
    /// @param fillDeadline Deadline for the fill.
    /// @param exclusiveRelayer Address of the exclusive relayer.
    /// @param exclusivityDeadline Deadline for the exclusivity.
    struct AcrossBridgeParams {
        address spokePoolAddress;
        uint32 quoteTimestamp;
        uint32 fillDeadline;
        address exclusiveRelayer;
        uint32 exclusivityDeadline;
    }

    /// @notice The mapping of a token on the local chain to a token on the destination chain.
    /// @param localAsset Address of the asset on the local chain.
    /// @param destinationChainAsset Address of the asset on the destination chain.
    /// @param destinationChainId Chain id of the destination chain.
    struct AssetMapping {
        address localAsset;
        address destinationChainAsset;
        uint256 destinationChainId;
    }

    /// @notice Getter for the address of the Across Spoke Pool.
    /// @return address of the Across Spoke Pool.
    function getSpokePool() external view returns (address);

    /// @notice Getter for the mapping of an asset on the local chain to an asset on the destination chain.
    /// @param localAsset Address of the asset on the local chain.
    /// @param destinationChainId Chain id of the destination chain.
    /// @return destinationChainAsset Address of the asset on the destination chain.
    function getDestinationChainAsset(address localAsset, uint256 destinationChainId) external view returns (address);

    /// @notice Sets the mapping of an asset on the local chain to an asset on the destination chain.
    /// @param assetMappings The mapping of an asset on the local chain to an asset on the destination chain.
    function setDestinationChainAssets(AssetMapping[] memory assetMappings) external;
}

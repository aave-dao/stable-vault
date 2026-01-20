// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";

import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {RescuableAssetNative} from "src/misc/RescuableAssetNative.sol";
import {RescuableToken} from "src/misc/RescuableToken.sol";
import {Constants} from "src/types/Constants.sol";
import {Errors} from "src/types/Errors.sol";

/// @title BaseChainGateway
/// @author Aave Labs
/// @notice Abstract base contract for ChainGateway contracts.
abstract contract BaseChainGateway is AccessManagedUpgradeable, RescuableAssetNative, RescuableToken, IChainGateway {
    address internal immutable IOU_TOKEN_MANAGER;

    /// @custom:storage-location erc7201:aave.storage.BaseChainGateway
    struct BaseChainGatewayStorage {
        /// @dev Set of adapters whitelisted for usage.
        /// @dev asset == address(0) for data-only bridging.
        /// @dev Assumes token bridges also support Arbitrary Message Bridging.
        mapping(address asset => mapping(uint256 chainId => mapping(address adapter => bool))) supportedBridgeAdapters;

        /// @dev The adapter used to send assets/messages to a destination chain.
        mapping(address asset => mapping(uint256 chainId => address defaultAdapter)) defaultBridgeAdapter;
    }

    // keccak256(abi.encode(uint256(keccak256("aave.storage.BaseChainGateway")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT_BASE_CHAIN_GATEWAY =
        0x4747741592a60aa5472529276f7e68f29b428a96eb848d005032328b323d4100;

    function $storage() private pure returns (BaseChainGatewayStorage storage _storage) {
        assembly {
            _storage.slot := STORAGE_SLOT_BASE_CHAIN_GATEWAY
        }
    }

    function $BaseChainGateway() internal pure returns (BaseChainGatewayStorage storage) {
        return $storage();
    }

    /// @dev Constructor.
    /// @param iouTokenManager Address of the IOU token manager.
    constructor(address iouTokenManager) {
        _disableInitializers();
        IOU_TOKEN_MANAGER = iouTokenManager;
    }

    function __BaseChainGateway_init(address accessManager) internal virtual onlyInitializing {
        __AccessManaged_init(accessManager);
    }

    /// @inheritdoc IChainGateway
    function getDefaultBridgeAdapter(address asset, uint256 chainId) external view override returns (address) {
        return $storage().defaultBridgeAdapter[asset][chainId];
    }

    /// @inheritdoc IChainGateway
    function receiveMessage(uint256 sourceChainId, IBridgeAdapter.BridgeAsset[] memory assets, bytes memory data)
        external
        override
    {
        if (assets.length > 0) {
            // Receiving of funds should not check for whitelisted adapter because we may want to recover tokens from
            // adapter even after removing the adapter. We may have to remove an adapter if we do not trust it for
            // receiving arbitrary messages.
            // If someone wants to send funds to the Gateway then it will take it.
            _receiveFunds(assets);
        }
        if (data.length > 0) {
            _receiveData(sourceChainId, data);
        }
    }

    /// @inheritdoc IChainGateway
    function sendBridgeIouTokenMessageWithFeePayer(
        uint256 destinationChainId,
        address iouTokenRecipient,
        uint256 iouTokenAmountRay,
        IBridgeAdapter.BridgeParams memory bridgeParams
    ) external override {
        require(msg.sender == IOU_TOKEN_MANAGER, OnlyIouTokenManager());

        address adapter = $storage().defaultBridgeAdapter[Constants.ASSET_FOR_DATA_ONLY_BRIDGE][destinationChainId];
        require(adapter != address(0), AdapterNotFound());

        bytes memory bridgeIouTokenMessageEncoded = abi.encode(
            IChainGateway.CrossChainMessage({
                messageType: IChainGateway.MessageType.BRIDGE_IOU_TOKEN,
                data: abi.encode(
                    IChainGateway.IouTokenBridgeMessage({recipient: iouTokenRecipient, amount: iouTokenAmountRay})
                )
            })
        );
        IBridgeAdapter(adapter)
            .publishMessageToChainWithFeePayer(
                destinationChainId, new IBridgeAdapter.BridgeAsset[](0), bridgeIouTokenMessageEncoded, bridgeParams
            );
    }

    /// @inheritdoc IChainGateway
    function addBridgeAdapter(address asset, uint256 chainId, address adapter) external override restricted {
        require(!$storage().supportedBridgeAdapters[asset][chainId][adapter], Errors.AddressAlreadyWhitelisted());
        $storage().supportedBridgeAdapters[asset][chainId][adapter] = true;
        emit BridgeAdapterAdded(asset, chainId, adapter);
    }

    /// @inheritdoc IChainGateway
    function removeBridgeAdapter(address asset, uint256 chainId, address adapter) external override restricted {
        require($storage().supportedBridgeAdapters[asset][chainId][adapter], Errors.AddressNotWhitelisted());
        delete $storage().supportedBridgeAdapters[asset][chainId][adapter];
        // Remove it from the default adapter if it is the default adapter.
        if ($storage().defaultBridgeAdapter[asset][chainId] == adapter) {
            delete $storage().defaultBridgeAdapter[asset][chainId];
            emit DefaultBridgeAdapterSet(asset, chainId, address(0));
        }
        emit BridgeAdapterRemoved(asset, chainId, adapter);
    }

    /// @inheritdoc IChainGateway
    function setDefaultBridgeAdapter(address asset, uint256 chainId, address adapter) external override restricted {
        require($storage().supportedBridgeAdapters[asset][chainId][adapter], Errors.AddressNotWhitelisted());
        $storage().defaultBridgeAdapter[asset][chainId] = adapter;
        emit DefaultBridgeAdapterSet(asset, chainId, adapter);
    }

    /// @dev Checks full set of adapters as opposed to the default adapter in case an adapter is swapped out but a
    /// pending message needs to be ingested.
    function _onlyAdapter(address asset, uint256 sourceChainId) internal view {
        require($storage().supportedBridgeAdapters[asset][sourceChainId][msg.sender], AdapterNotFound());
    }

    /// @dev The Gateway must have ownership of the assets being bridged as it allows the adapter as a spender.
    function _sendCrossChainMessage(
        uint256 destinationChainId,
        address adapter,
        address assetToBridge,
        uint256 amountToBridge,
        bytes memory dataToBridge,
        IBridgeAdapter.BridgeParams memory bridgeParams
    ) internal {
        IBridgeAdapter.BridgeAsset[] memory assets;
        if (assetToBridge != Constants.ASSET_FOR_DATA_ONLY_BRIDGE) {
            assets = new IBridgeAdapter.BridgeAsset[](1);
            assets[0] = IBridgeAdapter.BridgeAsset({asset: assetToBridge, amount: amountToBridge});
        }
        IBridgeAdapter(adapter)
            .publishMessageToChainWithFeePayer(destinationChainId, assets, dataToBridge, bridgeParams);
    }

    function _beforeRescueTokens(
        address, // asset
        uint256 // amount
    )
        internal
        virtual
        override
    {
        // Equivalent to adding the `restricted` modifier.
        _checkCanCall(_msgSender(), _msgData());
    }

    function _beforeRescueNative(uint256) internal virtual override {
        // Equivalent to adding the `restricted` modifier.
        _checkCanCall(_msgSender(), _msgData());
    }

    function _receiveFunds(IBridgeAdapter.BridgeAsset[] memory assets) internal virtual;

    function _receiveData(uint256 sourceChainId, bytes memory data) internal virtual;
}

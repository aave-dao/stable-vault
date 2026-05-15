// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {RescuableNative} from "src/misc/RescuableNative.sol";
import {RescuableToken} from "src/misc/RescuableToken.sol";
import {Constants} from "src/types/Constants.sol";
import {Errors} from "src/types/Errors.sol";

/// @title BaseChainGateway
/// @author Aave Labs
/// @notice Abstract base contract for ChainGateway contracts.
/// @custom:upgradeable
abstract contract BaseChainGateway is AccessManagedUpgradeable, RescuableNative, RescuableToken, IChainGateway {
    address internal immutable IOU_TOKEN_MANAGER;

    /// @custom:storage-location erc7201:aave.storage.BaseChainGateway
    struct BaseChainGatewayStorage {
        /// @dev Set of adapters whitelisted for usage.
        /// @dev An adapter whitelisted for a token is assumed to also be trusted to ingest data sent along with the
        /// token.
        /// @dev asset == `address(0xDA7ada7aDA7ADA7ADA7AdA7aDA7aDA7ADA7adA7a)` for data-only bridging.
        mapping(address asset => mapping(uint256 chainId => mapping(address bridgeAdapter => bool)))
            supportedBridgeAdapters;
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
        require(iouTokenManager != address(0), Errors.ZeroAddress());
        _disableInitializers();
        IOU_TOKEN_MANAGER = iouTokenManager;
    }

    function __BaseChainGateway_init(address accessManager) internal virtual onlyInitializing {
        IAccessManager(accessManager).canCall(address(0), address(0), bytes4(0));
        __AccessManaged_init(accessManager);
    }

    /// @inheritdoc IChainGateway
    function getIouTokenManager() external view override returns (address) {
        return IOU_TOKEN_MANAGER;
    }

    /// @notice Checks whether a bridge adapter is whitelisted for a given asset and chain.
    /// @param asset The asset to check the bridge adapter for.
    /// @param chainId The chain id to check the bridge adapter for.
    /// @param bridgeAdapter The bridge adapter to check.
    /// @return True if the bridge adapter is whitelisted, false otherwise.
    function isBridgeAdapterSupported(address asset, uint256 chainId, address bridgeAdapter)
        external
        view
        returns (bool)
    {
        return $storage().supportedBridgeAdapters[asset][chainId][bridgeAdapter];
    }

    /// @inheritdoc IChainGateway
    function receiveMessage(uint256 sourceChainId, address asset, uint256 amount, bytes memory data) external override {
        bool hasFunds = asset != Constants.ASSET_FOR_DATA_ONLY_BRIDGE && amount > 0;
        bool hasData = data.length > 0;

        if (hasFunds) {
            if (hasData) {
                // Require msg.sender to be a whitelisted bridge adapter to ingest the data accompanying the funds.
                _validateBridgeAdapterIsSupported(asset, sourceChainId, msg.sender);
                _receiveFundsWithData(sourceChainId, asset, amount, data);
            } else {
                // Receiving of funds should not check for whitelisted bridge adapter because we may want to recover
                // tokens from an adapter even after removing it from arbitrary message handling.
                // If someone wants to send funds to the Gateway then it will take it.
                _receiveFunds(asset, amount);
            }
            emit FundsReceived(asset, amount, sourceChainId);
        } else if (hasData) {
            // Require msg.sender to be a whitelisted bridge adapter to ingest the data from a data-only message.
            _validateBridgeAdapterIsSupported(Constants.ASSET_FOR_DATA_ONLY_BRIDGE, sourceChainId, msg.sender);
            _receiveData(sourceChainId, data);
        }
    }

    /// @inheritdoc IChainGateway
    function sendBridgeIouTokenMessageWithFeePayer(
        uint256 destinationChainId,
        address iouTokenRecipient,
        uint256 iouTokenAmountRay,
        address bridgeAdapter,
        address feePayer,
        uint256 payloadExecutionGasLimit,
        bytes calldata bridgeAdapterData
    ) external payable override {
        require(msg.sender == IOU_TOKEN_MANAGER, OnlyIouTokenManager());
        require(iouTokenAmountRay > 0, Errors.ZeroAmount());

        bytes memory bridgeIouTokenMessageEncoded = abi.encode(
            IChainGateway.CrossChainMessage({
                messageType: IChainGateway.MessageType.BRIDGE_IOU_TOKEN,
                data: abi.encode(
                    IChainGateway.IouTokenBridgeMessage({recipient: iouTokenRecipient, amount: iouTokenAmountRay})
                )
            })
        );
        _validateBridgeAdapterIsSupported(Constants.ASSET_FOR_DATA_ONLY_BRIDGE, destinationChainId, bridgeAdapter);
        IBridgeAdapter(bridgeAdapter).publishDataOnlyMessage{value: msg.value}(
            destinationChainId, bridgeIouTokenMessageEncoded, feePayer, payloadExecutionGasLimit, bridgeAdapterData
        );
    }

    /// @inheritdoc IChainGateway
    function addBridgeAdapter(address asset, uint256 chainId, address bridgeAdapter) external override restricted {
        require(bridgeAdapter != address(0), Errors.ZeroAddress());
        require(chainId != block.chainid && chainId != 0, Errors.InvalidParameter());
        require(!$storage().supportedBridgeAdapters[asset][chainId][bridgeAdapter], Errors.AddressAlreadyWhitelisted());
        $storage().supportedBridgeAdapters[asset][chainId][bridgeAdapter] = true;
        emit BridgeAdapterAdded(asset, chainId, bridgeAdapter);
    }

    /// @inheritdoc IChainGateway
    function removeBridgeAdapter(address asset, uint256 chainId, address bridgeAdapter) external override restricted {
        require($storage().supportedBridgeAdapters[asset][chainId][bridgeAdapter], Errors.AddressNotWhitelisted());
        delete $storage().supportedBridgeAdapters[asset][chainId][bridgeAdapter];
        emit BridgeAdapterRemoved(asset, chainId, bridgeAdapter);
    }

    function _beforeRescueTokens(
        address, // token
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

    function _receiveData(uint256 sourceChainId, bytes memory data) internal virtual;

    function _receiveFunds(address asset, uint256 amount) internal virtual;

    /// @dev Reverts by default.
    /// @dev Must be overridden if the Chain Gateway can ingest funds along with data from a single cross-chain message.
    function _receiveFundsWithData(
        uint256, // sourceChainId
        address, // asset
        uint256, // amount
        bytes memory // data
    )
        internal
        virtual
    {
        revert DataNotAllowedWithFunds();
    }

    /// @dev Validates that the bridge adapter is whitelisted for the given asset and chain.
    function _validateBridgeAdapterIsSupported(address asset, uint256 chainId, address bridgeAdapter) internal view {
        require($storage().supportedBridgeAdapters[asset][chainId][bridgeAdapter], AdapterNotFound());
    }
}

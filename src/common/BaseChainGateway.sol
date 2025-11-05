// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "../interfaces/IChainGateway.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {RescuableAssets} from "./RescuableAssets.sol";

// TODO: this contract should be pausable.... if bridge is compromised we should not ingest messages from it.
abstract contract BaseChainGateway is AccessManagedUpgradeable, RescuableAssets, IChainGateway {
    using SafeERC20 for IERC20;

    address internal constant FEE_ON_NATIVE_CURRENCY = address(0);
    address internal constant ASSET_FOR_DATA_ONLY_BRIDGE = address(0);

    address internal immutable IOU_TOKEN_MANAGER;

    /// @dev Set of adapters whitelisted for usage.
    /// @dev asset == address(0) for data-only bridging.
    /// @dev Assumes token bridges also support Arbitrary Message Bridging.
    mapping(address asset => mapping(uint256 chainId => mapping(address adapter => bool))) internal
        _supportedBridgeAdapters;

    /// @dev The adapter used to send assets/messages to a destination chain.
    mapping(address asset => mapping(uint256 chainId => address defaultAdapter)) internal _defaultBridgeAdapter;

    /// @dev Constructor.
    /// @param iouTokenManager The address of the IOU token manager.
    constructor(address iouTokenManager) {
        _disableInitializers();
        IOU_TOKEN_MANAGER = iouTokenManager;
    }

    function __BaseChainGateway_init(address accessManager) internal virtual onlyInitializing {
        __AccessManaged_init(accessManager);
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
        BridgeAdapterParams memory bridgeAdapterParams
    ) external payable override {
        require(msg.sender == IOU_TOKEN_MANAGER, ErrorsLib.InvalidMessageSender());
        require(destinationChainId != block.chainid, ErrorsLib.InvalidDestinationChainId());

        address adapter = _defaultBridgeAdapter[ASSET_FOR_DATA_ONLY_BRIDGE][destinationChainId];
        require(adapter != address(0), AdapterNotFound());

        bytes memory data = abi.encode(
            IChainGateway.CrossChainMessage({
                messageType: IChainGateway.MessageType.BRIDGE_IOUTOKEN,
                data: abi.encode(
                    IChainGateway.IouTokenBridgeMessage({recipient: iouTokenRecipient, amount: iouTokenAmountRay})
                )
            })
        );
        _prepareBridgeFeeForAdapter(
            adapter,
            bridgeAdapterParams.bridgeFeePayer,
            bridgeAdapterParams.bridgeFeeToken,
            bridgeAdapterParams.bridgeFeeAmount
        );
        _sendCrossChainMessage(
            destinationChainId, adapter, new IBridgeAdapter.BridgeAsset[](0), data, bridgeAdapterParams
        );
    }

    /// @inheritdoc RescuableAssets
    function rescueTokens(address asset, uint256 amount) public override restricted {
        super.rescueTokens(asset, amount);
    }

    /// @inheritdoc IChainGateway
    function getDefaultBridgeAdapter(address asset, uint256 chainId) external view override returns (address) {
        return _defaultBridgeAdapter[asset][chainId];
    }

    /// @inheritdoc IChainGateway
    function addBridgeAdapter(address asset, uint256 chainId, address adapter) external override restricted {
        require(!_supportedBridgeAdapters[asset][chainId][adapter], ErrorsLib.AddressAlreadyWhitelisted());
        _supportedBridgeAdapters[asset][chainId][adapter] = true;
        emit BridgeAdapterAdded(asset, chainId, adapter);
    }

    /// @inheritdoc IChainGateway
    function removeBridgeAdapter(address asset, uint256 chainId, address adapter) external override restricted {
        require(_supportedBridgeAdapters[asset][chainId][adapter], ErrorsLib.AddressNotWhitelisted());
        delete _supportedBridgeAdapters[asset][chainId][adapter];
        // Remove it from the default adapter if it is the default adapter.
        if (_defaultBridgeAdapter[asset][chainId] == adapter) {
            delete _defaultBridgeAdapter[asset][chainId];
            emit DefaultBridgeAdapterSet(asset, chainId, address(0));
        }
        emit BridgeAdapterRemoved(asset, chainId, adapter);
    }

    /// @inheritdoc IChainGateway
    function setDefaultBridgeAdapter(address asset, uint256 chainId, address adapter) external override restricted {
        require(_supportedBridgeAdapters[asset][chainId][adapter], ErrorsLib.AddressNotWhitelisted());
        _defaultBridgeAdapter[asset][chainId] = adapter;
        emit DefaultBridgeAdapterSet(asset, chainId, adapter);
    }

    /// @dev Checks full set of adapters as opposed to the default adapter in case an adapter is swapped out but a
    /// pending message needs to be ingested.
    function _onlyAdapter(address asset, uint256 sourceChainId) internal view {
        require(_supportedBridgeAdapters[asset][sourceChainId][msg.sender], AdapterNotFound());
    }

    /// @dev Assumes the bridge fee has not yet been pulled from the caller into this contract.
    /// @dev Be mindful of overriding the token approval made by this function.
    function _prepareBridgeFeeForAdapter(
        address adapter,
        address feeSource,
        address bridgeFeeToken,
        uint256 bridgeFeeAmount
    ) internal {
        require(bridgeFeeAmount > 0, ErrorsLib.ZeroAmount());
        if (bridgeFeeToken == FEE_ON_NATIVE_CURRENCY) {
            require(msg.value >= bridgeFeeAmount, ErrorsLib.InsufficientFunds());
        } else {
            IERC20(bridgeFeeToken).safeTransferFrom(feeSource, address(this), bridgeFeeAmount);
            IERC20(bridgeFeeToken).forceApprove(adapter, bridgeFeeAmount);
        }
    }

    /// @dev The Gateway must have ownership of the assets being bridged as it allows the adapter as a spender.
    function _sendCrossChainMessage(
        uint256 destinationChainId,
        address adapter,
        IBridgeAdapter.BridgeAsset[] memory assets,
        bytes memory data,
        BridgeAdapterParams memory bridgeAdapterParams
    ) internal {
        for (uint256 i = 0; i < assets.length; i++) {
            // Increase allowance for when the fee token is the same token being bridged.
            IERC20(assets[i].asset).safeIncreaseAllowance(adapter, assets[i].amount);
        }
        IBridgeAdapter(adapter).publishMessageToChainWithFeePayer{value: msg.value}(
            destinationChainId, assets, data, bridgeAdapterParams
        );
    }

    function _receiveFunds(IBridgeAdapter.BridgeAsset[] memory assets) internal virtual;

    function _receiveData(uint256 sourceChainId, bytes memory data) internal virtual;
}

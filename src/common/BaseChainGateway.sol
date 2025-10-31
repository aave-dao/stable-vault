// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "../interfaces/IChainGateway.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {RescuableAssets} from "./RescuableAssets.sol";

// TODO: this contract should be pausable.... if bridge is compromised we should not ingest messages from it.
abstract contract BaseChainGateway is AccessManaged, RescuableAssets, IChainGateway {
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

    constructor(address accessManager, address iouTokenManager) AccessManaged(accessManager) {
        IOU_TOKEN_MANAGER = iouTokenManager;
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
        address feeRefundRecipient,
        address bridgeFeeToken,
        uint256 bridgeFeeAmount,
        uint256 destinationChainId,
        address iouTokenRecipient,
        uint256 iouTokenAmountRay
    ) external payable override {
        require(msg.sender == IOU_TOKEN_MANAGER, ErrorsLib.InvalidMessageSender());
        require(destinationChainId != block.chainid, ErrorsLib.InvalidDestinationChainId());

        if (bridgeFeeToken == address(0)) {
            require(msg.value >= bridgeFeeAmount, ErrorsLib.InsufficientFunds());
        }

        if (bridgeFeeToken != FEE_ON_NATIVE_CURRENCY) {
            IERC20(bridgeFeeToken).safeTransferFrom(msg.sender, address(this), bridgeFeeAmount);
            IERC20(bridgeFeeToken)
                .forceApprove(_defaultBridgeAdapter[ASSET_FOR_DATA_ONLY_BRIDGE][destinationChainId], bridgeFeeAmount);
        }

        IBridgeAdapter(_defaultBridgeAdapter[ASSET_FOR_DATA_ONLY_BRIDGE][destinationChainId])
            .publishMessageToChainWithFeePayer(
                feeRefundRecipient,
                bridgeFeeToken,
                bridgeFeeAmount,
                destinationChainId,
                new IBridgeAdapter.BridgeAsset[](0),
                abi.encode(
                    IChainGateway.CrossChainMessage({
                        messageType: IChainGateway.MessageType.BRIDGE_IOUTOKEN,
                        data: abi.encode(
                            IChainGateway.IouTokenBridgeMessage({
                                recipient: iouTokenRecipient, amount: iouTokenAmountRay
                            })
                        )
                    })
                )
            );
    }

    /// @inheritdoc RescuableAssets
    function rescueTokens(address asset, uint256 amount) public override restricted {
        super.rescueTokens(asset, amount);
    }

    function getDefaultBridgeAdapter(address asset, uint256 chainId) external view returns (address) {
        return _defaultBridgeAdapter[asset][chainId];
    }

    function addBridgeAdapter(address asset, uint256 chainId, address adapter) external restricted {
        require(!_supportedBridgeAdapters[asset][chainId][adapter], ErrorsLib.AddressAlreadyWhitelisted());
        _supportedBridgeAdapters[asset][chainId][adapter] = true;
        emit BridgeAdapterAdded(asset, chainId, adapter);
    }

    function removeBridgeAdapter(address asset, uint256 chainId, address adapter) external restricted {
        require(_supportedBridgeAdapters[asset][chainId][adapter], ErrorsLib.AddressNotWhitelisted());
        delete _supportedBridgeAdapters[asset][chainId][adapter];
        emit BridgeAdapterRemoved(asset, chainId, adapter);
    }

    function setDefaultBridgeAdapter(address asset, uint256 chainId, address adapter) external restricted {
        require(_supportedBridgeAdapters[asset][chainId][adapter], ErrorsLib.AddressNotWhitelisted());
        _defaultBridgeAdapter[asset][chainId] = adapter;
        emit DefaultBridgeAdapterSet(asset, chainId, adapter);
    }

    /// @dev Checks full set of adapters as opposed to the default adapter in case an adapter is swapped out but a
    /// pending message needs to be ingested.
    function _onlyAdapter(address asset, uint256 sourceChainId) internal view {
        require(_supportedBridgeAdapters[asset][sourceChainId][msg.sender], UnsupportedAdapter());
    }

    function _receiveFunds(IBridgeAdapter.BridgeAsset[] memory assets) internal virtual;

    function _receiveData(uint256 sourceChainId, bytes memory data) internal virtual;
}

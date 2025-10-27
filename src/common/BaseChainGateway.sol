// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "../interfaces/IChainGateway.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";

abstract contract BaseChainGateway is IChainGateway {
    using SafeERC20 for IERC20;

    error UnsupportedAdapter();

    address internal constant FEE_ON_NATIVE_CURRENCY = address(0);
    address internal constant ASSET_FOR_DATA_ONLY_BRIDGE = address(0);
    address internal immutable IOU_TOKEN_MANAGER;

    modifier onlyAdmin() {
        require(msg.sender == _admin, ErrorsLib.NotAdmin());
        _;
    }

    /// @notice Account used to make low frequency, high impact changes.
    address internal _admin;
    /// @dev Assumes a single asset is bridged per bridge action through an adapter.
    /// @dev asset == address(0) for data-only bridging.
    /// @dev Assumes token bridges also support Arbitrary Message Bridging.
    mapping(address asset => mapping(uint256 chainId => address adapter)) internal _bridgeAdapter;

    constructor(address admin, address iouTokenManager) {
        require(admin != address(0), ErrorsLib.ZeroAddress());
        require(iouTokenManager != address(0), ErrorsLib.ZeroAddress());
        IOU_TOKEN_MANAGER = iouTokenManager;
        _admin = admin;
    }

    /// @inheritdoc IChainGateway
    function receiveMessage(uint256 sourceChainId, IBridgeAdapter.BridgeAsset[] memory assets, bytes memory data)
        external
        override
    {
        if (assets.length > 0) {
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
                .forceApprove(_bridgeAdapter[ASSET_FOR_DATA_ONLY_BRIDGE][destinationChainId], bridgeFeeAmount);
        }

        IBridgeAdapter(_bridgeAdapter[ASSET_FOR_DATA_ONLY_BRIDGE][destinationChainId])
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

    function _receiveFunds(IBridgeAdapter.BridgeAsset[] memory assets) internal virtual;

    function _receiveData(uint256 sourceChainId, bytes memory data) internal virtual;

    function getBridgeAdapter(address asset, uint256 chainId) external view returns (address) {
        return _bridgeAdapter[asset][chainId];
    }

    function setBridgeAdapter(address asset, uint256 chainId, address adapter) external onlyAdmin {
        require(chainId != 0, ErrorsLib.ZeroChainId());
        require(adapter != address(0), ErrorsLib.ZeroAddress());
        _bridgeAdapter[asset][chainId] = adapter;
    }

    function _onlyAdapter(address asset, uint256 sourceChainId) internal view {
        require(_bridgeAdapter[asset][sourceChainId] == msg.sender, UnsupportedAdapter());
    }
}

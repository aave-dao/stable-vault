// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IChainGateway} from "../interfaces/IChainGateway.sol";
import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";

abstract contract BaseChainGateway is IChainGateway {
    using SafeERC20 for IERC20;

    error UnsupportedAdapter();

    address internal constant ASSET_FOR_DATA_ONLY_BRIDGE = address(0);

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

    constructor(address admin) {
        _admin = admin;
    }

    /// @inheritdoc IChainGateway
    function receiveMessage(uint256 sourceChainId, IBridgeAdapter.BridgeAsset[] memory assets, bytes memory data)
        external
        override
    {
        if (assets.length > 0) {
            _receiveFunds(sourceChainId, assets);
        }
        if (data.length > 0) {
            _receiveData(sourceChainId, data);
        }
    }

    function _receiveFunds(uint256 sourceChainId, IBridgeAdapter.BridgeAsset[] memory assets) internal virtual;

    function _receiveData(uint256 sourceChainId, bytes memory data) internal virtual;

    function getBridgeAdapter(address asset, uint256 chainId) external view returns (address) {
        return _bridgeAdapter[asset][chainId];
    }

    function setBridgeAdapter(address asset, uint256 chainId, address adapter) external onlyAdmin {
        _bridgeAdapter[asset][chainId] = adapter;
    }

    function _onlyAdapter(address asset, uint256 sourceChainId) internal view {
        require(_bridgeAdapter[asset][sourceChainId] == msg.sender, UnsupportedAdapter());
    }
}

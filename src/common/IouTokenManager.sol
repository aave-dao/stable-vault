// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IChainGateway} from "../interfaces/IChainGateway.sol";
import {IIouTokenManager} from "../interfaces/IIouTokenManager.sol";
import {IMintableBurnableIERC20} from "../interfaces/IMintableBurnableIERC20.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";

// TODO: add events

/// @title IouTokenManager
/// @notice Manages the IOU token locking, releasing, minting, burning.
contract IouTokenManager is IIouTokenManager {
    using SafeERC20 for IERC20;

    address internal constant FEE_ON_NATIVE_CURRENCY = address(0);

    address internal immutable IOU_TOKEN;
    address internal immutable CHAIN_GATEWAY;
    address internal immutable VAULT;
    bool internal immutable IS_CONANICAL_CHAIN;

    uint256 internal _lockedBalance;

    modifier onlyAllowedReleaser() {
        require(IS_CONANICAL_CHAIN, NotCanonicalChain());
        require(msg.sender == CHAIN_GATEWAY, ErrorsLib.NotAuthorized());
        _;
    }

    modifier onlyAllowedMinter() {
        require(msg.sender == VAULT || msg.sender == CHAIN_GATEWAY, ErrorsLib.NotAuthorized());
        _;
    }

    modifier onlyAllowedBurner() {
        require(msg.sender == VAULT || msg.sender == CHAIN_GATEWAY, ErrorsLib.NotAuthorized());
        _;
    }

    constructor(address iouToken, address chainGateway, address vault, bool isCanonicalChain) {
        IOU_TOKEN = iouToken;
        CHAIN_GATEWAY = chainGateway;
        VAULT = vault;
        IS_CONANICAL_CHAIN = isCanonicalChain;
    }

    function getAsset() external view override returns (address) {
        return IOU_TOKEN;
    }

    function getLockedBalance() external view returns (uint256) {
        return _lockedBalance;
    }

    /// @inheritdoc IIouTokenManager
    function bridgeTokens(
        uint256 destinationChainId,
        address iouTokenRecipient,
        uint256 iouTokenAmountRay,
        address bridgeFeePayer,
        address bridgeFeeToken,
        uint256 bridgeFeeAmount
    ) external payable override {
        require(destinationChainId != block.chainid, ErrorsLib.InvalidDestinationChainId());
        // Pull the fee token from the caller and approve the chain gateway to spend it.
        if (bridgeFeeToken != FEE_ON_NATIVE_CURRENCY) {
            IERC20(bridgeFeeToken).safeTransferFrom(msg.sender, address(this), bridgeFeeAmount);
            IERC20(bridgeFeeToken).forceApprove(CHAIN_GATEWAY, bridgeFeeAmount);
        }
        // Pull the IOU tokens from the caller and lock them.
        if (IS_CONANICAL_CHAIN) {
            _lockTokens(msg.sender, iouTokenAmountRay);
        } else {
            _burnTokens(msg.sender, iouTokenAmountRay);
        }
        IChainGateway(CHAIN_GATEWAY).sendBridgeIouTokenMessageWithFeePayer{value: msg.value}(
            bridgeFeePayer, bridgeFeeToken, bridgeFeeAmount, destinationChainId, iouTokenRecipient, iouTokenAmountRay
        );
    }

    /// @inheritdoc IIouTokenManager
    function mintTokens(address to, uint256 amount) external override onlyAllowedMinter {
        IMintableBurnableIERC20(IOU_TOKEN).mint(to, amount);
    }

    /// @inheritdoc IIouTokenManager
    function burnTokens(address from, uint256 amount) external override onlyAllowedBurner {
        _burnTokens(from, amount);
    }

    /// @inheritdoc IIouTokenManager
    /// @dev Should only be used on canonical chain.
    function burnLockedTokens(uint256 amount) external override onlyAllowedBurner {
        require(_lockedBalance >= amount, InsufficientLockedBalance());
        _lockedBalance -= amount;
        _burnTokens(address(this), amount);
    }

    /// @inheritdoc IIouTokenManager
    /// @dev Should only be used on canonical chain.
    function releaseTokens(address to, uint256 amount) external override onlyAllowedReleaser {
        require(_lockedBalance >= amount, InsufficientLockedBalance());
        _lockedBalance -= amount;
        IERC20(IOU_TOKEN).safeTransfer(to, amount);
    }

    /// @dev should only be used on canonical chain.
    function _lockTokens(address from, uint256 amount) internal {
        _lockedBalance += amount;
        IERC20(IOU_TOKEN).safeTransferFrom(from, address(this), amount);
    }

    function _burnTokens(address from, uint256 amount) internal {
        IMintableBurnableIERC20(IOU_TOKEN).burn(from, amount);
    }
}

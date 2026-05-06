// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {IIouToken} from "src/interfaces/IIouToken.sol";
import {IIouTokenManager} from "src/interfaces/IIouTokenManager.sol";
import {IMintableBurnableIERC20} from "src/interfaces/IMintableBurnableIERC20.sol";
import {TransferHelperClient} from "src/misc/TransferHelperClient.sol";
import {Errors} from "src/types/Errors.sol";

/// @title IouTokenManager
/// @author Aave Labs
/// @notice Manages the IOU token locking, releasing, minting, burning.
/// @custom:upgradeable
contract IouTokenManager is TransferHelperClient, IIouTokenManager {
    using SafeERC20 for IERC20;

    address internal immutable IOU_TOKEN;
    address internal immutable CHAIN_GATEWAY;
    address internal immutable VAULT;
    bool internal immutable IS_ACCOUNTING_CHAIN;

    /// @custom:storage-location erc7201:aave.storage.IouTokenManager
    struct IouTokenManagerStorage {
        uint256 lockedBalance;
    }

    // keccak256(abi.encode(uint256(keccak256("aave.storage.IouTokenManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT_IOU_TOKEN_MANAGER =
        0xc66e11a4855dc9db3d359cf776e012e79f530b562e1a94c415417157a76d1500;

    function $storage() private pure returns (IouTokenManagerStorage storage _storage) {
        assembly {
            _storage.slot := STORAGE_SLOT_IOU_TOKEN_MANAGER
        }
    }

    function $IouTokenManager() internal pure returns (IouTokenManagerStorage storage) {
        return $storage();
    }

    modifier onlyAllowedReleaser() {
        require(msg.sender == CHAIN_GATEWAY, Errors.NotAuthorized());
        _;
    }

    modifier onlyAllowedMinter() {
        require(msg.sender == VAULT || msg.sender == CHAIN_GATEWAY, Errors.NotAuthorized());
        _;
    }

    modifier onlyAllowedBurner() {
        require(msg.sender == VAULT || msg.sender == CHAIN_GATEWAY, Errors.NotAuthorized());
        _;
    }

    modifier onlyAccountingChain() {
        require(IS_ACCOUNTING_CHAIN, OnlyAccountingChain());
        _;
    }

    /// @dev Constructor.
    /// @param iouToken Address of the IOU token.
    /// @param chainGateway Address of the ChainGateway contract.
    /// @param vault Address of the Vault contract.
    /// @param transferHelper Address of the TransferHelper contract.
    /// @param isAccountingChain Whether the current chain is the Accounting chain.
    constructor(address iouToken, address chainGateway, address vault, address transferHelper, bool isAccountingChain)
        TransferHelperClient(transferHelper)
    {
        require(iouToken != address(0), Errors.ZeroAddress());
        require(chainGateway != address(0), Errors.ZeroAddress());
        if (isAccountingChain) {
            require(vault != address(0), Errors.ZeroAddress());
        }
        IOU_TOKEN = iouToken;
        CHAIN_GATEWAY = chainGateway;
        VAULT = vault;
        IS_ACCOUNTING_CHAIN = isAccountingChain;
    }

    /// @inheritdoc IIouTokenManager
    function getAsset() external view override returns (address) {
        return IOU_TOKEN;
    }

    /// @inheritdoc IIouTokenManager
    function getLockedBalance() external view override returns (uint256) {
        return $storage().lockedBalance;
    }

    /// @inheritdoc IIouTokenManager
    /// @dev IOUs should be bridged via bridges which require finalization on the source chain. If IOUs are bridged and
    /// exchanged for assets on a destination, but the source chain reorgs, then a user would keep their IOUs and the
    /// assets withdrawn on the destination chain.
    function bridgeTokens(
        uint256 destinationChainId,
        address iouTokenRecipient,
        uint256 iouTokenAmountRay,
        address bridgeAdapter,
        uint256 gasLimit,
        bytes calldata bridgeAdapterData
    ) external payable override {
        require(destinationChainId != block.chainid, Errors.InvalidDestinationChainId());
        require(iouTokenRecipient != address(0), Errors.InvalidParameter());
        require(iouTokenAmountRay > 0, Errors.ZeroAmount());
        if (IS_ACCOUNTING_CHAIN) {
            _lockTokens(msg.sender, iouTokenAmountRay);
        } else {
            _burnTokens(msg.sender, iouTokenAmountRay);
        }

        IChainGateway(CHAIN_GATEWAY).sendBridgeIouTokenMessageWithFeePayer{value: msg.value}(
            destinationChainId,
            iouTokenRecipient,
            iouTokenAmountRay,
            bridgeAdapter,
            msg.sender,
            gasLimit,
            bridgeAdapterData
        );

        emit TokensBridged(destinationChainId, iouTokenRecipient, iouTokenAmountRay);
    }

    /// @inheritdoc IIouTokenManager
    function mintTokens(address to, uint256 amount) external override onlyAllowedMinter {
        _mintTokens(to, amount);
    }

    /// @inheritdoc IIouTokenManager
    function burnTokens(address from, uint256 amount) external override onlyAllowedBurner {
        _burnTokens(from, amount);
    }

    /// @inheritdoc IIouTokenManager
    function burnLockedTokens(uint256 amount) external override onlyAllowedBurner onlyAccountingChain {
        require(amount <= $storage().lockedBalance, InsufficientLockedBalance());
        $storage().lockedBalance -= amount;
        _burnTokens(address(this), amount);
        emit LockedTokensBurned(address(this), amount);
    }

    /// @inheritdoc IIouTokenManager
    function releaseTokens(address to, uint256 amount) external override onlyAllowedReleaser onlyAccountingChain {
        require(amount <= $storage().lockedBalance, InsufficientLockedBalance());
        $storage().lockedBalance -= amount;
        IERC20(IOU_TOKEN).safeTransfer(to, amount);
        emit LockedTokensReleased(to, amount);
    }

    /// @dev should only be used on Accounting chain.
    function _lockTokens(address from, uint256 amount) internal {
        $storage().lockedBalance += amount;
        IIouToken(IOU_TOKEN).lock(from, amount);
        emit TokensLocked(from, amount);
    }

    function _burnTokens(address from, uint256 amount) internal {
        IMintableBurnableIERC20(IOU_TOKEN).burn(from, amount);
    }

    function _mintTokens(address to, uint256 amount) internal {
        IMintableBurnableIERC20(IOU_TOKEN).mint(to, amount);
    }
}

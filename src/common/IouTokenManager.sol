// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IChainGateway} from "../interfaces/IChainGateway.sol";
import {IIouTokenManager} from "../interfaces/IIouTokenManager.sol";
import {IMintableBurnableIERC20} from "../interfaces/IMintableBurnableIERC20.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {TransferHelperClient} from "./TransferHelperClient.sol";

// TODO: add events

/// @title IouTokenManager
/// @notice Manages the IOU token locking, releasing, minting, burning.
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

    modifier onlyAccountingChain() {
        require(IS_ACCOUNTING_CHAIN, NotAccountingChain());
        _;
    }

    constructor(address iouToken, address chainGateway, address vault, address transferHelper, bool isAccountingChain)
        TransferHelperClient(transferHelper)
    {
        IOU_TOKEN = iouToken;
        CHAIN_GATEWAY = chainGateway;
        VAULT = vault;
        IS_ACCOUNTING_CHAIN = isAccountingChain;
    }

    function getAsset() external view override returns (address) {
        return IOU_TOKEN;
    }

    function getLockedBalance() external view returns (uint256) {
        return $storage().lockedBalance;
    }

    /// @inheritdoc IIouTokenManager
    function bridgeTokens(
        uint256 destinationChainId,
        address iouTokenRecipient,
        uint256 iouTokenAmountRay,
        IChainGateway.BridgeParams memory bridgeParams
    ) external payable override assertingTransferHelperBalanceFor(bridgeParams.feeToken) {
        require(destinationChainId != block.chainid, ErrorsLib.InvalidDestinationChainId());
        if (IS_ACCOUNTING_CHAIN) {
            _lockTokens(msg.sender, iouTokenAmountRay);
        } else {
            _burnTokens(msg.sender, iouTokenAmountRay);
        }
        _transferBridgeFeeToTransferHelper(bridgeParams);

        IChainGateway(CHAIN_GATEWAY)
            .sendBridgeIouTokenMessageWithFeePayer(
                destinationChainId, iouTokenRecipient, iouTokenAmountRay, bridgeParams
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
    function burnLockedTokens(uint256 amount) external override onlyAllowedBurner onlyAccountingChain {
        require(amount <= $storage().lockedBalance, InsufficientLockedBalance());
        $storage().lockedBalance -= amount;
        _burnTokens(address(this), amount);
    }

    /// @inheritdoc IIouTokenManager
    function releaseTokens(address to, uint256 amount) external override onlyAllowedReleaser onlyAccountingChain {
        require(amount <= $storage().lockedBalance, InsufficientLockedBalance());
        $storage().lockedBalance -= amount;
        IERC20(IOU_TOKEN).safeTransfer(to, amount);
    }

    /// @dev should only be used on Accounting chain.
    function _lockTokens(address from, uint256 amount) internal {
        $storage().lockedBalance += amount;
        IERC20(IOU_TOKEN).safeTransferFrom(from, address(this), amount);
    }

    function _burnTokens(address from, uint256 amount) internal {
        IMintableBurnableIERC20(IOU_TOKEN).burn(from, amount);
    }
}

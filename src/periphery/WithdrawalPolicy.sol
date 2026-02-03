// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {EIP712Upgradeable} from "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EfficientHashLib} from "@solady/utils/EfficientHashLib.sol";

import {IWithdrawalPolicy} from "src/interfaces/IWithdrawalPolicy.sol";
import {Constants} from "src/types/Constants.sol";
import {Errors} from "src/types/Errors.sol";

/// @title WithdrawalPolicy
/// @author Aave Labs
/// @notice Contract that enforces conditions during withdrawal executions (i.e. when exchanging IOUs for assets).
/// @dev This contract does not control who can withdraw, all users have the right to do so. Thus, the conditions
/// enforced by this contract must not prevent withdrawals, but rather ensure that permissionless withdrawals meet the
/// protocol's requirements.
/// @dev The current implementation applies a fee to: deter abuse of arbitrage opportunities through the protocol's
/// liquidity, discourage spam, and cover protocol operational costs (e.g. bridge or swap fees).
/// @dev The fee is capped at 5.00% and is expected to be lower in most scenarios.
contract WithdrawalPolicy is AccessManagedUpgradeable, EIP712Upgradeable, IWithdrawalPolicy {
    // EIP-712 typeHash:
    // keccak256("FeeDiscount(address user,address assetOut,uint256 iouAmountRay,uint16 personalFeeBps,uint256
    // nonce,uint256 deadline)").
    bytes32 public constant FEE_DISCOUNT_TYPEHASH = 0x646ab18e84d3d6045718daa407509f2935bc43bae73437f6cfccb5fd55c34544;

    /// @dev The maximum fee in basis points that can be applied to a withdrawal. Set to 5.00%.
    uint16 internal constant FEE_CAP_BPS = 5_00;

    address internal immutable ASSET_REGISTRY;
    address internal immutable WITHDRAWAL_POLICY_APPLIER;

    /// @notice Signed fee discount data (decoded from WithdrawalRequest.data).
    /// @param personalFeeBps The personal fee in basis points signed by a whitelisted signer.
    /// @param nonce Unique nonce to prevent signature replay.
    /// @param deadline Timestamp after which the signature is no longer valid.
    /// @param signature The EIP-712 signature from a whitelisted signer.
    struct SignedFeeDiscount {
        uint16 personalFeeBps;
        uint256 nonce;
        uint256 deadline;
        bytes signature;
    }

    /// @notice Configuration for an asset-specific fee.
    /// @param feeBps Fee in basis points applied to the IOU quantity being exchanged for the asset.
    /// @param isSet Whether the fee is set (used for lookups).
    struct AssetFeeConfig {
        uint16 feeBps;
        bool isSet;
    }

    /// @custom:storage-location erc7201:aave.storage.WithdrawalPolicy
    struct WithdrawalPolicyStorage {
        uint16 defaultFeeBps;
        mapping(address asset => AssetFeeConfig config) assetFeeConfigs;
        mapping(address account => bool isSigner) isSigner;
        mapping(address signer => mapping(uint256 nonce => bool used)) wasNonceUsed;
    }

    // keccak256(abi.encode(uint256(keccak256("aave.storage.WithdrawalPolicy")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT_WITHDRAWAL_POLICY =
        0x48eb1b6299cf8fd4c062909cb421828ec45d2e192a5da81d7bd68b7aecc6f800;

    function $storage() private pure returns (WithdrawalPolicyStorage storage _storage) {
        assembly {
            _storage.slot := STORAGE_SLOT_WITHDRAWAL_POLICY
        }
    }

    modifier onlyWithdrawalPolicyApplier() {
        require(msg.sender == WITHDRAWAL_POLICY_APPLIER, Errors.NotAuthorized());
        _;
    }

    /// @dev Constructor.
    /// @param assetRegistry Address of the AssetRegistry contract used for managing asset configurations.
    /// @param withdrawalPolicyApplier Address allowed to apply the withdrawal policy.
    constructor(address assetRegistry, address withdrawalPolicyApplier) EIP712Upgradeable() {
        _disableInitializers();
        ASSET_REGISTRY = assetRegistry;
        WITHDRAWAL_POLICY_APPLIER = withdrawalPolicyApplier;
    }

    /// @dev Initializer.
    /// @param accessManager The address of the IAccessManager contract used for handling access control.
    /// @param defaultFeeBps The initial default fee in basis points.
    function initialize(address accessManager, uint16 defaultFeeBps) external virtual initializer {
        __WithdrawalPolicy_init(accessManager, defaultFeeBps);
    }

    function __WithdrawalPolicy_init(address accessManager, uint16 defaultFeeBps) internal virtual onlyInitializing {
        __AccessManaged_init(accessManager);
        __EIP712_init("WithdrawalPolicy", "1");
        _setDefaultFeeBps(defaultFeeBps);
    }

    /// @inheritdoc IWithdrawalPolicy
    function applyWithdrawalPolicy(WithdrawalRequest calldata request)
        external
        override
        onlyWithdrawalPolicyApplier
        returns (uint256)
    {
        (uint256 amountOutRay, address signer, uint256 nonce) = _previewWithdrawalPolicy(request);
        if (signer != address(0)) {
            _markNonceAsUsed(signer, nonce);
        }
        return amountOutRay;
    }

    /// @inheritdoc IWithdrawalPolicy
    function previewWithdrawalPolicy(WithdrawalRequest calldata request) external view override returns (uint256) {
        (uint256 amountOutRay,,) = _previewWithdrawalPolicy(request);
        return amountOutRay;
    }

    /// @notice Getter for the configuration for an asset-specific fee.
    /// @param asset Address of the asset to get the configuration for.
    /// @return assetFeeConfig Configuration for the asset-specific fee.
    function getAssetFeeConfig(address asset) external view returns (AssetFeeConfig memory) {
        return $storage().assetFeeConfigs[asset];
    }

    /// @notice Getter for the fallback fee in basis points which is used when a personal fee or asset-specific fee is
    /// not available.
    /// @return defaultFeeBps Fallback fee in basis points.
    function getDefaultFeeBps() external view returns (uint16) {
        return $storage().defaultFeeBps;
    }

    /// @notice Getter for whether an account is a signer.
    /// @param account Address of the account to check if it is a signer or not.
    /// @return bool True if the account is a signer, false otherwise.
    function isSigner(address account) external view returns (bool) {
        return $storage().isSigner[account];
    }

    /// @notice Getter for whether a nonce has been consumed by a signer.
    /// @param signer Address of the signer to check.
    /// @param nonce The nonce to check.
    /// @return bool True if the nonce has been used, false otherwise.
    function wasNonceUsed(address signer, uint256 nonce) external view returns (bool) {
        return $storage().wasNonceUsed[signer][nonce];
    }

    //////////////////////////////// RESTRICTED FUNCTIONS ////////////////////////////////

    /// @notice Sets the configuration for an asset-specific fee.
    /// @param asset Address of the asset to set the configuration for.
    /// @param newAssetFeeBps The fee in basis points applied to the IOU quantity being exchanged for the asset.
    /// @param isSet Whether the fee is set (used for lookups).
    function setAssetFeeBps(address asset, uint16 newAssetFeeBps, bool isSet) external restricted {
        // We don't check for new asset fee being less than the default fee because maybe we want some specific asset to
        // have a higher fee than the default fee.
        require(newAssetFeeBps <= FEE_CAP_BPS, Errors.InvalidParameter());
        $storage().assetFeeConfigs[asset].feeBps = newAssetFeeBps;
        $storage().assetFeeConfigs[asset].isSet = isSet;
        emit AssetFeeBpsSet(asset, newAssetFeeBps, isSet);
    }

    /// @notice Sets the fallback fee in basis points which is used when a personal fee or asset-specific fee is not
    /// available.
    /// @param newDefaultFeeBps The fee in basis points applied to the IOU quantity being exchanged for the
    /// asset.
    function setDefaultFeeBps(uint16 newDefaultFeeBps) external restricted {
        _setDefaultFeeBps(newDefaultFeeBps);
    }

    /// @notice Sets the signer to be used for signature verification.
    /// @param signer Address of the signer to set.
    /// @param whitelistAsSigner Whether the signer is enabled for signature verification.
    function setSigner(address signer, bool whitelistAsSigner) external restricted {
        $storage().isSigner[signer] = whitelistAsSigner;
    }

    /// @notice Allows a whitelisted signer to invalidate their own nonce.
    /// @dev Useful for cancelling a signed fee discount before it's used.
    /// @param signer The signer whose nonce to invalidate (must be msg.sender).
    /// @param nonce The nonce to invalidate.
    function invalidateNonce(address signer, uint256 nonce) external {
        require(msg.sender == signer, Errors.NotAuthorized());
        require($storage().isSigner[signer], Errors.NotAuthorized());
        require($storage().wasNonceUsed[signer][nonce] == false, NonceAlreadyUsed());
        _markNonceAsUsed(signer, nonce);
    }

    //////////////////////////////// INTERNAL FUNCTIONS ////////////////////////////////

    /// @dev Returns: (uint256 amountOutRay, address signer, uint256 nonce).
    function _previewWithdrawalPolicy(WithdrawalRequest calldata request)
        internal
        view
        returns (uint256, address, uint256)
    {
        address signer;
        uint256 nonce;
        uint16 feeBps = _getAssetFeeBps(request.assetOut);
        if (request.data.length > 0) {
            uint16 personalFeeBps;
            (signer, nonce, personalFeeBps) = _verifySignedDiscount(request);
            if (personalFeeBps < feeBps) {
                feeBps = personalFeeBps;
            }
        }
        uint256 feeAmountRay = (request.iouAmountRay * feeBps + Constants.MAX_BPS - 1) / Constants.MAX_BPS;
        return (request.iouAmountRay - feeAmountRay, signer, nonce);
    }

    function _markNonceAsUsed(address signer, uint256 nonce) internal {
        $storage().wasNonceUsed[signer][nonce] = true;
        emit NonceUsed(signer, nonce);
    }

    /// @dev Verifies a signed fee discount and returns the signer, nonce, and personal fee.
    /// @return signer The address that signed the discount.
    /// @return nonce The nonce from the signed discount.
    /// @return personalFeeBps The personal fee from the signed discount.
    function _verifySignedDiscount(WithdrawalRequest calldata request)
        internal
        view
        returns (address signer, uint256 nonce, uint16 personalFeeBps)
    {
        SignedFeeDiscount memory discount = abi.decode(request.data, (SignedFeeDiscount));

        require(discount.deadline >= block.timestamp, DeadlineExpired());

        signer = _recoverSigner(request, discount);
        require($storage().isSigner[signer], InvalidSignature());
        require(!$storage().wasNonceUsed[signer][discount.nonce], NonceAlreadyUsed());

        return (signer, discount.nonce, discount.personalFeeBps);
    }

    /// @dev Recovers the signer address from the EIP-712 signature.
    function _recoverSigner(WithdrawalRequest calldata request, SignedFeeDiscount memory discount)
        internal
        view
        returns (address)
    {
        bytes32 structHash = EfficientHashLib.hash(
            abi.encode(
                FEE_DISCOUNT_TYPEHASH,
                request.user,
                request.assetOut,
                request.iouAmountRay,
                discount.personalFeeBps,
                discount.nonce,
                discount.deadline
            )
        );
        return ECDSA.recover(_hashTypedDataV4(structHash), discount.signature);
    }

    /// @dev Returns the fee for an asset (asset-specific or default fallback).
    function _getAssetFeeBps(address assetOut) internal view returns (uint16) {
        if ($storage().assetFeeConfigs[assetOut].isSet) {
            return $storage().assetFeeConfigs[assetOut].feeBps;
        } else {
            return $storage().defaultFeeBps;
        }
    }

    function _setDefaultFeeBps(uint16 newDefaultFeeBps) internal {
        require(newDefaultFeeBps <= FEE_CAP_BPS, Errors.InvalidParameter());
        $storage().defaultFeeBps = newDefaultFeeBps;
        emit DefaultFeeBpsSet(newDefaultFeeBps);
    }
}

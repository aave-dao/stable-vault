// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {EfficientHashLib} from "@solady/utils/EfficientHashLib.sol";

import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {IWithdrawalPolicy} from "src/interfaces/IWithdrawalPolicy.sol";
import {ConstantsLib} from "src/libraries/ConstantsLib.sol";
import {ErrorsLib} from "src/libraries/ErrorsLib.sol";

/// @title WithdrawalPolicy
/// @author Aave Labs
/// @notice Contract used to enforce withdrawal policies such as fees.
/// @dev Withdrawal fees are calculated based on personal fees, asset-specific fees, or a fallback fee.
/// @dev Withdrawal fees are in basis points (bps) and are applied to the IOU tokens being exchanged for assets.
/// @dev This contract does not take ownership of the fee. It is expected the client of this contract takes the fee
/// returned by this contract.
contract WithdrawalPolicy is AccessManaged, EIP712, IWithdrawalPolicy {
    /// @notice Thrown when a recovered signer is not a whitelisted signer.
    /// @custom:selector 0x8baa579f
    error InvalidSignature();

    // EIP-712 typeHash:
    // keccak256("WithdrawalFee(address user,address assetOut,uint256 iouAmountRay,uint16 personalFee)").
    bytes32 public constant WITHDRAWAL_FEE_TYPEHASH =
        0x54fba3749597da90eaf91d291455c28cbcff7df8b965c964e65b00308f73e31c;

    address internal immutable ASSET_REGISTRY;

    /// @custom:storage-location erc7201:aave.storage.WithdrawalPolicy
    struct WithdrawalPolicyStorage {
        uint16 basicFeeBps;
        mapping(address asset => AssetFeeBpsConfig assetFeeBpsConfig) feeBpsConfigByAsset;
        mapping(address signer => bool isSigner) signers;
    }

    /// @notice Configuration for an asset-specific fee.
    /// @param feeBps The fee in basis points.
    /// @param isSet Whether the fee is set used for lookups.
    struct AssetFeeBpsConfig {
        uint16 feeBps;
        bool isSet;
    }

    // keccak256(abi.encode(uint256(keccak256("aave.storage.WithdrawalPolicy")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT_WITHDRAWAL_POLICY =
        0x48eb1b6299cf8fd4c062909cb421828ec45d2e192a5da81d7bd68b7aecc6f800;

    function $storage() private pure returns (WithdrawalPolicyStorage storage _storage) {
        assembly {
            _storage.slot := STORAGE_SLOT_WITHDRAWAL_POLICY
        }
    }

    /// @dev Constructor.
    /// @param accessManager Address of the IAccessManager contract used for handling access control.
    /// @param assetRegistry Address of the AssetRegistry contract used for managing asset configurations.
    constructor(address accessManager, address assetRegistry)
        EIP712("WithdrawalPolicy", "1")
        AccessManaged(accessManager)
    {
        ASSET_REGISTRY = assetRegistry;
    }

    function getAssetFeeBpsConfig(address asset) external view returns (AssetFeeBpsConfig memory) {
        return $storage().feeBpsConfigByAsset[asset];
    }

    function getBasicFeeBps() external view returns (uint16) {
        return $storage().basicFeeBps;
    }

    function isSigner(address signer) external view returns (bool) {
        return $storage().signers[signer];
    }

    /// @inheritdoc IWithdrawalPolicy
    function evaluateWithdrawal(address user, address assetOut, uint256 iouAmountRay, bytes memory data)
        external
        view
        override
        returns (uint256, uint16)
    {
        // Validate the asset can be withdrawn.
        require(IAssetRegistry(ASSET_REGISTRY).isUserWithdrawalAllowed(assetOut), ErrorsLib.UnsupportedAsset(assetOut));

        // Calculate and return the withdrawal fee data.
        return _calculateWithdrawalFee(user, assetOut, iouAmountRay, data);
    }

    // Restricted functions

    function setAssetFeeBps(address asset, uint16 newAssetFeeBps, bool isSet) external restricted {
        // We don't check for new asset fee being less than the basic fee because maybe we want some specific asset to
        // have a higher fee than the basic fee.
        require(newAssetFeeBps <= ConstantsLib.MAX_BPS, ErrorsLib.InvalidParameter());
        $storage().feeBpsConfigByAsset[asset].feeBps = newAssetFeeBps;
        $storage().feeBpsConfigByAsset[asset].isSet = isSet;
    }

    function setBasicFeeBps(uint16 newBasicFeeBps) external restricted {
        require(newBasicFeeBps <= ConstantsLib.MAX_BPS, ErrorsLib.InvalidParameter());
        $storage().basicFeeBps = newBasicFeeBps;
    }

    function setSigner(address signer, bool whitelistedSigner) external restricted {
        $storage().signers[signer] = whitelistedSigner;
    }

    function _calculateWithdrawalFee(address user, address assetOut, uint256 iouAmountRay, bytes memory data)
        internal
        view
        returns (uint256, uint16)
    {
        if (data.length > 0) {
            // There is a personal fee that should be parsed out and verified.
            (uint16 personalFeeBps, bytes memory signature) = abi.decode(data, (uint16, bytes));
            // Personal fee cannot be higher than non-personal one (asset-specific or basic, whatever is applied by
            // default).
            if ($storage().feeBpsConfigByAsset[assetOut].isSet) {
                require(personalFeeBps <= $storage().feeBpsConfigByAsset[assetOut].feeBps, ErrorsLib.InvalidParameter());
            } else {
                require(personalFeeBps <= $storage().basicFeeBps, ErrorsLib.InvalidParameter());
            }
            _validateSignature(user, assetOut, iouAmountRay, personalFeeBps, signature);
            return (iouAmountRay * personalFeeBps / ConstantsLib.MAX_BPS, personalFeeBps);
        } else if ($storage().feeBpsConfigByAsset[assetOut].isSet) {
            // There is an asset-specific fee - we apply it.
            return (
                iouAmountRay * $storage().feeBpsConfigByAsset[assetOut].feeBps / ConstantsLib.MAX_BPS,
                $storage().feeBpsConfigByAsset[assetOut].feeBps
            );
        } else {
            // There's no personal or asset-specific fee, so we apply the default basic fee.
            return (iouAmountRay * $storage().basicFeeBps / ConstantsLib.MAX_BPS, $storage().basicFeeBps);
        }
    }

    function _validateSignature(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint16 personalFeeBps,
        bytes memory signature
    ) internal view {
        bytes32 structHash = EfficientHashLib.hash(
            abi.encode(WITHDRAWAL_FEE_TYPEHASH, user, assetOut, iouAmountRay, personalFeeBps)
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        if (!$storage().signers[signer]) {
            revert InvalidSignature();
        }
    }
}

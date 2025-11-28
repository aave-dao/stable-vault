// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {EfficientHashLib} from "@solady/utils/EfficientHashLib.sol";

import {IWithdrawalFeeCalculator} from "../interfaces/IWithdrawalFeeCalculator.sol";
import {ConstantsLib} from "../libraries/ConstantsLib.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";

/// @title WithdrawalFeeCalculator
/// @author Aave Labs
/// @notice Contract for calculating withdrawal fees based on personal fees, asset-specific fees, and basic fees.
/// @dev This contract does not take ownership of the fee. It is expected the client of this contract takes the fee
/// returned by this contract.
contract WithdrawalFeeCalculator is AccessManaged, EIP712, IWithdrawalFeeCalculator {
    // EIP-712 typeHash:
    // keccak256("WithdrawalFee(address user,address assetOut,uint256 iouAmountRay,uint256 personalFee)").
    bytes32 public constant WITHDRAWAL_FEE_TYPEHASH =
        0x70053184e810124de211241896d50cf6caf42eac7fb6ee3f16afe61ee6a3f1b2;

    /// @custom:storage-location erc7201:aave.storage.WithdrawalFeeCalculator
    struct WithdrawalFeeCalculatorStorage {
        uint256 basicFeeBps;
        mapping(address asset => AssetFeeBpsConfig assetFeeBpsConfig) feeBpsConfigByAsset;
        mapping(address signer => bool isSigner) signers;
    }

    // keccak256(abi.encode(uint256(keccak256("aave.storage.WithdrawalFeeCalculator")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT_WITHDRAWAL_FEE_CALCULATOR =
        0xb4766a4633e61aded0a93de3a0e2b80dc0041dc0533fcc8f3fdb067abd96b000;

    function $storage() private pure returns (WithdrawalFeeCalculatorStorage storage _storage) {
        assembly {
            _storage.slot := STORAGE_SLOT_WITHDRAWAL_FEE_CALCULATOR
        }
    }

    function $WithdrawalFeeCalculator() internal pure returns (WithdrawalFeeCalculatorStorage storage) {
        return $storage();
    }

    /// @dev Constructor.
    /// @param accessManager Address of the IAccessManager contract used for handling access control.
    constructor(address accessManager) EIP712("WithdrawalFeeCalculator", "1") AccessManaged(accessManager) {}

    // TODO: Should we replace this with two getters? getAssetFeeBps and isAssetFeeBpsSet?
    /// @inheritdoc IWithdrawalFeeCalculator
    function getAssetFeeBpsConfig(address asset) external view override returns (AssetFeeBpsConfig memory) {
        return $storage().feeBpsConfigByAsset[asset];
    }

    /// @inheritdoc IWithdrawalFeeCalculator
    function getBasicFeeBps() external view override returns (uint256) {
        return $storage().basicFeeBps;
    }

    /// @inheritdoc IWithdrawalFeeCalculator
    function isSigner(address signer) external view override returns (bool) {
        return $storage().signers[signer];
    }

    /// @inheritdoc IWithdrawalFeeCalculator
    function calculateWithdrawalFee(address user, address assetOut, uint256 iouAmountRay, bytes memory data)
        external
        view
        override
        returns (uint256)
    {
        if (data.length > 0) {
            // There is a personal fee.
            (uint256 personalFeeBps, bytes memory signature) = abi.decode(data, (uint256, bytes));
            // Personal fee cannot be higher than non-personal one (asset-specific or basic, whatever is applied by
            // default).
            if ($storage().feeBpsConfigByAsset[assetOut].isSet) {
                require(personalFeeBps <= $storage().feeBpsConfigByAsset[assetOut].feeBps, ErrorsLib.InvalidParameter());
            } else {
                require(personalFeeBps <= $storage().basicFeeBps, ErrorsLib.InvalidParameter());
            }
            _validateSignature(user, assetOut, iouAmountRay, personalFeeBps, signature);
            return iouAmountRay * personalFeeBps / ConstantsLib.MAX_BPS;
        } else if ($storage().feeBpsConfigByAsset[assetOut].isSet) {
            // There is an asset-specific fee - we apply it.
            return iouAmountRay * $storage().feeBpsConfigByAsset[assetOut].feeBps / ConstantsLib.MAX_BPS;
        } else {
            // There's no personal or asset-specific fee, so we apply the default basic fee.
            return iouAmountRay * $storage().basicFeeBps / ConstantsLib.MAX_BPS;
        }
    }

    // Restricted functions

    /// @inheritdoc IWithdrawalFeeCalculator
    function setAssetFeeBps(address asset, uint256 newAssetFeeBps, bool isSet) external override restricted {
        // We don't check for new asset fee being less than the basic fee because maybe we want some specific asset to
        // have a higher fee than the basic fee.
        require(newAssetFeeBps <= ConstantsLib.MAX_BPS, ErrorsLib.InvalidParameter());
        // forge-lint: disable-next-line(unsafe-typecast)
        $storage().feeBpsConfigByAsset[asset].feeBps = uint16(newAssetFeeBps);
        $storage().feeBpsConfigByAsset[asset].isSet = isSet;
    }

    /// @inheritdoc IWithdrawalFeeCalculator
    function setBasicFeeBps(uint256 newBasicFeeBps) external override restricted {
        require(newBasicFeeBps <= ConstantsLib.MAX_BPS, ErrorsLib.InvalidParameter());
        $storage().basicFeeBps = newBasicFeeBps;
    }

    /// @inheritdoc IWithdrawalFeeCalculator
    function setSigner(address signer, bool whitelistedSigner) external override restricted {
        $storage().signers[signer] = whitelistedSigner;
    }

    function _validateSignature(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeBps,
        bytes memory signature
    ) internal view {
        // TODO: Should we replace this weird contraption with ignore lint [asm-keccak256]?
        // This saves a bit of gas, but looks non-standard.
        bytes32 structHash =
            EfficientHashLib.hash(abi.encode(WITHDRAWAL_FEE_TYPEHASH, user, assetOut, iouAmountRay, personalFeeBps));
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        if (!$storage().signers[signer]) {
            revert InvalidSignature();
        }
    }
}

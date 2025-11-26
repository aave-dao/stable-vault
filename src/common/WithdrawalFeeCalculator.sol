// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {EfficientHashLib} from "@solady/utils/EfficientHashLib.sol";

import {IWithdrawalFeeCalculator} from "../interfaces/IWithdrawalFeeCalculator.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";

contract WithdrawalFeeCalculator is AccessManaged, EIP712, IWithdrawalFeeCalculator {
    bytes32 public constant WITHDRAWAL_FEE_TYPEHASH =
        keccak256("WithdrawalFee(address user,address assetOut,uint256 iouAmountRay,uint256 personalFee)");

    uint256 internal constant BPS_BASE = 100_00; // TODO: Should we move this to constants lib?

    error InvalidSignature();

    struct AssetFeeBpsConfig {
        uint16 feeBps; // TODO: Remember which order these need to be and if that matters for further storage extension.
        bool isSet;
    }

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

    // TODO: I don't think this is needed:
    // function $WithdrawalFeeCalculator() internal pure returns (WithdrawalFeeCalculatorStorage storage) {
    //     return $storage();
    // }

    constructor(address accessManager) EIP712("WithdrawalFeeCalculator", "1") AccessManaged(accessManager) {}

    function calculateWithdrawalFee(address user, address assetOut, uint256 iouAmountRay, bytes memory data)
        external
        view
        override
        returns (uint256)
    {
        if (data.length > 0) {
            // Is there a personal fee?
            (uint256 personalFeeBps, bytes memory signature) = abi.decode(data, (uint256, bytes));
            if ($storage().feeBpsConfigByAsset[assetOut].isSet) {
                require(personalFeeBps <= $storage().feeBpsConfigByAsset[assetOut].feeBps, ErrorsLib.InvalidParameter());
            } else {
                require(personalFeeBps <= $storage().basicFeeBps, ErrorsLib.InvalidParameter());
            }
            _validateSignature(user, assetOut, iouAmountRay, personalFeeBps, signature);
            return iouAmountRay * personalFeeBps / 10000;
        } else if ($storage().feeBpsConfigByAsset[assetOut].isSet) {
            // Is there an asset-specific fee?
            return iouAmountRay * $storage().feeBpsConfigByAsset[assetOut].feeBps / 10000;
        } else {
            // There's no personal or asset-specific fee, so it's the basic fee.
            return iouAmountRay * $storage().basicFeeBps / 10000;
        }
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

    function setBasicFeeBps(uint256 newBasicFeeBps) external restricted {
        // TODO: We cannot verify that this wouldn't suddenly become less than any of the asset-specific fees.
        // But should we?
        $storage().basicFeeBps = newBasicFeeBps;
    }

    function setAssetFeeBps(address asset, uint256 newAssetFeeBps, bool isSet) external restricted {
        require(newAssetFeeBps <= BPS_BASE, ErrorsLib.InvalidParameter());
        // forge-lint: disable-next-line(unsafe-typecast)
        $storage().feeBpsConfigByAsset[asset].feeBps = uint16(newAssetFeeBps);
        $storage().feeBpsConfigByAsset[asset].isSet = isSet;
    }

    function setSigner(address signer, bool whitelistedSigner) external restricted {
        $storage().signers[signer] = whitelistedSigner;
    }

    function getBasicFeeBps() external view returns (uint256) {
        return $storage().basicFeeBps;
    }

    // TODO: Should we replace this with two getters? getAssetFeeBps and isAssetFeeBpsSet?
    function getAssetFeeBpsConfig(address asset) external view returns (AssetFeeBpsConfig memory) {
        return $storage().feeBpsConfigByAsset[asset];
    }

    function isSigner(address signer) external view returns (bool) {
        return $storage().signers[signer];
    }
}

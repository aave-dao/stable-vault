// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IWithdrawalFeeCalculator} from "../interfaces/IWithdrawalFeeCalculator.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";

contract WithdrawalFeeCalculator is IWithdrawalFeeCalculator, Ownable, EIP712 {
    bytes32 public constant WITHDRAWAL_FEE_TYPEHASH =
        keccak256("WithdrawalFee(address user,address assetOut,uint256 iouAmountRay,uint256 personalFee)");

    error InvalidSignature();

    /// @custom:storage-location erc7201:aave.storage.WithdrawalFeeCalculator
    struct WithdrawalFeeCalculatorStorage {
        uint256 basicFee;
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

    constructor(address owner) Ownable(owner) EIP712("WithdrawalFeeCalculator", "1") {}

    function calculateWithdrawalFee(address user, address assetOut, uint256 iouAmountRay, bytes memory data)
        external
        view
        override
        returns (uint256)
    {
        if (data.length > 0) {
            (uint256 personalFee, bytes memory signature) = abi.decode(data, (uint256, bytes));
            _validateSignature(user, assetOut, iouAmountRay, personalFee, signature);
            return personalFee;
        }
        return $storage().basicFee;
    }

    function _validateSignature(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFee,
        bytes memory signature
    ) internal view {
        bytes32 structHash = keccak256(abi.encode(WITHDRAWAL_FEE_TYPEHASH, user, assetOut, iouAmountRay, personalFee));
        bytes32 digest = _hashTypedDataV4(structHash);
        address signer = ECDSA.recover(digest, signature);
        if (!$storage().signers[signer]) {
            revert InvalidSignature();
        }
    }

    function setBasicFee(uint256 newBasicFee) external onlyOwner {
        $storage().basicFee = newBasicFee;
    }

    function setSigner(address signer, bool whitelistedSigner) external onlyOwner {
        $storage().signers[signer] = whitelistedSigner;
    }

    function getBasicFee() external view returns (uint256) {
        return $storage().basicFee;
    }

    function isSigner(address signer) external view returns (bool) {
        return $storage().signers[signer];
    }
}

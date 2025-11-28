// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";

import {WithdrawalFeeCalculator} from "../../../src/common/WithdrawalFeeCalculator.sol";
import {IWithdrawalFeeCalculator} from "../../../src/interfaces/IWithdrawalFeeCalculator.sol";
import {ConstantsLib} from "../../../src/libraries/ConstantsLib.sol";
import {ErrorsLib} from "../../../src/libraries/ErrorsLib.sol";
import {TestWithHelpers} from "../../helpers/TestWithHelpers.sol";
import {MockAccessManager} from "../../mocks/MockAccessManager.sol";

contract WithdrawalFeeCalculatorTest is TestWithHelpers {
    WithdrawalFeeCalculator withdrawalFeeCalculator;
    MockAccessManager mockAccessManager;
    address admin = makeAddr("admin");

    function setUp() public {
        mockAccessManager = new MockAccessManager(admin);
        withdrawalFeeCalculator = new WithdrawalFeeCalculator(address(mockAccessManager));
    }

    // Restricted functions access control tests

    function test_setAssetFeeBps_reverts_ifMsgSenderIsNotAuthorized(
        address unauthorizedMsgSender,
        address asset,
        uint256 newAssetFeeBps,
        bool isSet
    ) public {
        vm.assume(unauthorizedMsgSender != address(0));

        mockAccessManager.mockRejectCall(
            unauthorizedMsgSender, address(withdrawalFeeCalculator), IWithdrawalFeeCalculator.setAssetFeeBps.selector
        );

        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedMsgSender)
        );
        vm.prank(unauthorizedMsgSender);
        withdrawalFeeCalculator.setAssetFeeBps(asset, newAssetFeeBps, isSet);
    }

    function test_setBasicFeeBps_reverts_ifMsgSenderIsNotAuthorized(
        address unauthorizedMsgSender,
        uint256 newBasicFeeBps
    ) public {
        vm.assume(unauthorizedMsgSender != address(0));

        mockAccessManager.mockRejectCall(
            unauthorizedMsgSender, address(withdrawalFeeCalculator), IWithdrawalFeeCalculator.setBasicFeeBps.selector
        );

        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedMsgSender)
        );
        vm.prank(unauthorizedMsgSender);
        withdrawalFeeCalculator.setBasicFeeBps(newBasicFeeBps);
    }

    function test_setSigner_reverts_ifMsgSenderIsNotAuthorized(
        address unauthorizedMsgSender,
        address signer,
        bool whitelistedSigner
    ) public {
        vm.assume(unauthorizedMsgSender != address(0));

        mockAccessManager.mockRejectCall(
            unauthorizedMsgSender, address(withdrawalFeeCalculator), IWithdrawalFeeCalculator.setSigner.selector
        );

        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedMsgSender)
        );
        vm.prank(unauthorizedMsgSender);
        withdrawalFeeCalculator.setSigner(signer, whitelistedSigner);
    }

    // Setters & Getters tests

    function test_setAssetFeeBps_setsExpectedConfig(address asset, uint256 feeBps, bool isSet) public {
        feeBps = bound(feeBps, 0, 10_000); // ConstantsLib.MAX_BPS

        vm.prank(admin);
        withdrawalFeeCalculator.setAssetFeeBps(asset, feeBps, isSet);

        IWithdrawalFeeCalculator.AssetFeeBpsConfig memory config = withdrawalFeeCalculator.getAssetFeeBpsConfig(asset);
        assertEq(config.feeBps, feeBps);
        assertEq(config.isSet, isSet);
    }

    function test_setAssetFeeBps_reverts_ifFeeBpsIsInvalid(address asset, uint256 feeBps, bool isSet) public {
        feeBps = bound(feeBps, 10_001, type(uint256).max);

        vm.expectRevert(ErrorsLib.InvalidParameter.selector);
        vm.prank(admin);
        withdrawalFeeCalculator.setAssetFeeBps(asset, feeBps, isSet);
    }

    function test_setBasicFeeBps_setsExpectedFee(uint256 feeBps) public {
        feeBps = bound(feeBps, 0, ConstantsLib.MAX_BPS);

        vm.prank(admin);
        withdrawalFeeCalculator.setBasicFeeBps(feeBps);

        assertEq(withdrawalFeeCalculator.getBasicFeeBps(), feeBps);
    }

    function test_setBasicFeeBps_reverts_ifFeeBpsIsInvalid(uint256 feeBps) public {
        feeBps = bound(feeBps, ConstantsLib.MAX_BPS + 1, type(uint256).max);

        vm.expectRevert(ErrorsLib.InvalidParameter.selector);
        vm.prank(admin);
        withdrawalFeeCalculator.setBasicFeeBps(feeBps);
    }

    function test_setSigner_setsSignerStatus(address signer, bool isSigner) public {
        vm.prank(admin);
        withdrawalFeeCalculator.setSigner(signer, isSigner);

        assertEq(withdrawalFeeCalculator.isSigner(signer), isSigner);
    }

    // Calculation tests

    function test_calculateWithdrawalFee_returnsBaseFee(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 baseFeeBps
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, ConstantsLib.MAX_BPS);
        iouAmountRay = bound(iouAmountRay, 0, type(uint256).max / ConstantsLib.MAX_BPS);

        vm.prank(admin);
        withdrawalFeeCalculator.setBasicFeeBps(baseFeeBps);

        uint256 expectedFee = iouAmountRay * baseFeeBps / ConstantsLib.MAX_BPS;

        assertFalse(withdrawalFeeCalculator.getAssetFeeBpsConfig(assetOut).isSet, "Asset fee is set");

        bytes memory data = "";
        uint256 actualFee = withdrawalFeeCalculator.calculateWithdrawalFee(user, assetOut, iouAmountRay, data);
        assertEq(actualFee, expectedFee);
    }

    function test_calculateWithdrawalFee_returnsAssetFee(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 assetFeeBps,
        uint256 baseFeeBps
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, ConstantsLib.MAX_BPS);
        assetFeeBps = bound(assetFeeBps, 0, ConstantsLib.MAX_BPS);
        iouAmountRay = bound(iouAmountRay, 0, type(uint256).max / ConstantsLib.MAX_BPS);

        vm.prank(admin);
        withdrawalFeeCalculator.setBasicFeeBps(baseFeeBps);
        assertEq(withdrawalFeeCalculator.getBasicFeeBps(), baseFeeBps);

        vm.prank(admin);
        withdrawalFeeCalculator.setAssetFeeBps(assetOut, assetFeeBps, true);

        uint256 expectedFee = iouAmountRay * assetFeeBps / ConstantsLib.MAX_BPS;

        assertTrue(withdrawalFeeCalculator.getAssetFeeBpsConfig(assetOut).isSet, "Asset fee is not set");
        assertEq(withdrawalFeeCalculator.getAssetFeeBpsConfig(assetOut).feeBps, assetFeeBps);

        bytes memory data = "";
        uint256 actualFee = withdrawalFeeCalculator.calculateWithdrawalFee(user, assetOut, iouAmountRay, data);
        assertEq(actualFee, expectedFee);
    }

    function test_calculateWithdrawalFee_returnsPersonalFee(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeBps,
        bool isAssetFeeSet,
        uint256 assetFeeBps,
        uint256 baseFeeBps
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, ConstantsLib.MAX_BPS);
        assetFeeBps = bound(assetFeeBps, 0, ConstantsLib.MAX_BPS);
        if (isAssetFeeSet) {
            personalFeeBps = bound(personalFeeBps, 0, assetFeeBps);
        } else {
            personalFeeBps = bound(personalFeeBps, 0, baseFeeBps);
        }
        iouAmountRay = bound(iouAmountRay, 0, type(uint256).max / ConstantsLib.MAX_BPS);

        // Setup base fee
        vm.prank(admin);
        withdrawalFeeCalculator.setBasicFeeBps(baseFeeBps);

        // Setup asset fee
        if (isAssetFeeSet) {
            vm.prank(admin);
            withdrawalFeeCalculator.setAssetFeeBps(assetOut, assetFeeBps, true);
        }

        // Create signer wallet and whitelist it
        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalFeeCalculator.setSigner(signer, true);
        assertTrue(withdrawalFeeCalculator.isSigner(signer), "Signer is not whitelisted");

        // Build EIP712 signature
        bytes memory signature = _signPersonalFee(signerPk, user, assetOut, iouAmountRay, personalFeeBps);

        uint256 expectedFee = iouAmountRay * personalFeeBps / ConstantsLib.MAX_BPS;

        bytes memory data = abi.encode(personalFeeBps, signature);
        uint256 actualFee = withdrawalFeeCalculator.calculateWithdrawalFee(user, assetOut, iouAmountRay, data);
        assertEq(actualFee, expectedFee);
    }

    function test_calculateWithdrawalFee_reverts_ifPersonalFeeExceedsOtherFees(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeBps,
        bool isAssetFeeSet,
        uint256 assetFeeBps,
        uint256 baseFeeBps
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, ConstantsLib.MAX_BPS);
        assetFeeBps = bound(assetFeeBps, 0, ConstantsLib.MAX_BPS);
        if (isAssetFeeSet) {
            personalFeeBps = bound(personalFeeBps, assetFeeBps + 1, type(uint256).max);
        } else {
            personalFeeBps = bound(personalFeeBps, baseFeeBps + 1, type(uint256).max);
        }
        iouAmountRay = bound(iouAmountRay, 0, type(uint256).max / ConstantsLib.MAX_BPS);

        // Setup base fee
        vm.prank(admin);
        withdrawalFeeCalculator.setBasicFeeBps(baseFeeBps);

        // Setup asset fee
        if (isAssetFeeSet) {
            vm.prank(admin);
            withdrawalFeeCalculator.setAssetFeeBps(assetOut, assetFeeBps, true);
        }

        // Create signer wallet and whitelist it
        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalFeeCalculator.setSigner(signer, true);
        assertTrue(withdrawalFeeCalculator.isSigner(signer), "Signer is not whitelisted");

        // Build EIP712 signature
        bytes memory signature = _signPersonalFee(signerPk, user, assetOut, iouAmountRay, personalFeeBps);

        bytes memory data = abi.encode(personalFeeBps, signature);
        vm.expectRevert(ErrorsLib.InvalidParameter.selector);
        withdrawalFeeCalculator.calculateWithdrawalFee(user, assetOut, iouAmountRay, data);
    }

    function test_calculateWithdrawalFee_reverts_ifSignerIsNotWhitelisted(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeBps,
        uint256 baseFeeBps,
        uint256 nonWhitelistedSignerPk
    ) public {
        // Secp256k1 curve order
        uint256 SECP256K1_ORDER = 115792089237316195423570985008687907852837564279074904382605163141518161494337;
        nonWhitelistedSignerPk = bound(nonWhitelistedSignerPk, 1, SECP256K1_ORDER - 1);
        address nonWhitelistedSigner = vm.addr(nonWhitelistedSignerPk);
        vm.assume(withdrawalFeeCalculator.isSigner(nonWhitelistedSigner) == false);

        baseFeeBps = bound(baseFeeBps, 0, ConstantsLib.MAX_BPS);
        personalFeeBps = bound(personalFeeBps, 0, baseFeeBps);
        iouAmountRay = bound(iouAmountRay, 0, type(uint256).max / ConstantsLib.MAX_BPS);

        // Setup base fee
        vm.prank(admin);
        withdrawalFeeCalculator.setBasicFeeBps(baseFeeBps);

        // Build EIP712 signature with non-whitelisted signer
        bytes memory signature = _signPersonalFee(nonWhitelistedSignerPk, user, assetOut, iouAmountRay, personalFeeBps);

        bytes memory data = abi.encode(personalFeeBps, signature);
        vm.expectRevert(WithdrawalFeeCalculator.InvalidSignature.selector);
        withdrawalFeeCalculator.calculateWithdrawalFee(user, assetOut, iouAmountRay, data);
    }

    function test_calculateWithdrawalFee_reverts_ifSignatureIsForDifferentUser(
        address user,
        address wrongUser,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeBps,
        uint256 baseFeeBps
    ) public {
        vm.assume(user != wrongUser);
        baseFeeBps = bound(baseFeeBps, 0, ConstantsLib.MAX_BPS);
        personalFeeBps = bound(personalFeeBps, 0, baseFeeBps);
        iouAmountRay = bound(iouAmountRay, 0, type(uint256).max / ConstantsLib.MAX_BPS);

        // Setup base fee
        vm.prank(admin);
        withdrawalFeeCalculator.setBasicFeeBps(baseFeeBps);

        // Create signer wallet and whitelist it
        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalFeeCalculator.setSigner(signer, true);

        // Build EIP712 signature for WRONG user
        bytes memory signature = _signPersonalFee(signerPk, wrongUser, assetOut, iouAmountRay, personalFeeBps);

        bytes memory data = abi.encode(personalFeeBps, signature);
        vm.expectRevert(WithdrawalFeeCalculator.InvalidSignature.selector);
        withdrawalFeeCalculator.calculateWithdrawalFee(user, assetOut, iouAmountRay, data);
    }

    function test_calculateWithdrawalFee_reverts_ifSignatureIsForDifferentAsset(
        address user,
        address assetOut,
        address wrongAssetOut,
        uint256 iouAmountRay,
        uint256 personalFeeBps,
        uint256 baseFeeBps
    ) public {
        vm.assume(assetOut != wrongAssetOut);
        baseFeeBps = bound(baseFeeBps, 0, ConstantsLib.MAX_BPS);
        personalFeeBps = bound(personalFeeBps, 0, baseFeeBps);
        iouAmountRay = bound(iouAmountRay, 0, type(uint256).max / ConstantsLib.MAX_BPS);

        // Setup base fee
        vm.prank(admin);
        withdrawalFeeCalculator.setBasicFeeBps(baseFeeBps);

        // Create signer wallet and whitelist it
        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalFeeCalculator.setSigner(signer, true);

        // Build EIP712 signature for WRONG asset
        bytes memory signature = _signPersonalFee(signerPk, user, wrongAssetOut, iouAmountRay, personalFeeBps);

        bytes memory data = abi.encode(personalFeeBps, signature);
        vm.expectRevert(WithdrawalFeeCalculator.InvalidSignature.selector);
        withdrawalFeeCalculator.calculateWithdrawalFee(user, assetOut, iouAmountRay, data);
    }

    function test_calculateWithdrawalFee_reverts_ifSignatureIsForDifferentAmount(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 wrongIouAmountRay,
        uint256 personalFeeBps,
        uint256 baseFeeBps
    ) public {
        vm.assume(iouAmountRay != wrongIouAmountRay);
        baseFeeBps = bound(baseFeeBps, 0, ConstantsLib.MAX_BPS);
        personalFeeBps = bound(personalFeeBps, 0, baseFeeBps);
        iouAmountRay = bound(iouAmountRay, 0, type(uint256).max / ConstantsLib.MAX_BPS);
        wrongIouAmountRay = bound(wrongIouAmountRay, 0, type(uint256).max / ConstantsLib.MAX_BPS);
        vm.assume(iouAmountRay != wrongIouAmountRay);

        // Setup base fee
        vm.prank(admin);
        withdrawalFeeCalculator.setBasicFeeBps(baseFeeBps);

        // Create signer wallet and whitelist it
        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalFeeCalculator.setSigner(signer, true);

        // Build EIP712 signature for WRONG amount
        bytes memory signature = _signPersonalFee(signerPk, user, assetOut, wrongIouAmountRay, personalFeeBps);

        bytes memory data = abi.encode(personalFeeBps, signature);
        vm.expectRevert(WithdrawalFeeCalculator.InvalidSignature.selector);
        withdrawalFeeCalculator.calculateWithdrawalFee(user, assetOut, iouAmountRay, data);
    }

    function test_calculateWithdrawalFee_reverts_ifSignatureIsForDifferentPersonalFee(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeBps,
        uint256 wrongPersonalFeeBps,
        uint256 baseFeeBps
    ) public {
        vm.assume(personalFeeBps != wrongPersonalFeeBps);
        baseFeeBps = bound(baseFeeBps, 0, ConstantsLib.MAX_BPS);
        personalFeeBps = bound(personalFeeBps, 0, baseFeeBps);
        wrongPersonalFeeBps = bound(wrongPersonalFeeBps, 0, baseFeeBps);
        vm.assume(personalFeeBps != wrongPersonalFeeBps);
        iouAmountRay = bound(iouAmountRay, 0, type(uint256).max / ConstantsLib.MAX_BPS);

        // Setup base fee
        vm.prank(admin);
        withdrawalFeeCalculator.setBasicFeeBps(baseFeeBps);

        // Create signer wallet and whitelist it
        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalFeeCalculator.setSigner(signer, true);

        // Build EIP712 signature for WRONG personal fee
        bytes memory signature = _signPersonalFee(signerPk, user, assetOut, iouAmountRay, wrongPersonalFeeBps);

        bytes memory data = abi.encode(personalFeeBps, signature);
        vm.expectRevert(WithdrawalFeeCalculator.InvalidSignature.selector);
        withdrawalFeeCalculator.calculateWithdrawalFee(user, assetOut, iouAmountRay, data);
    }

    function test_calculateWithdrawalFee_reverts_ifSignatureIsMalformed(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeBps,
        uint256 baseFeeBps,
        bytes memory malformedSignature
    ) public {
        vm.assume(malformedSignature.length != 65);
        baseFeeBps = bound(baseFeeBps, 0, ConstantsLib.MAX_BPS);
        personalFeeBps = bound(personalFeeBps, 0, baseFeeBps);
        iouAmountRay = bound(iouAmountRay, 0, type(uint256).max / ConstantsLib.MAX_BPS);

        // Setup base fee
        vm.prank(admin);
        withdrawalFeeCalculator.setBasicFeeBps(baseFeeBps);

        // Create signer wallet and whitelist it
        (address signer,) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalFeeCalculator.setSigner(signer, true);

        bytes memory data = abi.encode(personalFeeBps, malformedSignature);
        vm.expectRevert();
        withdrawalFeeCalculator.calculateWithdrawalFee(user, assetOut, iouAmountRay, data);
    }

    function _signPersonalFee(
        uint256 signerPk,
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeBps
    ) internal view returns (bytes memory) {
        bytes32 WITHDRAWAL_FEE_TYPEHASH = keccak256(
            "WithdrawalFee(address user,address assetOut,uint256 iouAmountRay,uint256 personalFee)"
        );

        bytes32 structHash =
            keccak256(abi.encode(WITHDRAWAL_FEE_TYPEHASH, user, assetOut, iouAmountRay, personalFeeBps));

        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("WithdrawalFeeCalculator"),
                keccak256("1"),
                block.chainid,
                address(withdrawalFeeCalculator)
            )
        );

        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }
}

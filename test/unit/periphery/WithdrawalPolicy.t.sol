// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {IWithdrawalPolicy} from "src/interfaces/IWithdrawalPolicy.sol";
import {WithdrawalPolicy} from "src/policies/WithdrawalPolicy.sol";
import {Constants} from "src/types/Constants.sol";
import {Errors} from "src/types/Errors.sol";

import {TestWithHelpers} from "test/helpers/TestWithHelpers.sol";
import {MockAccessManager} from "test/mocks/MockAccessManager.sol";
import {MockAssetRegistry} from "test/mocks/MockAssetRegistry.sol";

contract WithdrawalPolicyTest is TestWithHelpers {
    WithdrawalPolicy withdrawalPolicy;
    MockAccessManager mockAccessManager;
    MockAssetRegistry mockAssetRegistry;
    address admin = makeAddr("admin");

    // Default nonce and deadline for tests
    uint256 constant DEFAULT_NONCE = 1;
    uint256 constant DEFAULT_DEADLINE = type(uint256).max;

    uint16 constant FEE_CAP_BPS = 10_00; // 10.00%

    function _deployWithdrawalPolicy(address accessManager, address withdrawalPolicyApplier)
        internal
        returns (WithdrawalPolicy)
    {
        address withdrawalPolicyImpl = address(new WithdrawalPolicy(withdrawalPolicyApplier));
        return WithdrawalPolicy(
            address(
                new TransparentUpgradeableProxy(
                    withdrawalPolicyImpl, address(this), abi.encodeCall(WithdrawalPolicy.initialize, (accessManager, 0))
                )
            )
        );
    }

    function setUp() public {
        mockAccessManager = new MockAccessManager(admin);
        mockAssetRegistry = new MockAssetRegistry();
        withdrawalPolicy = _deployWithdrawalPolicy(address(mockAccessManager), address(this));
    }

    // Helper to build WithdrawalRequest
    function _buildRequest(address user, address assetOut, uint256 iouAmountRay, bytes memory data)
        internal
        pure
        returns (IWithdrawalPolicy.WithdrawalRequest memory)
    {
        return IWithdrawalPolicy.WithdrawalRequest({
            user: user, assetOut: assetOut, iouAmountRay: iouAmountRay, data: data
        });
    }

    // Constructor tests

    function test_constructor_reverts_ifWithdrawalPolicyApplierIsZeroAddress() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new WithdrawalPolicy(address(0));
    }

    // Restricted functions access control tests

    function test_setAssetFeeBps_reverts_ifMsgSenderIsNotAuthorized(
        address unauthorizedMsgSender,
        address asset,
        uint256 newAssetFeeBps,
        bool isSet
    ) public {
        vm.assume(unauthorizedMsgSender != address(0));
        _assumeNotProxyAdmin(unauthorizedMsgSender, address(withdrawalPolicy));

        mockAccessManager.mockRejectCall(
            unauthorizedMsgSender, address(withdrawalPolicy), WithdrawalPolicy.setAssetFeeBps.selector
        );

        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedMsgSender)
        );
        vm.prank(unauthorizedMsgSender);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setAssetFeeBps(asset, uint16(newAssetFeeBps), isSet);
    }

    function test_setDefaultFeeBps_reverts_ifMsgSenderIsNotAuthorized(
        address unauthorizedMsgSender,
        uint256 newDefaultFeeBps
    ) public {
        vm.assume(unauthorizedMsgSender != address(0));
        _assumeNotProxyAdmin(unauthorizedMsgSender, address(withdrawalPolicy));

        mockAccessManager.mockRejectCall(
            unauthorizedMsgSender, address(withdrawalPolicy), WithdrawalPolicy.setDefaultFeeBps.selector
        );

        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedMsgSender)
        );
        vm.prank(unauthorizedMsgSender);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(newDefaultFeeBps));
    }

    function test_addSigner_reverts_ifMsgSenderIsNotAuthorized(address unauthorizedMsgSender, address signer) public {
        vm.assume(unauthorizedMsgSender != address(0));
        _assumeNotProxyAdmin(unauthorizedMsgSender, address(withdrawalPolicy));
        mockAccessManager.mockRejectCall(
            unauthorizedMsgSender, address(withdrawalPolicy), WithdrawalPolicy.addSigner.selector
        );

        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedMsgSender)
        );
        vm.prank(unauthorizedMsgSender);
        withdrawalPolicy.addSigner(signer);
    }

    function test_removeSigner_reverts_ifMsgSenderIsNotAuthorized(address unauthorizedMsgSender, address signer)
        public
    {
        vm.assume(unauthorizedMsgSender != address(0));
        _assumeNotProxyAdmin(unauthorizedMsgSender, address(withdrawalPolicy));
        mockAccessManager.mockRejectCall(
            unauthorizedMsgSender, address(withdrawalPolicy), WithdrawalPolicy.removeSigner.selector
        );

        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedMsgSender)
        );
        vm.prank(unauthorizedMsgSender);
        withdrawalPolicy.removeSigner(signer);
    }

    // Setters & Getters tests

    function test_setAssetFeeBps_setsExpectedConfig(address asset, uint256 feeBps, bool isSet) public {
        vm.assume(asset != address(0));
        feeBps = bound(feeBps, 0, FEE_CAP_BPS);
        vm.assume(isSet || feeBps == 0);

        vm.expectEmit(true, true, true, true);
        // forge-lint: disable-next-line(unsafe-typecast)
        emit WithdrawalPolicy.AssetFeeBpsSet(asset, uint16(feeBps), isSet);
        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setAssetFeeBps(asset, uint16(feeBps), isSet);

        WithdrawalPolicy.AssetFeeConfig memory config = withdrawalPolicy.getAssetFeeConfig(asset);
        assertEq(config.feeBps, feeBps);
        assertEq(config.isSet, isSet);
    }

    function test_setAssetFeeBps_reverts_ifAssetIsZeroAddress(uint256 feeBps, bool isSet) public {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 feeBps16 = uint16(bound(feeBps, 0, FEE_CAP_BPS));

        vm.expectRevert(Errors.ZeroAddress.selector);
        vm.prank(admin);
        withdrawalPolicy.setAssetFeeBps(address(0), feeBps16, isSet);
    }

    function test_setAssetFeeBps_reverts_ifFeeBpsIsInvalid(address asset, uint256 feeBps, bool isSet) public {
        vm.assume(asset != address(0));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 feeBps16 = uint16(bound(feeBps, 10_001, type(uint16).max));

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(admin);
        withdrawalPolicy.setAssetFeeBps(asset, feeBps16, isSet);
    }

    function test_setAssetFeeBps_reverts_ifNotSetWithNonZeroFee(address asset, uint256 feeBps) public {
        vm.assume(asset != address(0));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 feeBps16 = uint16(bound(feeBps, 1, FEE_CAP_BPS));

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(admin);
        withdrawalPolicy.setAssetFeeBps(asset, feeBps16, false);
    }

    function test_setDefaultFeeBps_setsExpectedFee(uint256 feeBps) public {
        feeBps = bound(feeBps, 0, FEE_CAP_BPS);

        vm.expectEmit(true, true, true, true);
        // forge-lint: disable-next-line(unsafe-typecast)
        emit WithdrawalPolicy.DefaultFeeBpsSet(uint16(feeBps));
        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(feeBps));

        assertEq(withdrawalPolicy.getDefaultFeeBps(), feeBps);
    }

    function test_setDefaultFeeBps_reverts_ifFeeBpsIsInvalid(uint256 feeBps) public {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 feeBps16 = uint16(bound(feeBps, FEE_CAP_BPS + 1, type(uint16).max));

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(admin);
        withdrawalPolicy.setDefaultFeeBps(feeBps16);
    }

    function test_addSigner_setsSignerStatus(address signer) public {
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer);

        assertEq(withdrawalPolicy.isSigner(signer), true);
    }

    function test_removeSigner_setsSignerStatus(address signer) public {
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer);
        vm.prank(admin);
        withdrawalPolicy.removeSigner(signer);

        assertEq(withdrawalPolicy.isSigner(signer), false);
    }

    function test_addSigner_emitsSignerSet(address signer) public {
        vm.expectEmit(true, true, true, true);
        emit WithdrawalPolicy.SignerSet(signer, true);
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer);
    }

    function test_removeSigner_emitsSignerSet(address signer) public {
        vm.expectEmit(true, true, true, true);
        emit WithdrawalPolicy.SignerSet(signer, false);
        vm.prank(admin);
        withdrawalPolicy.removeSigner(signer);
    }

    // Calculation tests

    function test_applyWithdrawalPolicy_returnsDefaultFee(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 baseFeeBps
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - Constants.MAX_BPS) / Constants.MAX_BPS);

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        // Fee rounds up, so expectedAmountOut rounds down
        uint256 expectedFee = (iouAmountRay * baseFeeBps + Constants.MAX_BPS - 1) / Constants.MAX_BPS;
        uint256 expectedAmountOut = iouAmountRay - expectedFee;

        assertFalse(withdrawalPolicy.getAssetFeeConfig(assetOut).isSet, "Asset fee is set");

        IWithdrawalPolicy.WithdrawalRequest memory request = _buildRequest(user, assetOut, iouAmountRay, "");

        // Preview should return same result
        uint256 previewAmountOut = withdrawalPolicy.previewWithdrawalPolicy(request);
        assertEq(previewAmountOut, expectedAmountOut, "Preview should match expected");

        // Apply should return same result
        uint256 actualAmountOut = withdrawalPolicy.applyWithdrawalPolicy(request);
        assertEq(actualAmountOut, expectedAmountOut, "Apply should match expected");
    }

    function test_applyWithdrawalPolicy_returnsAssetFee(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 assetFeeBps,
        uint256 baseFeeBps
    ) public {
        vm.assume(assetOut != address(0));
        baseFeeBps = bound(baseFeeBps, 0, FEE_CAP_BPS);
        assetFeeBps = bound(assetFeeBps, 0, FEE_CAP_BPS);
        // Bound to prevent overflow in fee calculation: iouAmountRay * feeBps + MAX_BPS - 1
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - Constants.MAX_BPS) / Constants.MAX_BPS);

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));
        assertEq(withdrawalPolicy.getDefaultFeeBps(), baseFeeBps);

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setAssetFeeBps(assetOut, uint16(assetFeeBps), true);

        // Fee rounds up, so expectedAmountOut rounds down
        uint256 expectedFee = (iouAmountRay * assetFeeBps + Constants.MAX_BPS - 1) / Constants.MAX_BPS;
        uint256 expectedAmountOut = iouAmountRay - expectedFee;

        assertTrue(withdrawalPolicy.getAssetFeeConfig(assetOut).isSet, "Asset fee is not set");
        assertEq(withdrawalPolicy.getAssetFeeConfig(assetOut).feeBps, assetFeeBps);

        IWithdrawalPolicy.WithdrawalRequest memory request = _buildRequest(user, assetOut, iouAmountRay, "");

        // Preview should return same result
        uint256 previewAmountOut = withdrawalPolicy.previewWithdrawalPolicy(request);
        assertEq(previewAmountOut, expectedAmountOut, "Preview should match expected");

        // Apply should return same result
        uint256 actualAmountOut = withdrawalPolicy.applyWithdrawalPolicy(request);
        assertEq(actualAmountOut, expectedAmountOut, "Apply should match expected");
    }

    function test_applyWithdrawalPolicy_returnsPersonalFee(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeAmountRay,
        bool isAssetFeeSet,
        uint256 assetFeeBps,
        uint256 baseFeeBps
    ) public {
        vm.assume(assetOut != address(0));
        baseFeeBps = bound(baseFeeBps, 0, FEE_CAP_BPS);
        assetFeeBps = bound(assetFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - Constants.MAX_BPS) / Constants.MAX_BPS);
        uint256 activeFeeBps = isAssetFeeSet ? assetFeeBps : baseFeeBps;
        uint256 capRay = _capRay(iouAmountRay, activeFeeBps);
        // Bound the signed fee at-or-below the cap so it's applied verbatim.
        personalFeeAmountRay = bound(personalFeeAmountRay, 0, capRay);

        // Setup base fee
        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        // Setup asset fee
        if (isAssetFeeSet) {
            vm.prank(admin);
            // forge-lint: disable-next-line(unsafe-typecast)
            withdrawalPolicy.setAssetFeeBps(assetOut, uint16(assetFeeBps), true);
        }

        // Create signer wallet and whitelist it
        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer);
        assertTrue(withdrawalPolicy.isSigner(signer), "Signer is not whitelisted");

        // Build signed personal-fee data
        bytes memory data = _createSignedFeeData(
            signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        // Signed fee is used directly (no rounding) as long as it's at-or-below the cap.
        uint256 expectedAmountOut = iouAmountRay - personalFeeAmountRay;

        IWithdrawalPolicy.WithdrawalRequest memory request = _buildRequest(user, assetOut, iouAmountRay, data);

        // Preview should return same result and NOT consume the nonce
        assertFalse(withdrawalPolicy.wasNonceUsed(signer, DEFAULT_NONCE), "Nonce should not be used before preview");
        uint256 previewAmountOut = withdrawalPolicy.previewWithdrawalPolicy(request);
        assertEq(previewAmountOut, expectedAmountOut, "Preview should match expected");
        assertFalse(withdrawalPolicy.wasNonceUsed(signer, DEFAULT_NONCE), "Preview should NOT consume nonce");

        // Apply should return same result and consume the nonce
        uint256 actualAmountOut = withdrawalPolicy.applyWithdrawalPolicy(request);
        assertEq(actualAmountOut, expectedAmountOut, "Apply should match expected");
        assertTrue(withdrawalPolicy.wasNonceUsed(signer, DEFAULT_NONCE), "Apply should consume nonce");
    }

    function test_applyWithdrawalPolicy_emitsWithdrawalPolicyApplied(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 baseFeeBps
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - Constants.MAX_BPS) / Constants.MAX_BPS);

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        uint256 expectedFee = (iouAmountRay * baseFeeBps + Constants.MAX_BPS - 1) / Constants.MAX_BPS;
        uint256 expectedAmountOut = iouAmountRay - expectedFee;

        IWithdrawalPolicy.WithdrawalRequest memory request = _buildRequest(user, assetOut, iouAmountRay, "");

        vm.expectEmit(true, true, true, true);
        emit IWithdrawalPolicy.WithdrawalPolicyApplied(user, assetOut, iouAmountRay, expectedAmountOut);

        withdrawalPolicy.applyWithdrawalPolicy(request);
    }

    function test_applyWithdrawalPolicy_reverts_ifCallerIsNotApplier() public {
        address user = makeAddr("user");
        address assetOut = makeAddr("assetOut");
        uint256 iouAmountRay = 1000e27;
        uint256 personalFeeAmountRay = 0;
        uint16 baseFeeBps = 5_00;

        vm.prank(admin);
        withdrawalPolicy.setDefaultFeeBps(baseFeeBps);

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer);

        bytes memory data = _createSignedFeeData(
            signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, DEFAULT_DEADLINE
        );
        IWithdrawalPolicy.WithdrawalRequest memory request = _buildRequest(user, assetOut, iouAmountRay, data);

        address attacker = makeAddr("attacker");
        vm.expectRevert(Errors.NotAuthorized.selector);
        vm.prank(attacker);
        withdrawalPolicy.applyWithdrawalPolicy(request);
        assertFalse(withdrawalPolicy.wasNonceUsed(signer, DEFAULT_NONCE), "Nonce should not be used after revert");

        uint256 amountOut = withdrawalPolicy.applyWithdrawalPolicy(request);
        assertEq(amountOut, iouAmountRay, "Authorized caller should apply fee waiver");
        assertTrue(withdrawalPolicy.wasNonceUsed(signer, DEFAULT_NONCE), "Apply should consume nonce");
    }

    function test_applyWithdrawalPolicy_clampsSignedFeeToAssetCap(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeAmountRay,
        bool isAssetFeeSet,
        uint256 assetFeeBps,
        uint256 baseFeeBps
    ) public {
        vm.assume(assetOut != address(0));
        baseFeeBps = bound(baseFeeBps, 0, FEE_CAP_BPS);
        assetFeeBps = bound(assetFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - Constants.MAX_BPS) / Constants.MAX_BPS);
        uint256 activeFeeBps = isAssetFeeSet ? assetFeeBps : baseFeeBps;
        uint256 capRay = _capRay(iouAmountRay, activeFeeBps);
        // Bound the signed fee strictly above the cap so the contract must clamp it.
        personalFeeAmountRay = bound(personalFeeAmountRay, capRay + 1, type(uint256).max);

        // Setup base fee
        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        // Setup asset fee
        if (isAssetFeeSet) {
            vm.prank(admin);
            // forge-lint: disable-next-line(unsafe-typecast)
            withdrawalPolicy.setAssetFeeBps(assetOut, uint16(assetFeeBps), true);
        }

        // Create signer wallet and whitelist it
        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer);
        assertTrue(withdrawalPolicy.isSigner(signer), "Signer is not whitelisted");

        bytes memory data = _createSignedFeeData(
            signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        uint256 expectedAmountOut = iouAmountRay - capRay;

        IWithdrawalPolicy.WithdrawalRequest memory request = _buildRequest(user, assetOut, iouAmountRay, data);

        assertFalse(withdrawalPolicy.wasNonceUsed(signer, DEFAULT_NONCE), "Nonce should not be used before preview");
        uint256 previewAmountOut = withdrawalPolicy.previewWithdrawalPolicy(request);
        assertEq(previewAmountOut, expectedAmountOut, "Preview should clamp to asset cap");
        assertFalse(withdrawalPolicy.wasNonceUsed(signer, DEFAULT_NONCE), "Preview should NOT consume nonce");

        uint256 actualAmountOut = withdrawalPolicy.applyWithdrawalPolicy(request);
        assertEq(actualAmountOut, expectedAmountOut, "Apply should clamp to asset cap");
        assertTrue(withdrawalPolicy.wasNonceUsed(signer, DEFAULT_NONCE), "Apply should consume nonce");
    }

    function test_applyWithdrawalPolicy_reverts_ifSignerIsNotWhitelisted(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeAmountRay,
        uint256 baseFeeBps,
        uint256 nonWhitelistedSignerPk
    ) public {
        // Secp256k1 curve order
        uint256 SECP256K1_ORDER = 115792089237316195423570985008687907852837564279074904382605163141518161494337;
        nonWhitelistedSignerPk = bound(nonWhitelistedSignerPk, 1, SECP256K1_ORDER - 1);
        address nonWhitelistedSigner = vm.addr(nonWhitelistedSignerPk);
        vm.assume(withdrawalPolicy.isSigner(nonWhitelistedSigner) == false);

        baseFeeBps = bound(baseFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - Constants.MAX_BPS) / Constants.MAX_BPS);
        personalFeeAmountRay = bound(personalFeeAmountRay, 0, _capRay(iouAmountRay, baseFeeBps));

        // Setup base fee
        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        // Build signed personal-fee data with non-whitelisted signer
        bytes memory data = _createSignedFeeData(
            nonWhitelistedSignerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        vm.expectRevert(WithdrawalPolicy.InvalidSignature.selector);
        withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
    }

    function test_applyWithdrawalPolicy_reverts_ifSignatureIsForDifferentUser(
        address user,
        address wrongUser,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeAmountRay,
        uint256 baseFeeBps
    ) public {
        vm.assume(user != wrongUser);
        baseFeeBps = bound(baseFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - Constants.MAX_BPS) / Constants.MAX_BPS);
        personalFeeAmountRay = bound(personalFeeAmountRay, 0, _capRay(iouAmountRay, baseFeeBps));

        // Setup base fee
        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        // Create signer wallet and whitelist it
        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer);

        // Build signed personal-fee data for WRONG user
        bytes memory data = _createSignedFeeData(
            signerPk, wrongUser, assetOut, iouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        vm.expectRevert(WithdrawalPolicy.InvalidSignature.selector);
        withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
    }

    function test_applyWithdrawalPolicy_reverts_ifSignatureIsForDifferentAsset(
        address user,
        address assetOut,
        address wrongAssetOut,
        uint256 iouAmountRay,
        uint256 personalFeeAmountRay,
        uint256 baseFeeBps
    ) public {
        vm.assume(assetOut != wrongAssetOut);
        baseFeeBps = bound(baseFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - Constants.MAX_BPS) / Constants.MAX_BPS);
        personalFeeAmountRay = bound(personalFeeAmountRay, 0, _capRay(iouAmountRay, baseFeeBps));

        // Setup base fee
        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        // Create signer wallet and whitelist it
        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer);

        // Build signed personal-fee data for WRONG asset
        bytes memory data = _createSignedFeeData(
            signerPk, user, wrongAssetOut, iouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        vm.expectRevert(WithdrawalPolicy.InvalidSignature.selector);
        withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
    }

    function test_applyWithdrawalPolicy_reverts_ifSignatureIsForDifferentAmount(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 wrongIouAmountRay,
        uint256 personalFeeAmountRay,
        uint256 baseFeeBps
    ) public {
        vm.assume(iouAmountRay != wrongIouAmountRay);
        baseFeeBps = bound(baseFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - Constants.MAX_BPS) / Constants.MAX_BPS);
        wrongIouAmountRay = bound(wrongIouAmountRay, 0, (type(uint256).max - Constants.MAX_BPS) / Constants.MAX_BPS);
        vm.assume(iouAmountRay != wrongIouAmountRay);
        personalFeeAmountRay = bound(personalFeeAmountRay, 0, _capRay(iouAmountRay, baseFeeBps));

        // Setup base fee
        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        // Create signer wallet and whitelist it
        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer);

        // Build signed personal-fee data for WRONG amount
        bytes memory data = _createSignedFeeData(
            signerPk, user, assetOut, wrongIouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        vm.expectRevert(WithdrawalPolicy.InvalidSignature.selector);
        withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
    }

    function test_applyWithdrawalPolicy_reverts_ifSignatureIsForDifferentPersonalFee(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeAmountRay,
        uint256 wrongPersonalFeeAmountRay,
        uint256 baseFeeBps
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - Constants.MAX_BPS) / Constants.MAX_BPS);
        uint256 capRay = _capRay(iouAmountRay, baseFeeBps);
        personalFeeAmountRay = bound(personalFeeAmountRay, 0, capRay);
        wrongPersonalFeeAmountRay = bound(wrongPersonalFeeAmountRay, 0, capRay);
        vm.assume(personalFeeAmountRay != wrongPersonalFeeAmountRay);

        // Setup base fee
        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        // Create signer wallet and whitelist it
        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer);

        // Create data with the CORRECT personalFeeAmountRay claimed but signature for a different ray amount
        bytes memory wrongData = _createSignedFeeDataWithMismatch(
            signerPk,
            user,
            assetOut,
            iouAmountRay,
            personalFeeAmountRay, // claimed in data
            wrongPersonalFeeAmountRay, // signed
            DEFAULT_NONCE,
            DEFAULT_DEADLINE
        );

        vm.expectRevert(WithdrawalPolicy.InvalidSignature.selector);
        withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, wrongData));
    }

    function test_applyWithdrawalPolicy_reverts_ifSignatureIsMalformed(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeAmountRay,
        uint256 baseFeeBps,
        bytes memory malformedSignature
    ) public {
        vm.assume(malformedSignature.length != 65);
        baseFeeBps = bound(baseFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - Constants.MAX_BPS) / Constants.MAX_BPS);
        personalFeeAmountRay = bound(personalFeeAmountRay, 0, _capRay(iouAmountRay, baseFeeBps));

        // Setup base fee
        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        // Create signer wallet and whitelist it
        (address signer,) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer);

        // Manually encode SignedFee with malformed signature
        bytes memory data = abi.encode(
            WithdrawalPolicy.SignedFee({
                personalFeeAmountRay: personalFeeAmountRay,
                nonce: DEFAULT_NONCE,
                deadline: DEFAULT_DEADLINE,
                signature: malformedSignature
            })
        );

        vm.expectRevert();
        withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
    }

    function test_applyWithdrawalPolicy_reverts_ifDeadlineExpired() public {
        address user = makeAddr("user");
        address assetOut = makeAddr("assetOut");
        uint256 iouAmountRay = 1000e27;
        uint256 personalFeeAmountRay = 0;
        uint16 baseFeeBps = 5_00;

        vm.prank(admin);
        withdrawalPolicy.setDefaultFeeBps(baseFeeBps);

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer);

        // Create signature with expired deadline
        uint256 expiredDeadline = block.timestamp - 1;
        bytes memory data = _createSignedFeeData(
            signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, expiredDeadline
        );

        IWithdrawalPolicy.WithdrawalRequest memory request = _buildRequest(user, assetOut, iouAmountRay, data);

        // Both preview and apply should revert
        vm.expectRevert(WithdrawalPolicy.DeadlineExpired.selector);
        withdrawalPolicy.previewWithdrawalPolicy(request);

        vm.expectRevert(WithdrawalPolicy.DeadlineExpired.selector);
        withdrawalPolicy.applyWithdrawalPolicy(request);
    }

    // Preview Tests

    /// @notice Test that preview can be called multiple times without consuming nonces
    function test_previewWithdrawalPolicy_doesNotConsumeNonce() public {
        address user = makeAddr("user");
        address assetOut = makeAddr("assetOut");
        uint256 iouAmountRay = 1000e27;
        uint256 personalFeeAmountRay = 25e27; // 2.5% of iouAmountRay, within 5% base-fee cap
        uint16 baseFeeBps = 5_00; // 5% base fee

        vm.prank(admin);
        withdrawalPolicy.setDefaultFeeBps(baseFeeBps);

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer);

        bytes memory data = _createSignedFeeData(
            signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        IWithdrawalPolicy.WithdrawalRequest memory request = _buildRequest(user, assetOut, iouAmountRay, data);

        // Preview can be called multiple times
        uint256 preview1 = withdrawalPolicy.previewWithdrawalPolicy(request);
        uint256 preview2 = withdrawalPolicy.previewWithdrawalPolicy(request);
        uint256 preview3 = withdrawalPolicy.previewWithdrawalPolicy(request);

        assertEq(preview1, preview2, "Preview results should be consistent");
        assertEq(preview2, preview3, "Preview results should be consistent");
        assertFalse(withdrawalPolicy.wasNonceUsed(signer, DEFAULT_NONCE), "Nonce should not be consumed by preview");

        // Apply consumes the nonce
        uint256 applied = withdrawalPolicy.applyWithdrawalPolicy(request);
        assertEq(applied, preview1, "Apply should return same as preview");
        assertTrue(withdrawalPolicy.wasNonceUsed(signer, DEFAULT_NONCE), "Nonce should be consumed by apply");

        // Now preview should revert because nonce is used
        vm.expectRevert(WithdrawalPolicy.NonceAlreadyUsed.selector);
        withdrawalPolicy.previewWithdrawalPolicy(request);
    }

    // Signature Replay Protection Tests

    /// @notice Test that signatures cannot be replayed after first use
    function test_applyWithdrawalPolicy_reverts_onSignatureReplay() public {
        address user = makeAddr("user");
        address assetOut = makeAddr("assetOut");
        uint256 iouAmountRay = 1000e27; // 1000 tokens in RAY
        uint256 personalFeeAmountRay = 0; // 0 fee (waiver)
        uint16 baseFeeBps = 5_00; // 5% base fee

        // Setup: Configure base fee and whitelist signer
        vm.prank(admin);
        withdrawalPolicy.setDefaultFeeBps(baseFeeBps);

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer);

        // Create signature for personal fee waiver
        bytes memory data = _createSignedFeeData(
            signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        // First use: Should succeed and return full amount (0% fee)
        uint256 amountOut1 = withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
        assertEq(amountOut1, iouAmountRay, "First use should return full amount (0% fee)");

        // Second use: Should REVERT because nonce was consumed
        vm.expectRevert(WithdrawalPolicy.NonceAlreadyUsed.selector);
        withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
    }

    // Nonce Invalidation Tests

    function test_invalidateNonce_allowsSignerToInvalidateOwnNonce() public {
        (address signer,) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer);

        uint256 nonce = 42;
        assertFalse(withdrawalPolicy.wasNonceUsed(signer, nonce), "Nonce should not be used initially");

        vm.prank(signer);
        withdrawalPolicy.invalidateNonce(signer, nonce);

        assertTrue(withdrawalPolicy.wasNonceUsed(signer, nonce), "Nonce should be invalidated");
    }

    function test_invalidateNonce_emitsExpectedEvent(uint256 nonceSalt) public {
        (address signer,) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer);

        uint256 nonce = uint256(keccak256(abi.encodePacked("fuzzedNonce:", nonceSalt)));
        assertFalse(withdrawalPolicy.wasNonceUsed(signer, nonce), "Nonce should not be used initially");

        vm.expectEmit(true, true, true, true);
        emit WithdrawalPolicy.NonceUsed(signer, nonce);

        vm.prank(signer);
        withdrawalPolicy.invalidateNonce(signer, nonce);
    }

    function test_invalidateNonce_reverts_ifCallerIsNotSigner() public {
        address notSigner = makeAddr("notSigner");
        (address signer,) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer);

        vm.prank(notSigner);
        vm.expectRevert(Errors.NotAuthorized.selector);
        withdrawalPolicy.invalidateNonce(notSigner, 1);
    }

    function test_invalidateNonce_reverts_ifSignerParamDoesNotMatchCaller() public {
        (address signer1,) = makeAddrAndKey("signer1");
        (address signer2,) = makeAddrAndKey("signer2");
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer1);
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer2);

        // signer1 tries to invalidate signer2's nonce
        vm.prank(signer1);
        vm.expectRevert(Errors.NotAuthorized.selector);
        withdrawalPolicy.invalidateNonce(signer2, 1);
    }

    function test_invalidateNonce_reverts_ifAlreadyInvalidated() public {
        (address signer,) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer);

        vm.prank(signer);
        withdrawalPolicy.invalidateNonce(signer, 1);

        vm.expectRevert(WithdrawalPolicy.NonceAlreadyUsed.selector);
        vm.prank(signer);
        withdrawalPolicy.invalidateNonce(signer, 1);
    }

    function test_invalidateNonce_preventsSignatureFromBeingApplied(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeAmountRay,
        uint256 baseFeeBps,
        uint256 nonce
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - Constants.MAX_BPS) / Constants.MAX_BPS);
        personalFeeAmountRay = bound(personalFeeAmountRay, 0, _capRay(iouAmountRay, baseFeeBps));

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer);

        bytes memory data =
            _createSignedFeeData(signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, nonce, DEFAULT_DEADLINE);

        // Signer invalidates the nonce before it's used
        vm.prank(signer);
        withdrawalPolicy.invalidateNonce(signer, nonce);

        // Now apply should revert
        vm.expectRevert(WithdrawalPolicy.NonceAlreadyUsed.selector);
        withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
    }

    function test_invalidateNonce_preventsSignatureFromBeingPreviewed(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeAmountRay,
        uint256 baseFeeBps,
        uint256 nonce
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - Constants.MAX_BPS) / Constants.MAX_BPS);
        personalFeeAmountRay = bound(personalFeeAmountRay, 0, _capRay(iouAmountRay, baseFeeBps));

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer);

        bytes memory data =
            _createSignedFeeData(signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, nonce, DEFAULT_DEADLINE);

        // Signer invalidates the nonce before it's used
        vm.prank(signer);
        withdrawalPolicy.invalidateNonce(signer, nonce);

        // Now preview should also revert
        vm.expectRevert(WithdrawalPolicy.NonceAlreadyUsed.selector);
        withdrawalPolicy.previewWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
    }

    // Deadline Tests

    function test_applyWithdrawalPolicy_acceptsDeadlineAtCurrentTimestamp() public {
        address user = makeAddr("user");
        address assetOut = makeAddr("assetOut");
        uint256 iouAmountRay = 1000e27;
        uint256 personalFeeAmountRay = 25e27; // 2.5% of iou, within 5% base-fee cap
        uint16 baseFeeBps = 5_00;

        vm.prank(admin);
        withdrawalPolicy.setDefaultFeeBps(baseFeeBps);

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer);

        // Deadline exactly at current timestamp should work
        uint256 deadline = block.timestamp;
        bytes memory data =
            _createSignedFeeData(signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, deadline);

        // Should succeed
        uint256 amountOut = withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
        assertGt(amountOut, 0, "Should return non-zero amount");
    }

    function test_applyWithdrawalPolicy_acceptsDeadlineInFuture(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeAmountRay,
        uint256 baseFeeBps,
        uint256 deadlineOffset
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - Constants.MAX_BPS) / Constants.MAX_BPS);
        personalFeeAmountRay = bound(personalFeeAmountRay, 0, _capRay(iouAmountRay, baseFeeBps));
        deadlineOffset = bound(deadlineOffset, 1, 365 days);

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer);

        // Deadline in the future should work
        uint256 deadline = block.timestamp + deadlineOffset;
        bytes memory data =
            _createSignedFeeData(signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, deadline);

        // Should succeed — signed fee is at-or-below cap so it's charged verbatim.
        uint256 amountOut = withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
        assertEq(amountOut, iouAmountRay - personalFeeAmountRay, "Should return correct amount");
    }

    // Nonce Tests

    function test_applyWithdrawalPolicy_allowsDifferentNoncesFromSameSigner(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeAmountRay,
        uint256 baseFeeBps,
        uint256 nonce1,
        uint256 nonce2,
        uint256 nonce3
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - Constants.MAX_BPS) / Constants.MAX_BPS);
        personalFeeAmountRay = bound(personalFeeAmountRay, 0, _capRay(iouAmountRay, baseFeeBps));
        vm.assume(nonce1 != nonce2 && nonce2 != nonce3 && nonce1 != nonce3);

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer);

        // First signature with nonce1
        bytes memory data1 = _createSignedFeeData(
            signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, nonce1, DEFAULT_DEADLINE
        );
        withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data1));
        assertTrue(withdrawalPolicy.wasNonceUsed(signer, nonce1), "Nonce1 should be used");

        // Second signature with nonce2 should also work
        bytes memory data2 = _createSignedFeeData(
            signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, nonce2, DEFAULT_DEADLINE
        );
        withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data2));
        assertTrue(withdrawalPolicy.wasNonceUsed(signer, nonce2), "Nonce2 should be used");

        // Third signature with nonce3 should also work
        bytes memory data3 = _createSignedFeeData(
            signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, nonce3, DEFAULT_DEADLINE
        );
        withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data3));
        assertTrue(withdrawalPolicy.wasNonceUsed(signer, nonce3), "Nonce3 should be used");
    }

    function test_applyWithdrawalPolicy_acceptsNonceZero() public {
        address user = makeAddr("user");
        address assetOut = makeAddr("assetOut");
        uint256 iouAmountRay = 1000e27;
        uint256 personalFeeAmountRay = 25e27; // within 5% base-fee cap
        uint16 baseFeeBps = 5_00;

        vm.prank(admin);
        withdrawalPolicy.setDefaultFeeBps(baseFeeBps);

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer);

        // Nonce 0 should be valid
        uint256 nonceZero = 0;
        bytes memory data = _createSignedFeeData(
            signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, nonceZero, DEFAULT_DEADLINE
        );

        assertFalse(withdrawalPolicy.wasNonceUsed(signer, nonceZero), "Nonce 0 should not be used initially");

        uint256 amountOut = withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
        assertGt(amountOut, 0, "Should return non-zero amount");
        assertTrue(withdrawalPolicy.wasNonceUsed(signer, nonceZero), "Nonce 0 should be used after apply");
    }

    function test_applyWithdrawalPolicy_allowsSameNonceFromDifferentSigners(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeAmountRay,
        uint256 baseFeeBps,
        uint256 sharedNonce
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - Constants.MAX_BPS) / Constants.MAX_BPS);
        personalFeeAmountRay = bound(personalFeeAmountRay, 0, _capRay(iouAmountRay, baseFeeBps));

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        (address signer1, uint256 signerPk1) = makeAddrAndKey("signer1");
        (address signer2, uint256 signerPk2) = makeAddrAndKey("signer2");
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer1);
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer2);

        // Signer1 uses the shared nonce
        bytes memory data1 = _createSignedFeeData(
            signerPk1, user, assetOut, iouAmountRay, personalFeeAmountRay, sharedNonce, DEFAULT_DEADLINE
        );
        withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data1));
        assertTrue(withdrawalPolicy.wasNonceUsed(signer1, sharedNonce), "Signer1 nonce should be used");
        assertFalse(withdrawalPolicy.wasNonceUsed(signer2, sharedNonce), "Signer2 nonce should not be used yet");

        // Signer2 can also use the same nonce
        bytes memory data2 = _createSignedFeeData(
            signerPk2, user, assetOut, iouAmountRay, personalFeeAmountRay, sharedNonce, DEFAULT_DEADLINE
        );
        withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data2));
        assertTrue(withdrawalPolicy.wasNonceUsed(signer2, sharedNonce), "Signer2 nonce should now be used");
    }

    // Signer Removal Tests

    function test_applyWithdrawalPolicy_reverts_ifSignerWasRemoved(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeAmountRay,
        uint256 baseFeeBps
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - Constants.MAX_BPS) / Constants.MAX_BPS);
        personalFeeAmountRay = bound(personalFeeAmountRay, 0, _capRay(iouAmountRay, baseFeeBps));

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer);

        bytes memory data = _createSignedFeeData(
            signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        // Remove the signer
        vm.prank(admin);
        withdrawalPolicy.removeSigner(signer);
        assertFalse(withdrawalPolicy.isSigner(signer), "Signer should be removed");

        // Apply should revert because signer is no longer whitelisted
        vm.expectRevert(WithdrawalPolicy.InvalidSignature.selector);
        withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
    }

    function test_previewWithdrawalPolicy_reverts_ifSignerWasRemoved(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeAmountRay,
        uint256 baseFeeBps
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - Constants.MAX_BPS) / Constants.MAX_BPS);
        personalFeeAmountRay = bound(personalFeeAmountRay, 0, _capRay(iouAmountRay, baseFeeBps));

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer);

        bytes memory data = _createSignedFeeData(
            signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        // Remove the signer
        vm.prank(admin);
        withdrawalPolicy.removeSigner(signer);

        // Preview should also revert because signer is no longer whitelisted
        vm.expectRevert(WithdrawalPolicy.InvalidSignature.selector);
        withdrawalPolicy.previewWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
    }

    function test_previewWithdrawalPolicy_becomesInvalidAfterSignerRemoved(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeAmountRay,
        uint256 baseFeeBps
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - Constants.MAX_BPS) / Constants.MAX_BPS);
        personalFeeAmountRay = bound(personalFeeAmountRay, 0, _capRay(iouAmountRay, baseFeeBps));

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer);

        bytes memory data = _createSignedFeeData(
            signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        IWithdrawalPolicy.WithdrawalRequest memory request = _buildRequest(user, assetOut, iouAmountRay, data);

        // Preview works while signer is whitelisted — signed fee at-or-below cap is charged verbatim.
        uint256 previewAmount = withdrawalPolicy.previewWithdrawalPolicy(request);
        assertEq(previewAmount, iouAmountRay - personalFeeAmountRay, "Preview should return correct amount");

        // Remove the signer
        vm.prank(admin);
        withdrawalPolicy.removeSigner(signer);

        // Same preview should now revert
        vm.expectRevert(WithdrawalPolicy.InvalidSignature.selector);
        withdrawalPolicy.previewWithdrawalPolicy(request);
    }

    function test_applyWithdrawalPolicy_acceptsSignatureAfterSignerReAdded(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeAmountRay,
        uint256 baseFeeBps
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - Constants.MAX_BPS) / Constants.MAX_BPS);
        personalFeeAmountRay = bound(personalFeeAmountRay, 0, _capRay(iouAmountRay, baseFeeBps));

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer);

        bytes memory data = _createSignedFeeData(
            signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        // Remove the signer
        vm.prank(admin);
        withdrawalPolicy.removeSigner(signer);

        // Apply should revert
        vm.expectRevert(WithdrawalPolicy.InvalidSignature.selector);
        withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data));

        // Re-add the signer
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer);

        // Apply should now succeed
        uint256 amountOut = withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
        assertEq(amountOut, iouAmountRay - personalFeeAmountRay, "Should return correct amount after signer re-added");
    }

    function test_applyWithdrawalPolicy_otherSignersUnaffectedWhenOneRemoved(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeAmountRay,
        uint256 baseFeeBps
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - Constants.MAX_BPS) / Constants.MAX_BPS);
        personalFeeAmountRay = bound(personalFeeAmountRay, 0, _capRay(iouAmountRay, baseFeeBps));

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        (address signer1, uint256 signerPk1) = makeAddrAndKey("signer1");
        (address signer2, uint256 signerPk2) = makeAddrAndKey("signer2");
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer1);
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer2);

        bytes memory data1 =
            _createSignedFeeData(signerPk1, user, assetOut, iouAmountRay, personalFeeAmountRay, 1, DEFAULT_DEADLINE);
        bytes memory data2 =
            _createSignedFeeData(signerPk2, user, assetOut, iouAmountRay, personalFeeAmountRay, 1, DEFAULT_DEADLINE);

        // Remove signer1
        vm.prank(admin);
        withdrawalPolicy.removeSigner(signer1);

        // Signer1's signature should fail
        vm.expectRevert(WithdrawalPolicy.InvalidSignature.selector);
        withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data1));

        // Signer2's signature should still work
        uint256 amountOut = withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data2));
        assertEq(amountOut, iouAmountRay - personalFeeAmountRay, "Signer2 signature should still work");
    }

    function test_invalidateNonce_reverts_ifSignerWasRemoved(uint256 nonce1, uint256 nonce2) public {
        vm.assume(nonce1 != nonce2);

        (address signer,) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer);

        // Signer can invalidate while whitelisted
        vm.prank(signer);
        withdrawalPolicy.invalidateNonce(signer, nonce1);
        assertTrue(withdrawalPolicy.wasNonceUsed(signer, nonce1), "Nonce1 should be invalidated");

        // Remove the signer
        vm.prank(admin);
        withdrawalPolicy.removeSigner(signer);

        // Removed signer cannot invalidate nonces anymore
        vm.prank(signer);
        vm.expectRevert(Errors.NotAuthorized.selector);
        withdrawalPolicy.invalidateNonce(signer, nonce2);
    }

    /// @notice Invariant: the fee charged to the user is never more than the asset-bp cap applied to iouAmountRay
    /// (rounded up). Holds for any signed ray amount, including values far above the cap.
    function test_chargedFeeNeverExceedsAssetCap(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeAmountRay,
        uint256 assetFeeBps
    ) public {
        vm.assume(assetOut != address(0));
        assetFeeBps = bound(assetFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - Constants.MAX_BPS) / Constants.MAX_BPS);

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setAssetFeeBps(assetOut, uint16(assetFeeBps), true);

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer);

        bytes memory data = _createSignedFeeData(
            signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        uint256 amountOut = withdrawalPolicy.previewWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
        uint256 chargedFee = iouAmountRay - amountOut;

        assertLe(chargedFee, _capRay(iouAmountRay, assetFeeBps), "Charged fee must not exceed asset-bp cap");
    }

    function test_chargedFeeAtCapMatchesLegacyBpsRounding(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 signedBps,
        uint256 assetFeeBps
    ) public {
        vm.assume(assetOut != address(0));
        assetFeeBps = bound(assetFeeBps, 0, FEE_CAP_BPS);
        signedBps = bound(signedBps, 0, assetFeeBps);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - Constants.MAX_BPS) / Constants.MAX_BPS);

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setAssetFeeBps(assetOut, uint16(assetFeeBps), true);

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer);

        uint256 personalFeeAmountRay = _capRay(iouAmountRay, signedBps);
        bytes memory data = _createSignedFeeData(
            signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        uint256 amountOut = withdrawalPolicy.previewWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
        assertEq(
            iouAmountRay - amountOut,
            _capRay(iouAmountRay, signedBps),
            "Charged fee must match legacy bps-based rounding"
        );
    }

    /// @notice When the asset bp limit is 0, any signed ray amount must be clamped to 0 (no fee charged).
    function test_zeroAssetFeeClampsSignedAmountToZero(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeAmountRay
    ) public {
        vm.assume(assetOut != address(0));
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - Constants.MAX_BPS) / Constants.MAX_BPS);

        vm.prank(admin);
        withdrawalPolicy.setDefaultFeeBps(0);
        vm.prank(admin);
        withdrawalPolicy.setAssetFeeBps(assetOut, 0, true);

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer);

        bytes memory data = _createSignedFeeData(
            signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        uint256 amountOut = withdrawalPolicy.previewWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
        assertEq(amountOut, iouAmountRay, "No fee may be charged when asset bp is 0");
    }

    function test_oneWeiAboveCapIsClampedToCap(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 assetFeeBps
    ) public {
        vm.assume(assetOut != address(0));
        assetFeeBps = bound(assetFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - Constants.MAX_BPS) / Constants.MAX_BPS);
        uint256 capRay = _capRay(iouAmountRay, assetFeeBps);
        vm.assume(capRay < type(uint256).max);

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setAssetFeeBps(assetOut, uint16(assetFeeBps), true);

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.addSigner(signer);

        bytes memory data =
            _createSignedFeeData(signerPk, user, assetOut, iouAmountRay, capRay + 1, DEFAULT_NONCE, DEFAULT_DEADLINE);

        uint256 amountOut = withdrawalPolicy.previewWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
        assertEq(amountOut, iouAmountRay - capRay, "One wei above cap must clamp to cap");
    }

    /// @notice Rounding direction: the asset cap is always the ceil of (iou * feeBps / MAX_BPS), so the protocol is
    /// never short-changed even when the division is not exact. No signed data is supplied, exercising the fallback.
    function test_fuzz_capRoundsUpInFavorOfProtocol(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 assetFeeBps
    ) public {
        vm.assume(assetOut != address(0));
        assetFeeBps = bound(assetFeeBps, 1, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 1, (type(uint256).max - Constants.MAX_BPS) / Constants.MAX_BPS);

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setAssetFeeBps(assetOut, uint16(assetFeeBps), true);

        uint256 amountOut = withdrawalPolicy.previewWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, ""));
        uint256 chargedFee = iouAmountRay - amountOut;

        uint256 floor = (iouAmountRay * assetFeeBps) / Constants.MAX_BPS;
        uint256 ceil = (iouAmountRay * assetFeeBps + Constants.MAX_BPS - 1) / Constants.MAX_BPS;
        assertEq(chargedFee, ceil, "Cap must round up");
        assertGe(chargedFee, floor, "Cap must never round below floor");
    }

    // Computes the asset-cap ray amount for a given iou amount and bp limit (rounds up, matching protocol).
    function _capRay(uint256 iouAmountRay, uint256 feeBps) internal pure returns (uint256) {
        return (iouAmountRay * feeBps + Constants.MAX_BPS - 1) / Constants.MAX_BPS;
    }

    // Helper to create signed personal-fee data
    function _createSignedFeeData(
        uint256 signerPk,
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeAmountRay,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes memory signature = _signPersonalFee(
            signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, nonce, deadline
        );

        return abi.encode(
            WithdrawalPolicy.SignedFee({
                personalFeeAmountRay: personalFeeAmountRay, nonce: nonce, deadline: deadline, signature: signature
            })
        );
    }

    // Helper for mismatch test - creates data where claimed fee differs from signed fee
    function _createSignedFeeDataWithMismatch(
        uint256 signerPk,
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 claimedFeeAmountRay,
        uint256 signedFeeAmountRay,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        // Sign with signedFeeAmountRay but encode with claimedFeeAmountRay
        bytes memory signature =
            _signPersonalFee(signerPk, user, assetOut, iouAmountRay, signedFeeAmountRay, nonce, deadline);

        return abi.encode(
            WithdrawalPolicy.SignedFee({
                personalFeeAmountRay: claimedFeeAmountRay, nonce: nonce, deadline: deadline, signature: signature
            })
        );
    }

    function _signPersonalFee(
        uint256 signerPk,
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeAmountRay,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 digest = _buildSignedFeeDigest(user, assetOut, iouAmountRay, personalFeeAmountRay, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _buildSignedFeeDigest(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeAmountRay,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        // Must match SIGNED_FEE_TYPEHASH in WithdrawalPolicy
        bytes32 typeHash = keccak256(
            "SignedFee(address user,address assetOut,uint256 iouAmountRay,uint256 personalFeeAmountRay,uint256 nonce,uint256 deadline)"
        );

        bytes32 structHash =
            keccak256(abi.encode(typeHash, user, assetOut, iouAmountRay, personalFeeAmountRay, nonce, deadline));

        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("WithdrawalPolicy"),
                keccak256("1"),
                block.chainid,
                address(withdrawalPolicy)
            )
        );

        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}

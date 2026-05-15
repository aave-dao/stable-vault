// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {IWithdrawalExecutionPolicy} from "src/interfaces/IWithdrawalExecutionPolicy.sol";
import {RateLimitBucketLib} from "src/libraries/RateLimitBucketLib.sol";
import {WithdrawalExecutionPolicy} from "src/policies/WithdrawalExecutionPolicy.sol";
import {Constants} from "src/types/Constants.sol";
import {Errors} from "src/types/Errors.sol";

import {TestWithHelpers} from "test/helpers/TestWithHelpers.sol";
import {MockAccessManager} from "test/mocks/MockAccessManager.sol";
import {MockAssetRegistry} from "test/mocks/MockAssetRegistry.sol";

contract WithdrawalExecutionPolicyTest is TestWithHelpers {
    WithdrawalExecutionPolicy withdrawalExecutionPolicy;
    MockAccessManager mockAccessManager;
    MockAssetRegistry mockAssetRegistry;
    address admin = makeAddr("admin");

    // Default nonce and deadline for tests
    uint256 constant DEFAULT_NONCE = 1;
    uint256 constant DEFAULT_DEADLINE = type(uint256).max;

    uint16 constant FEE_CAP_BPS = 10_00; // 10.00%

    uint128 constant MIN_REDEMPTION_CAPACITY = 1;
    uint128 constant MIN_REDEMPTION_REFILL_RATE = 1;
    uint128 constant SEED_REDEMPTION_CAPACITY = type(uint128).max - 1;
    uint128 constant SEED_REDEMPTION_REFILL_RATE = 1e30;

    function _deployWithdrawalExecutionPolicy(address accessManager, address withdrawalExecutionPolicyApplier)
        internal
        returns (WithdrawalExecutionPolicy)
    {
        return _deployWithdrawalExecutionPolicy(
            accessManager, withdrawalExecutionPolicyApplier, MIN_REDEMPTION_CAPACITY, MIN_REDEMPTION_REFILL_RATE
        );
    }

    function _deployWithdrawalExecutionPolicy(
        address accessManager,
        address withdrawalExecutionPolicyApplier,
        uint128 minRedemptionCapacity,
        uint128 minRedemptionRefillRate
    ) internal returns (WithdrawalExecutionPolicy) {
        address withdrawalExecutionPolicyImpl = address(
            new WithdrawalExecutionPolicy(
                withdrawalExecutionPolicyApplier, minRedemptionCapacity, minRedemptionRefillRate
            )
        );
        WithdrawalExecutionPolicy policy = WithdrawalExecutionPolicy(
            address(
                new TransparentUpgradeableProxy(
                    withdrawalExecutionPolicyImpl,
                    address(this),
                    abi.encodeCall(WithdrawalExecutionPolicy.initialize, (accessManager, 0))
                )
            )
        );
        policy.raiseRedemptionCapacity(SEED_REDEMPTION_CAPACITY);
        policy.raiseRedemptionRefillRate(SEED_REDEMPTION_REFILL_RATE);
        return policy;
    }

    function setUp() public {
        mockAccessManager = new MockAccessManager(admin);
        mockAssetRegistry = new MockAssetRegistry();
        withdrawalExecutionPolicy = _deployWithdrawalExecutionPolicy(address(mockAccessManager), address(this));
    }

    // Helper to build WithdrawalRequest
    function _buildRequest(address user, address assetOut, uint256 iouAmountRay, bytes memory data)
        internal
        pure
        returns (IWithdrawalExecutionPolicy.WithdrawalExecutionIntent memory)
    {
        return IWithdrawalExecutionPolicy.WithdrawalExecutionIntent({
            user: user, assetOut: assetOut, iouAmountRay: iouAmountRay, policyData: data
        });
    }

    // Constructor tests

    function test_constructor_reverts_ifWithdrawalExecutionPolicyApplierIsZeroAddress() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        new WithdrawalExecutionPolicy(address(0), MIN_REDEMPTION_CAPACITY, MIN_REDEMPTION_REFILL_RATE);
    }

    function test_constructor_reverts_ifMinRedemptionCapacityIsZero() public {
        vm.expectRevert(WithdrawalExecutionPolicy.ZeroMinRedemptionCapacity.selector);
        new WithdrawalExecutionPolicy(address(this), 0, MIN_REDEMPTION_REFILL_RATE);
    }

    function test_constructor_reverts_ifMinRedemptionRefillRateIsZero() public {
        vm.expectRevert(WithdrawalExecutionPolicy.ZeroMinRedemptionRefillRate.selector);
        new WithdrawalExecutionPolicy(address(this), MIN_REDEMPTION_CAPACITY, 0);
    }

    // Restricted functions access control tests

    function test_setAssetFeeBps_reverts_ifMsgSenderIsNotAuthorized(
        address unauthorizedMsgSender,
        address asset,
        uint256 newAssetFeeBps,
        bool isSet
    ) public {
        vm.assume(unauthorizedMsgSender != address(0));
        _assumeNotProxyAdmin(unauthorizedMsgSender, address(withdrawalExecutionPolicy));

        mockAccessManager.mockRejectCall(
            unauthorizedMsgSender, address(withdrawalExecutionPolicy), WithdrawalExecutionPolicy.setAssetFeeBps.selector
        );

        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedMsgSender)
        );
        vm.prank(unauthorizedMsgSender);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalExecutionPolicy.setAssetFeeBps(asset, uint16(newAssetFeeBps), isSet);
    }

    function test_setDefaultFeeBps_reverts_ifMsgSenderIsNotAuthorized(
        address unauthorizedMsgSender,
        uint256 newDefaultFeeBps
    ) public {
        vm.assume(unauthorizedMsgSender != address(0));
        _assumeNotProxyAdmin(unauthorizedMsgSender, address(withdrawalExecutionPolicy));

        mockAccessManager.mockRejectCall(
            unauthorizedMsgSender,
            address(withdrawalExecutionPolicy),
            WithdrawalExecutionPolicy.setDefaultFeeBps.selector
        );

        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedMsgSender)
        );
        vm.prank(unauthorizedMsgSender);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalExecutionPolicy.setDefaultFeeBps(uint16(newDefaultFeeBps));
    }

    function test_addSigner_reverts_ifMsgSenderIsNotAuthorized(address unauthorizedMsgSender, address signer) public {
        vm.assume(unauthorizedMsgSender != address(0));
        _assumeNotProxyAdmin(unauthorizedMsgSender, address(withdrawalExecutionPolicy));
        mockAccessManager.mockRejectCall(
            unauthorizedMsgSender, address(withdrawalExecutionPolicy), WithdrawalExecutionPolicy.addSigner.selector
        );

        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedMsgSender)
        );
        vm.prank(unauthorizedMsgSender);
        withdrawalExecutionPolicy.addSigner(signer);
    }

    function test_removeSigner_reverts_ifMsgSenderIsNotAuthorized(address unauthorizedMsgSender, address signer)
        public
    {
        vm.assume(unauthorizedMsgSender != address(0));
        _assumeNotProxyAdmin(unauthorizedMsgSender, address(withdrawalExecutionPolicy));
        mockAccessManager.mockRejectCall(
            unauthorizedMsgSender, address(withdrawalExecutionPolicy), WithdrawalExecutionPolicy.removeSigner.selector
        );

        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedMsgSender)
        );
        vm.prank(unauthorizedMsgSender);
        withdrawalExecutionPolicy.removeSigner(signer);
    }

    // Setters & Getters tests

    function test_setAssetFeeBps_setsExpectedConfig(address asset, uint256 feeBps, bool isSet) public {
        vm.assume(asset != address(0));
        feeBps = bound(feeBps, 0, FEE_CAP_BPS);
        vm.assume(isSet || feeBps == 0);

        vm.expectEmit(true, true, true, true);
        // forge-lint: disable-next-line(unsafe-typecast)
        emit WithdrawalExecutionPolicy.AssetFeeBpsSet(asset, uint16(feeBps), isSet);
        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalExecutionPolicy.setAssetFeeBps(asset, uint16(feeBps), isSet);

        WithdrawalExecutionPolicy.AssetFeeConfig memory config = withdrawalExecutionPolicy.getAssetFeeConfig(asset);
        assertEq(config.feeBps, feeBps);
        assertEq(config.isSet, isSet);
    }

    function test_setAssetFeeBps_reverts_ifAssetIsZeroAddress(uint256 feeBps, bool isSet) public {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 feeBps16 = uint16(bound(feeBps, 0, FEE_CAP_BPS));

        vm.expectRevert(Errors.ZeroAddress.selector);
        vm.prank(admin);
        withdrawalExecutionPolicy.setAssetFeeBps(address(0), feeBps16, isSet);
    }

    function test_setAssetFeeBps_reverts_ifFeeBpsIsInvalid(address asset, uint256 feeBps, bool isSet) public {
        vm.assume(asset != address(0));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 feeBps16 = uint16(bound(feeBps, 10_001, type(uint16).max));

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(admin);
        withdrawalExecutionPolicy.setAssetFeeBps(asset, feeBps16, isSet);
    }

    function test_setAssetFeeBps_reverts_ifNotSetWithNonZeroFee(address asset, uint256 feeBps) public {
        vm.assume(asset != address(0));
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 feeBps16 = uint16(bound(feeBps, 1, FEE_CAP_BPS));

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(admin);
        withdrawalExecutionPolicy.setAssetFeeBps(asset, feeBps16, false);
    }

    function test_setDefaultFeeBps_setsExpectedFee(uint256 feeBps) public {
        feeBps = bound(feeBps, 0, FEE_CAP_BPS);

        vm.expectEmit(true, true, true, true);
        // forge-lint: disable-next-line(unsafe-typecast)
        emit WithdrawalExecutionPolicy.DefaultFeeBpsSet(uint16(feeBps));
        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalExecutionPolicy.setDefaultFeeBps(uint16(feeBps));

        assertEq(withdrawalExecutionPolicy.getDefaultFeeBps(), feeBps);
    }

    function test_setDefaultFeeBps_reverts_ifFeeBpsIsInvalid(uint256 feeBps) public {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 feeBps16 = uint16(bound(feeBps, FEE_CAP_BPS + 1, type(uint16).max));

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(admin);
        withdrawalExecutionPolicy.setDefaultFeeBps(feeBps16);
    }

    function test_addSigner_setsSignerStatus(address signer) public {
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer);

        assertEq(withdrawalExecutionPolicy.isSigner(signer), true);
    }

    function test_removeSigner_setsSignerStatus(address signer) public {
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer);
        vm.prank(admin);
        withdrawalExecutionPolicy.removeSigner(signer);

        assertEq(withdrawalExecutionPolicy.isSigner(signer), false);
    }

    function test_addSigner_emitsSignerSet(address signer) public {
        vm.expectEmit(true, true, true, true);
        emit WithdrawalExecutionPolicy.SignerSet(signer, true);
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer);
    }

    function test_removeSigner_emitsSignerSet(address signer) public {
        vm.expectEmit(true, true, true, true);
        emit WithdrawalExecutionPolicy.SignerSet(signer, false);
        vm.prank(admin);
        withdrawalExecutionPolicy.removeSigner(signer);
    }

    // Calculation tests

    function test_applyWithdrawalExecutionPolicy_returnsDefaultFee(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 baseFeeBps
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint128).max - 1) / 4);

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalExecutionPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        // Fee rounds up, so expectedAmountOut rounds down
        uint256 expectedFee = (iouAmountRay * baseFeeBps + Constants.MAX_BPS - 1) / Constants.MAX_BPS;
        uint256 expectedAmountOut = iouAmountRay - expectedFee;

        assertFalse(withdrawalExecutionPolicy.getAssetFeeConfig(assetOut).isSet, "Asset fee is set");

        IWithdrawalExecutionPolicy.WithdrawalExecutionIntent memory request =
            _buildRequest(user, assetOut, iouAmountRay, "");

        // Preview should return same result
        uint256 previewAmountOut = withdrawalExecutionPolicy.previewWithdrawalExecutionPolicy(request);
        assertEq(previewAmountOut, expectedAmountOut, "Preview should match expected");

        // Apply should return same result
        uint256 actualAmountOut = withdrawalExecutionPolicy.applyWithdrawalExecutionPolicy(request);
        assertEq(actualAmountOut, expectedAmountOut, "Apply should match expected");
    }

    function test_applyWithdrawalExecutionPolicy_returnsAssetFee(
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
        iouAmountRay = bound(iouAmountRay, 0, (type(uint128).max - 1) / 4);

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalExecutionPolicy.setDefaultFeeBps(uint16(baseFeeBps));
        assertEq(withdrawalExecutionPolicy.getDefaultFeeBps(), baseFeeBps);

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalExecutionPolicy.setAssetFeeBps(assetOut, uint16(assetFeeBps), true);

        // Fee rounds up, so expectedAmountOut rounds down
        uint256 expectedFee = (iouAmountRay * assetFeeBps + Constants.MAX_BPS - 1) / Constants.MAX_BPS;
        uint256 expectedAmountOut = iouAmountRay - expectedFee;

        assertTrue(withdrawalExecutionPolicy.getAssetFeeConfig(assetOut).isSet, "Asset fee is not set");
        assertEq(withdrawalExecutionPolicy.getAssetFeeConfig(assetOut).feeBps, assetFeeBps);

        IWithdrawalExecutionPolicy.WithdrawalExecutionIntent memory request =
            _buildRequest(user, assetOut, iouAmountRay, "");

        // Preview should return same result
        uint256 previewAmountOut = withdrawalExecutionPolicy.previewWithdrawalExecutionPolicy(request);
        assertEq(previewAmountOut, expectedAmountOut, "Preview should match expected");

        // Apply should return same result
        uint256 actualAmountOut = withdrawalExecutionPolicy.applyWithdrawalExecutionPolicy(request);
        assertEq(actualAmountOut, expectedAmountOut, "Apply should match expected");
    }

    function test_applyWithdrawalExecutionPolicy_returnsPersonalFee(
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
        iouAmountRay = bound(iouAmountRay, 0, (type(uint128).max - 1) / 4);
        uint256 activeFeeBps = isAssetFeeSet ? assetFeeBps : baseFeeBps;
        uint256 capRay = _capRay(iouAmountRay, activeFeeBps);
        // Bound the signed fee at-or-below the cap so it's applied verbatim.
        personalFeeAmountRay = bound(personalFeeAmountRay, 0, capRay);

        // Setup base fee
        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalExecutionPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        // Setup asset fee
        if (isAssetFeeSet) {
            vm.prank(admin);
            // forge-lint: disable-next-line(unsafe-typecast)
            withdrawalExecutionPolicy.setAssetFeeBps(assetOut, uint16(assetFeeBps), true);
        }

        // Create signer wallet and whitelist it
        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer);
        assertTrue(withdrawalExecutionPolicy.isSigner(signer), "Signer is not whitelisted");

        // Build signed personal-fee data
        bytes memory data = _createSignedFeeData(
            signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        // Signed fee is used directly (no rounding) as long as it's at-or-below the cap.
        uint256 expectedAmountOut = iouAmountRay - personalFeeAmountRay;

        IWithdrawalExecutionPolicy.WithdrawalExecutionIntent memory request =
            _buildRequest(user, assetOut, iouAmountRay, data);

        // Preview should return same result and NOT consume the nonce
        assertFalse(
            withdrawalExecutionPolicy.wasNonceUsed(signer, DEFAULT_NONCE), "Nonce should not be used before preview"
        );
        uint256 previewAmountOut = withdrawalExecutionPolicy.previewWithdrawalExecutionPolicy(request);
        assertEq(previewAmountOut, expectedAmountOut, "Preview should match expected");
        assertFalse(withdrawalExecutionPolicy.wasNonceUsed(signer, DEFAULT_NONCE), "Preview should NOT consume nonce");

        // Apply should return same result and consume the nonce
        uint256 actualAmountOut = withdrawalExecutionPolicy.applyWithdrawalExecutionPolicy(request);
        assertEq(actualAmountOut, expectedAmountOut, "Apply should match expected");
        assertTrue(withdrawalExecutionPolicy.wasNonceUsed(signer, DEFAULT_NONCE), "Apply should consume nonce");
    }

    function test_applyWithdrawalExecutionPolicy_emitsWithdrawalExecutionPolicyApplied(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 baseFeeBps
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint128).max - 1) / 4);

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalExecutionPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        uint256 expectedFee = (iouAmountRay * baseFeeBps + Constants.MAX_BPS - 1) / Constants.MAX_BPS;
        uint256 expectedAmountOut = iouAmountRay - expectedFee;

        IWithdrawalExecutionPolicy.WithdrawalExecutionIntent memory request =
            _buildRequest(user, assetOut, iouAmountRay, "");

        vm.expectEmit(true, true, true, true);
        emit IWithdrawalExecutionPolicy.WithdrawalExecutionPolicyApplied(
            user, assetOut, iouAmountRay, expectedAmountOut
        );

        withdrawalExecutionPolicy.applyWithdrawalExecutionPolicy(request);
    }

    function test_applyWithdrawalExecutionPolicy_reverts_ifCallerIsNotApplier() public {
        address user = makeAddr("user");
        address assetOut = makeAddr("assetOut");
        uint256 iouAmountRay = 1000e27;
        uint256 personalFeeAmountRay = 0;
        uint16 baseFeeBps = 5_00;

        vm.prank(admin);
        withdrawalExecutionPolicy.setDefaultFeeBps(baseFeeBps);

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer);

        bytes memory data = _createSignedFeeData(
            signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, DEFAULT_DEADLINE
        );
        IWithdrawalExecutionPolicy.WithdrawalExecutionIntent memory request =
            _buildRequest(user, assetOut, iouAmountRay, data);

        address attacker = makeAddr("attacker");
        vm.expectRevert(Errors.NotAuthorized.selector);
        vm.prank(attacker);
        withdrawalExecutionPolicy.applyWithdrawalExecutionPolicy(request);
        assertFalse(
            withdrawalExecutionPolicy.wasNonceUsed(signer, DEFAULT_NONCE), "Nonce should not be used after revert"
        );

        uint256 amountOut = withdrawalExecutionPolicy.applyWithdrawalExecutionPolicy(request);
        assertEq(amountOut, iouAmountRay, "Authorized caller should apply fee waiver");
        assertTrue(withdrawalExecutionPolicy.wasNonceUsed(signer, DEFAULT_NONCE), "Apply should consume nonce");
    }

    function test_applyWithdrawalExecutionPolicy_clampsSignedFeeToAssetCap(
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
        iouAmountRay = bound(iouAmountRay, 0, (type(uint128).max - 1) / 4);
        uint256 activeFeeBps = isAssetFeeSet ? assetFeeBps : baseFeeBps;
        uint256 capRay = _capRay(iouAmountRay, activeFeeBps);
        // Bound the signed fee strictly above the cap so the contract must clamp it.
        personalFeeAmountRay = bound(personalFeeAmountRay, capRay + 1, type(uint256).max);

        // Setup base fee
        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalExecutionPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        // Setup asset fee
        if (isAssetFeeSet) {
            vm.prank(admin);
            // forge-lint: disable-next-line(unsafe-typecast)
            withdrawalExecutionPolicy.setAssetFeeBps(assetOut, uint16(assetFeeBps), true);
        }

        // Create signer wallet and whitelist it
        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer);
        assertTrue(withdrawalExecutionPolicy.isSigner(signer), "Signer is not whitelisted");

        bytes memory data = _createSignedFeeData(
            signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        uint256 expectedAmountOut = iouAmountRay - capRay;

        IWithdrawalExecutionPolicy.WithdrawalExecutionIntent memory request =
            _buildRequest(user, assetOut, iouAmountRay, data);

        assertFalse(
            withdrawalExecutionPolicy.wasNonceUsed(signer, DEFAULT_NONCE), "Nonce should not be used before preview"
        );
        uint256 previewAmountOut = withdrawalExecutionPolicy.previewWithdrawalExecutionPolicy(request);
        assertEq(previewAmountOut, expectedAmountOut, "Preview should clamp to asset cap");
        assertFalse(withdrawalExecutionPolicy.wasNonceUsed(signer, DEFAULT_NONCE), "Preview should NOT consume nonce");

        uint256 actualAmountOut = withdrawalExecutionPolicy.applyWithdrawalExecutionPolicy(request);
        assertEq(actualAmountOut, expectedAmountOut, "Apply should clamp to asset cap");
        assertTrue(withdrawalExecutionPolicy.wasNonceUsed(signer, DEFAULT_NONCE), "Apply should consume nonce");
    }

    function test_applyWithdrawalExecutionPolicy_reverts_ifSignerIsNotWhitelisted(
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
        vm.assume(withdrawalExecutionPolicy.isSigner(nonWhitelistedSigner) == false);

        baseFeeBps = bound(baseFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint128).max - 1) / 4);
        personalFeeAmountRay = bound(personalFeeAmountRay, 0, _capRay(iouAmountRay, baseFeeBps));

        // Setup base fee
        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalExecutionPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        // Build signed personal-fee data with non-whitelisted signer
        bytes memory data = _createSignedFeeData(
            nonWhitelistedSignerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        vm.expectRevert(WithdrawalExecutionPolicy.InvalidSignature.selector);
        withdrawalExecutionPolicy.applyWithdrawalExecutionPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
    }

    function test_applyWithdrawalExecutionPolicy_reverts_ifSignatureIsForDifferentUser(
        address user,
        address wrongUser,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeAmountRay,
        uint256 baseFeeBps
    ) public {
        vm.assume(user != wrongUser);
        baseFeeBps = bound(baseFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint128).max - 1) / 4);
        personalFeeAmountRay = bound(personalFeeAmountRay, 0, _capRay(iouAmountRay, baseFeeBps));

        // Setup base fee
        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalExecutionPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        // Create signer wallet and whitelist it
        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer);

        // Build signed personal-fee data for WRONG user
        bytes memory data = _createSignedFeeData(
            signerPk, wrongUser, assetOut, iouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        vm.expectRevert(WithdrawalExecutionPolicy.InvalidSignature.selector);
        withdrawalExecutionPolicy.applyWithdrawalExecutionPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
    }

    function test_applyWithdrawalExecutionPolicy_reverts_ifSignatureIsForDifferentAsset(
        address user,
        address assetOut,
        address wrongAssetOut,
        uint256 iouAmountRay,
        uint256 personalFeeAmountRay,
        uint256 baseFeeBps
    ) public {
        vm.assume(assetOut != wrongAssetOut);
        baseFeeBps = bound(baseFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint128).max - 1) / 4);
        personalFeeAmountRay = bound(personalFeeAmountRay, 0, _capRay(iouAmountRay, baseFeeBps));

        // Setup base fee
        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalExecutionPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        // Create signer wallet and whitelist it
        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer);

        // Build signed personal-fee data for WRONG asset
        bytes memory data = _createSignedFeeData(
            signerPk, user, wrongAssetOut, iouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        vm.expectRevert(WithdrawalExecutionPolicy.InvalidSignature.selector);
        withdrawalExecutionPolicy.applyWithdrawalExecutionPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
    }

    function test_applyWithdrawalExecutionPolicy_reverts_ifSignatureIsForDifferentAmount(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 wrongIouAmountRay,
        uint256 personalFeeAmountRay,
        uint256 baseFeeBps
    ) public {
        vm.assume(iouAmountRay != wrongIouAmountRay);
        baseFeeBps = bound(baseFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint128).max - 1) / 4);
        wrongIouAmountRay = bound(wrongIouAmountRay, 0, (type(uint256).max - Constants.MAX_BPS) / Constants.MAX_BPS);
        vm.assume(iouAmountRay != wrongIouAmountRay);
        personalFeeAmountRay = bound(personalFeeAmountRay, 0, _capRay(iouAmountRay, baseFeeBps));

        // Setup base fee
        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalExecutionPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        // Create signer wallet and whitelist it
        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer);

        // Build signed personal-fee data for WRONG amount
        bytes memory data = _createSignedFeeData(
            signerPk, user, assetOut, wrongIouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        vm.expectRevert(WithdrawalExecutionPolicy.InvalidSignature.selector);
        withdrawalExecutionPolicy.applyWithdrawalExecutionPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
    }

    function test_applyWithdrawalExecutionPolicy_reverts_ifSignatureIsForDifferentPersonalFee(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeAmountRay,
        uint256 wrongPersonalFeeAmountRay,
        uint256 baseFeeBps
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint128).max - 1) / 4);
        uint256 capRay = _capRay(iouAmountRay, baseFeeBps);
        personalFeeAmountRay = bound(personalFeeAmountRay, 0, capRay);
        wrongPersonalFeeAmountRay = bound(wrongPersonalFeeAmountRay, 0, capRay);
        vm.assume(personalFeeAmountRay != wrongPersonalFeeAmountRay);

        // Setup base fee
        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalExecutionPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        // Create signer wallet and whitelist it
        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer);

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

        vm.expectRevert(WithdrawalExecutionPolicy.InvalidSignature.selector);
        withdrawalExecutionPolicy.applyWithdrawalExecutionPolicy(_buildRequest(user, assetOut, iouAmountRay, wrongData));
    }

    function test_applyWithdrawalExecutionPolicy_reverts_ifSignatureIsMalformed(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeAmountRay,
        uint256 baseFeeBps,
        bytes memory malformedSignature
    ) public {
        vm.assume(malformedSignature.length != 65);
        baseFeeBps = bound(baseFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint128).max - 1) / 4);
        personalFeeAmountRay = bound(personalFeeAmountRay, 0, _capRay(iouAmountRay, baseFeeBps));

        // Setup base fee
        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalExecutionPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        // Create signer wallet and whitelist it
        (address signer,) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer);

        // Manually encode SignedFee with malformed signature
        bytes memory data = abi.encode(
            WithdrawalExecutionPolicy.SignedFee({
                personalFeeAmountRay: personalFeeAmountRay,
                nonce: DEFAULT_NONCE,
                deadline: DEFAULT_DEADLINE,
                signature: malformedSignature
            })
        );

        vm.expectRevert();
        withdrawalExecutionPolicy.applyWithdrawalExecutionPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
    }

    function test_applyWithdrawalExecutionPolicy_reverts_ifDeadlineExpired() public {
        address user = makeAddr("user");
        address assetOut = makeAddr("assetOut");
        uint256 iouAmountRay = 1000e27;
        uint256 personalFeeAmountRay = 0;
        uint16 baseFeeBps = 5_00;

        vm.prank(admin);
        withdrawalExecutionPolicy.setDefaultFeeBps(baseFeeBps);

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer);

        // Create signature with expired deadline
        uint256 expiredDeadline = block.timestamp - 1;
        bytes memory data = _createSignedFeeData(
            signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, expiredDeadline
        );

        IWithdrawalExecutionPolicy.WithdrawalExecutionIntent memory request =
            _buildRequest(user, assetOut, iouAmountRay, data);

        // Both preview and apply should revert
        vm.expectRevert(WithdrawalExecutionPolicy.DeadlineExpired.selector);
        withdrawalExecutionPolicy.previewWithdrawalExecutionPolicy(request);

        vm.expectRevert(WithdrawalExecutionPolicy.DeadlineExpired.selector);
        withdrawalExecutionPolicy.applyWithdrawalExecutionPolicy(request);
    }

    // Preview Tests

    /// @notice Test that preview can be called multiple times without consuming nonces
    function test_previewWithdrawalExecutionPolicy_doesNotConsumeNonce() public {
        address user = makeAddr("user");
        address assetOut = makeAddr("assetOut");
        uint256 iouAmountRay = 1000e27;
        uint256 personalFeeAmountRay = 25e27; // 2.5% of iouAmountRay, within 5% base-fee cap
        uint16 baseFeeBps = 5_00; // 5% base fee

        vm.prank(admin);
        withdrawalExecutionPolicy.setDefaultFeeBps(baseFeeBps);

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer);

        bytes memory data = _createSignedFeeData(
            signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        IWithdrawalExecutionPolicy.WithdrawalExecutionIntent memory request =
            _buildRequest(user, assetOut, iouAmountRay, data);

        // Preview can be called multiple times
        uint256 preview1 = withdrawalExecutionPolicy.previewWithdrawalExecutionPolicy(request);
        uint256 preview2 = withdrawalExecutionPolicy.previewWithdrawalExecutionPolicy(request);
        uint256 preview3 = withdrawalExecutionPolicy.previewWithdrawalExecutionPolicy(request);

        assertEq(preview1, preview2, "Preview results should be consistent");
        assertEq(preview2, preview3, "Preview results should be consistent");
        assertFalse(
            withdrawalExecutionPolicy.wasNonceUsed(signer, DEFAULT_NONCE), "Nonce should not be consumed by preview"
        );

        // Apply consumes the nonce
        uint256 applied = withdrawalExecutionPolicy.applyWithdrawalExecutionPolicy(request);
        assertEq(applied, preview1, "Apply should return same as preview");
        assertTrue(withdrawalExecutionPolicy.wasNonceUsed(signer, DEFAULT_NONCE), "Nonce should be consumed by apply");

        // Now preview should revert because nonce is used
        vm.expectRevert(WithdrawalExecutionPolicy.NonceAlreadyUsed.selector);
        withdrawalExecutionPolicy.previewWithdrawalExecutionPolicy(request);
    }

    // Signature Replay Protection Tests

    /// @notice Test that signatures cannot be replayed after first use
    function test_applyWithdrawalExecutionPolicy_reverts_onSignatureReplay() public {
        address user = makeAddr("user");
        address assetOut = makeAddr("assetOut");
        uint256 iouAmountRay = 1000e27; // 1000 tokens in RAY
        uint256 personalFeeAmountRay = 0; // 0 fee (waiver)
        uint16 baseFeeBps = 5_00; // 5% base fee

        // Setup: Configure base fee and whitelist signer
        vm.prank(admin);
        withdrawalExecutionPolicy.setDefaultFeeBps(baseFeeBps);

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer);

        // Create signature for personal fee waiver
        bytes memory data = _createSignedFeeData(
            signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        // First use: Should succeed and return full amount (0% fee)
        uint256 amountOut1 =
            withdrawalExecutionPolicy.applyWithdrawalExecutionPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
        assertEq(amountOut1, iouAmountRay, "First use should return full amount (0% fee)");

        // Second use: Should REVERT because nonce was consumed
        vm.expectRevert(WithdrawalExecutionPolicy.NonceAlreadyUsed.selector);
        withdrawalExecutionPolicy.applyWithdrawalExecutionPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
    }

    // Nonce Invalidation Tests

    function test_invalidateNonce_allowsSignerToInvalidateOwnNonce() public {
        (address signer,) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer);

        uint256 nonce = 42;
        assertFalse(withdrawalExecutionPolicy.wasNonceUsed(signer, nonce), "Nonce should not be used initially");

        vm.prank(signer);
        withdrawalExecutionPolicy.invalidateNonce(signer, nonce);

        assertTrue(withdrawalExecutionPolicy.wasNonceUsed(signer, nonce), "Nonce should be invalidated");
    }

    function test_invalidateNonce_emitsExpectedEvent(uint256 nonceSalt) public {
        (address signer,) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer);

        uint256 nonce = uint256(keccak256(abi.encodePacked("fuzzedNonce:", nonceSalt)));
        assertFalse(withdrawalExecutionPolicy.wasNonceUsed(signer, nonce), "Nonce should not be used initially");

        vm.expectEmit(true, true, true, true);
        emit WithdrawalExecutionPolicy.NonceUsed(signer, nonce);

        vm.prank(signer);
        withdrawalExecutionPolicy.invalidateNonce(signer, nonce);
    }

    function test_invalidateNonce_reverts_ifCallerIsNotSigner() public {
        address notSigner = makeAddr("notSigner");
        (address signer,) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer);

        vm.prank(notSigner);
        vm.expectRevert(Errors.NotAuthorized.selector);
        withdrawalExecutionPolicy.invalidateNonce(notSigner, 1);
    }

    function test_invalidateNonce_reverts_ifSignerParamDoesNotMatchCaller() public {
        (address signer1,) = makeAddrAndKey("signer1");
        (address signer2,) = makeAddrAndKey("signer2");
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer1);
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer2);

        // signer1 tries to invalidate signer2's nonce
        vm.prank(signer1);
        vm.expectRevert(Errors.NotAuthorized.selector);
        withdrawalExecutionPolicy.invalidateNonce(signer2, 1);
    }

    function test_invalidateNonce_reverts_ifAlreadyInvalidated() public {
        (address signer,) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer);

        vm.prank(signer);
        withdrawalExecutionPolicy.invalidateNonce(signer, 1);

        vm.expectRevert(WithdrawalExecutionPolicy.NonceAlreadyUsed.selector);
        vm.prank(signer);
        withdrawalExecutionPolicy.invalidateNonce(signer, 1);
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
        iouAmountRay = bound(iouAmountRay, 0, (type(uint128).max - 1) / 4);
        personalFeeAmountRay = bound(personalFeeAmountRay, 0, _capRay(iouAmountRay, baseFeeBps));

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalExecutionPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer);

        bytes memory data =
            _createSignedFeeData(signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, nonce, DEFAULT_DEADLINE);

        // Signer invalidates the nonce before it's used
        vm.prank(signer);
        withdrawalExecutionPolicy.invalidateNonce(signer, nonce);

        // Now apply should revert
        vm.expectRevert(WithdrawalExecutionPolicy.NonceAlreadyUsed.selector);
        withdrawalExecutionPolicy.applyWithdrawalExecutionPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
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
        iouAmountRay = bound(iouAmountRay, 0, (type(uint128).max - 1) / 4);
        personalFeeAmountRay = bound(personalFeeAmountRay, 0, _capRay(iouAmountRay, baseFeeBps));

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalExecutionPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer);

        bytes memory data =
            _createSignedFeeData(signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, nonce, DEFAULT_DEADLINE);

        // Signer invalidates the nonce before it's used
        vm.prank(signer);
        withdrawalExecutionPolicy.invalidateNonce(signer, nonce);

        // Now preview should also revert
        vm.expectRevert(WithdrawalExecutionPolicy.NonceAlreadyUsed.selector);
        withdrawalExecutionPolicy.previewWithdrawalExecutionPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
    }

    // Deadline Tests

    function test_applyWithdrawalExecutionPolicy_acceptsDeadlineAtCurrentTimestamp() public {
        address user = makeAddr("user");
        address assetOut = makeAddr("assetOut");
        uint256 iouAmountRay = 1000e27;
        uint256 personalFeeAmountRay = 25e27; // 2.5% of iou, within 5% base-fee cap
        uint16 baseFeeBps = 5_00;

        vm.prank(admin);
        withdrawalExecutionPolicy.setDefaultFeeBps(baseFeeBps);

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer);

        // Deadline exactly at current timestamp should work
        uint256 deadline = block.timestamp;
        bytes memory data =
            _createSignedFeeData(signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, deadline);

        // Should succeed
        uint256 amountOut =
            withdrawalExecutionPolicy.applyWithdrawalExecutionPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
        assertGt(amountOut, 0, "Should return non-zero amount");
    }

    function test_applyWithdrawalExecutionPolicy_acceptsDeadlineInFuture(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeAmountRay,
        uint256 baseFeeBps,
        uint256 deadlineOffset
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint128).max - 1) / 4);
        personalFeeAmountRay = bound(personalFeeAmountRay, 0, _capRay(iouAmountRay, baseFeeBps));
        deadlineOffset = bound(deadlineOffset, 1, 365 days);

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalExecutionPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer);

        // Deadline in the future should work
        uint256 deadline = block.timestamp + deadlineOffset;
        bytes memory data =
            _createSignedFeeData(signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, deadline);

        // Should succeed — signed fee is at-or-below cap so it's charged verbatim.
        uint256 amountOut =
            withdrawalExecutionPolicy.applyWithdrawalExecutionPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
        assertEq(amountOut, iouAmountRay - personalFeeAmountRay, "Should return correct amount");
    }

    // Nonce Tests

    function test_applyWithdrawalExecutionPolicy_allowsDifferentNoncesFromSameSigner(
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
        iouAmountRay = bound(iouAmountRay, 0, (type(uint128).max - 1) / 4);
        personalFeeAmountRay = bound(personalFeeAmountRay, 0, _capRay(iouAmountRay, baseFeeBps));
        vm.assume(nonce1 != nonce2 && nonce2 != nonce3 && nonce1 != nonce3);

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalExecutionPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer);

        // First signature with nonce1
        bytes memory data1 = _createSignedFeeData(
            signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, nonce1, DEFAULT_DEADLINE
        );
        withdrawalExecutionPolicy.applyWithdrawalExecutionPolicy(_buildRequest(user, assetOut, iouAmountRay, data1));
        assertTrue(withdrawalExecutionPolicy.wasNonceUsed(signer, nonce1), "Nonce1 should be used");

        // Second signature with nonce2 should also work
        bytes memory data2 = _createSignedFeeData(
            signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, nonce2, DEFAULT_DEADLINE
        );
        withdrawalExecutionPolicy.applyWithdrawalExecutionPolicy(_buildRequest(user, assetOut, iouAmountRay, data2));
        assertTrue(withdrawalExecutionPolicy.wasNonceUsed(signer, nonce2), "Nonce2 should be used");

        // Third signature with nonce3 should also work
        bytes memory data3 = _createSignedFeeData(
            signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, nonce3, DEFAULT_DEADLINE
        );
        withdrawalExecutionPolicy.applyWithdrawalExecutionPolicy(_buildRequest(user, assetOut, iouAmountRay, data3));
        assertTrue(withdrawalExecutionPolicy.wasNonceUsed(signer, nonce3), "Nonce3 should be used");
    }

    function test_applyWithdrawalExecutionPolicy_acceptsNonceZero() public {
        address user = makeAddr("user");
        address assetOut = makeAddr("assetOut");
        uint256 iouAmountRay = 1000e27;
        uint256 personalFeeAmountRay = 25e27; // within 5% base-fee cap
        uint16 baseFeeBps = 5_00;

        vm.prank(admin);
        withdrawalExecutionPolicy.setDefaultFeeBps(baseFeeBps);

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer);

        // Nonce 0 should be valid
        uint256 nonceZero = 0;
        bytes memory data = _createSignedFeeData(
            signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, nonceZero, DEFAULT_DEADLINE
        );

        assertFalse(withdrawalExecutionPolicy.wasNonceUsed(signer, nonceZero), "Nonce 0 should not be used initially");

        uint256 amountOut =
            withdrawalExecutionPolicy.applyWithdrawalExecutionPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
        assertGt(amountOut, 0, "Should return non-zero amount");
        assertTrue(withdrawalExecutionPolicy.wasNonceUsed(signer, nonceZero), "Nonce 0 should be used after apply");
    }

    function test_applyWithdrawalExecutionPolicy_allowsSameNonceFromDifferentSigners(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeAmountRay,
        uint256 baseFeeBps,
        uint256 sharedNonce
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint128).max - 1) / 4);
        personalFeeAmountRay = bound(personalFeeAmountRay, 0, _capRay(iouAmountRay, baseFeeBps));

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalExecutionPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        (address signer1, uint256 signerPk1) = makeAddrAndKey("signer1");
        (address signer2, uint256 signerPk2) = makeAddrAndKey("signer2");
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer1);
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer2);

        // Signer1 uses the shared nonce
        bytes memory data1 = _createSignedFeeData(
            signerPk1, user, assetOut, iouAmountRay, personalFeeAmountRay, sharedNonce, DEFAULT_DEADLINE
        );
        withdrawalExecutionPolicy.applyWithdrawalExecutionPolicy(_buildRequest(user, assetOut, iouAmountRay, data1));
        assertTrue(withdrawalExecutionPolicy.wasNonceUsed(signer1, sharedNonce), "Signer1 nonce should be used");
        assertFalse(
            withdrawalExecutionPolicy.wasNonceUsed(signer2, sharedNonce), "Signer2 nonce should not be used yet"
        );

        // Signer2 can also use the same nonce
        bytes memory data2 = _createSignedFeeData(
            signerPk2, user, assetOut, iouAmountRay, personalFeeAmountRay, sharedNonce, DEFAULT_DEADLINE
        );
        withdrawalExecutionPolicy.applyWithdrawalExecutionPolicy(_buildRequest(user, assetOut, iouAmountRay, data2));
        assertTrue(withdrawalExecutionPolicy.wasNonceUsed(signer2, sharedNonce), "Signer2 nonce should now be used");
    }

    // Signer Removal Tests

    function test_applyWithdrawalExecutionPolicy_reverts_ifSignerWasRemoved(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeAmountRay,
        uint256 baseFeeBps
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint128).max - 1) / 4);
        personalFeeAmountRay = bound(personalFeeAmountRay, 0, _capRay(iouAmountRay, baseFeeBps));

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalExecutionPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer);

        bytes memory data = _createSignedFeeData(
            signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        // Remove the signer
        vm.prank(admin);
        withdrawalExecutionPolicy.removeSigner(signer);
        assertFalse(withdrawalExecutionPolicy.isSigner(signer), "Signer should be removed");

        // Apply should revert because signer is no longer whitelisted
        vm.expectRevert(WithdrawalExecutionPolicy.InvalidSignature.selector);
        withdrawalExecutionPolicy.applyWithdrawalExecutionPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
    }

    function test_previewWithdrawalExecutionPolicy_reverts_ifSignerWasRemoved(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeAmountRay,
        uint256 baseFeeBps
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint128).max - 1) / 4);
        personalFeeAmountRay = bound(personalFeeAmountRay, 0, _capRay(iouAmountRay, baseFeeBps));

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalExecutionPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer);

        bytes memory data = _createSignedFeeData(
            signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        // Remove the signer
        vm.prank(admin);
        withdrawalExecutionPolicy.removeSigner(signer);

        // Preview should also revert because signer is no longer whitelisted
        vm.expectRevert(WithdrawalExecutionPolicy.InvalidSignature.selector);
        withdrawalExecutionPolicy.previewWithdrawalExecutionPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
    }

    function test_previewWithdrawalExecutionPolicy_becomesInvalidAfterSignerRemoved(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeAmountRay,
        uint256 baseFeeBps
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint128).max - 1) / 4);
        personalFeeAmountRay = bound(personalFeeAmountRay, 0, _capRay(iouAmountRay, baseFeeBps));

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalExecutionPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer);

        bytes memory data = _createSignedFeeData(
            signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        IWithdrawalExecutionPolicy.WithdrawalExecutionIntent memory request =
            _buildRequest(user, assetOut, iouAmountRay, data);

        // Preview works while signer is whitelisted — signed fee at-or-below cap is charged verbatim.
        uint256 previewAmount = withdrawalExecutionPolicy.previewWithdrawalExecutionPolicy(request);
        assertEq(previewAmount, iouAmountRay - personalFeeAmountRay, "Preview should return correct amount");

        // Remove the signer
        vm.prank(admin);
        withdrawalExecutionPolicy.removeSigner(signer);

        // Same preview should now revert
        vm.expectRevert(WithdrawalExecutionPolicy.InvalidSignature.selector);
        withdrawalExecutionPolicy.previewWithdrawalExecutionPolicy(request);
    }

    function test_applyWithdrawalExecutionPolicy_acceptsSignatureAfterSignerReAdded(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeAmountRay,
        uint256 baseFeeBps
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint128).max - 1) / 4);
        personalFeeAmountRay = bound(personalFeeAmountRay, 0, _capRay(iouAmountRay, baseFeeBps));

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalExecutionPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer);

        bytes memory data = _createSignedFeeData(
            signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        // Remove the signer
        vm.prank(admin);
        withdrawalExecutionPolicy.removeSigner(signer);

        // Apply should revert
        vm.expectRevert(WithdrawalExecutionPolicy.InvalidSignature.selector);
        withdrawalExecutionPolicy.applyWithdrawalExecutionPolicy(_buildRequest(user, assetOut, iouAmountRay, data));

        // Re-add the signer
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer);

        // Apply should now succeed
        uint256 amountOut =
            withdrawalExecutionPolicy.applyWithdrawalExecutionPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
        assertEq(amountOut, iouAmountRay - personalFeeAmountRay, "Should return correct amount after signer re-added");
    }

    function test_applyWithdrawalExecutionPolicy_otherSignersUnaffectedWhenOneRemoved(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeAmountRay,
        uint256 baseFeeBps
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, FEE_CAP_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint128).max - 1) / 4);
        personalFeeAmountRay = bound(personalFeeAmountRay, 0, _capRay(iouAmountRay, baseFeeBps));

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalExecutionPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        (address signer1, uint256 signerPk1) = makeAddrAndKey("signer1");
        (address signer2, uint256 signerPk2) = makeAddrAndKey("signer2");
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer1);
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer2);

        bytes memory data1 =
            _createSignedFeeData(signerPk1, user, assetOut, iouAmountRay, personalFeeAmountRay, 1, DEFAULT_DEADLINE);
        bytes memory data2 =
            _createSignedFeeData(signerPk2, user, assetOut, iouAmountRay, personalFeeAmountRay, 1, DEFAULT_DEADLINE);

        // Remove signer1
        vm.prank(admin);
        withdrawalExecutionPolicy.removeSigner(signer1);

        // Signer1's signature should fail
        vm.expectRevert(WithdrawalExecutionPolicy.InvalidSignature.selector);
        withdrawalExecutionPolicy.applyWithdrawalExecutionPolicy(_buildRequest(user, assetOut, iouAmountRay, data1));

        // Signer2's signature should still work
        uint256 amountOut = withdrawalExecutionPolicy.applyWithdrawalExecutionPolicy(
            _buildRequest(user, assetOut, iouAmountRay, data2)
        );
        assertEq(amountOut, iouAmountRay - personalFeeAmountRay, "Signer2 signature should still work");
    }

    function test_invalidateNonce_reverts_ifSignerWasRemoved(uint256 nonce1, uint256 nonce2) public {
        vm.assume(nonce1 != nonce2);

        (address signer,) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer);

        // Signer can invalidate while whitelisted
        vm.prank(signer);
        withdrawalExecutionPolicy.invalidateNonce(signer, nonce1);
        assertTrue(withdrawalExecutionPolicy.wasNonceUsed(signer, nonce1), "Nonce1 should be invalidated");

        // Remove the signer
        vm.prank(admin);
        withdrawalExecutionPolicy.removeSigner(signer);

        // Removed signer cannot invalidate nonces anymore
        vm.prank(signer);
        vm.expectRevert(Errors.NotAuthorized.selector);
        withdrawalExecutionPolicy.invalidateNonce(signer, nonce2);
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
        iouAmountRay = bound(iouAmountRay, 0, (type(uint128).max - 1) / 4);

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalExecutionPolicy.setAssetFeeBps(assetOut, uint16(assetFeeBps), true);

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer);

        bytes memory data = _createSignedFeeData(
            signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        uint256 amountOut = withdrawalExecutionPolicy.previewWithdrawalExecutionPolicy(
            _buildRequest(user, assetOut, iouAmountRay, data)
        );
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
        iouAmountRay = bound(iouAmountRay, 0, (type(uint128).max - 1) / 4);

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalExecutionPolicy.setAssetFeeBps(assetOut, uint16(assetFeeBps), true);

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer);

        uint256 personalFeeAmountRay = _capRay(iouAmountRay, signedBps);
        bytes memory data = _createSignedFeeData(
            signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        uint256 amountOut = withdrawalExecutionPolicy.previewWithdrawalExecutionPolicy(
            _buildRequest(user, assetOut, iouAmountRay, data)
        );
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
        iouAmountRay = bound(iouAmountRay, 0, (type(uint128).max - 1) / 4);

        vm.prank(admin);
        withdrawalExecutionPolicy.setDefaultFeeBps(0);
        vm.prank(admin);
        withdrawalExecutionPolicy.setAssetFeeBps(assetOut, 0, true);

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer);

        bytes memory data = _createSignedFeeData(
            signerPk, user, assetOut, iouAmountRay, personalFeeAmountRay, DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        uint256 amountOut = withdrawalExecutionPolicy.previewWithdrawalExecutionPolicy(
            _buildRequest(user, assetOut, iouAmountRay, data)
        );
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
        iouAmountRay = bound(iouAmountRay, 0, (type(uint128).max - 1) / 4);
        uint256 capRay = _capRay(iouAmountRay, assetFeeBps);
        vm.assume(capRay < type(uint256).max);

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalExecutionPolicy.setAssetFeeBps(assetOut, uint16(assetFeeBps), true);

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalExecutionPolicy.addSigner(signer);

        bytes memory data =
            _createSignedFeeData(signerPk, user, assetOut, iouAmountRay, capRay + 1, DEFAULT_NONCE, DEFAULT_DEADLINE);

        uint256 amountOut = withdrawalExecutionPolicy.previewWithdrawalExecutionPolicy(
            _buildRequest(user, assetOut, iouAmountRay, data)
        );
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
        iouAmountRay = bound(iouAmountRay, 1, (type(uint128).max - 1) / 4);

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalExecutionPolicy.setAssetFeeBps(assetOut, uint16(assetFeeBps), true);

        uint256 amountOut =
            withdrawalExecutionPolicy.previewWithdrawalExecutionPolicy(_buildRequest(user, assetOut, iouAmountRay, ""));
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
            WithdrawalExecutionPolicy.SignedFee({
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
            WithdrawalExecutionPolicy.SignedFee({
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
        // Must match SIGNED_FEE_TYPEHASH in WithdrawalExecutionPolicy
        bytes32 typeHash = keccak256(
            "SignedFee(address user,address assetOut,uint256 iouAmountRay,uint256 personalFeeAmountRay,uint256 nonce,uint256 deadline)"
        );

        bytes32 structHash =
            keccak256(abi.encode(typeHash, user, assetOut, iouAmountRay, personalFeeAmountRay, nonce, deadline));

        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("WithdrawalExecutionPolicy"),
                keccak256("1"),
                block.chainid,
                address(withdrawalExecutionPolicy)
            )
        );

        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }

    // Redemption rate-limit tests

    function _deployPolicyWithCustomFloors(uint128 minCapacity, uint128 minRefillRate)
        internal
        returns (WithdrawalExecutionPolicy)
    {
        return _deployWithdrawalExecutionPolicy(address(mockAccessManager), address(this), minCapacity, minRefillRate);
    }

    function test_raiseRedemptionCapacity_reverts_ifMsgSenderIsNotAuthorized(address caller, uint128 newCapacity)
        public
    {
        vm.assume(caller != address(0));
        _assumeNotProxyAdmin(caller, address(withdrawalExecutionPolicy));

        mockAccessManager.mockRejectCall(
            caller, address(withdrawalExecutionPolicy), WithdrawalExecutionPolicy.raiseRedemptionCapacity.selector
        );

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        withdrawalExecutionPolicy.raiseRedemptionCapacity(newCapacity);
    }

    function test_lowerRedemptionCapacity_reverts_ifMsgSenderIsNotAuthorized(address caller, uint128 newCapacity)
        public
    {
        vm.assume(caller != address(0));
        _assumeNotProxyAdmin(caller, address(withdrawalExecutionPolicy));

        mockAccessManager.mockRejectCall(
            caller, address(withdrawalExecutionPolicy), WithdrawalExecutionPolicy.lowerRedemptionCapacity.selector
        );

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        withdrawalExecutionPolicy.lowerRedemptionCapacity(newCapacity);
    }

    function test_raiseRedemptionRefillRate_reverts_ifMsgSenderIsNotAuthorized(address caller, uint128 newRate) public {
        vm.assume(caller != address(0));
        _assumeNotProxyAdmin(caller, address(withdrawalExecutionPolicy));

        mockAccessManager.mockRejectCall(
            caller, address(withdrawalExecutionPolicy), WithdrawalExecutionPolicy.raiseRedemptionRefillRate.selector
        );

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        withdrawalExecutionPolicy.raiseRedemptionRefillRate(newRate);
    }

    function test_lowerRedemptionRefillRate_reverts_ifMsgSenderIsNotAuthorized(address caller, uint128 newRate) public {
        vm.assume(caller != address(0));
        _assumeNotProxyAdmin(caller, address(withdrawalExecutionPolicy));

        mockAccessManager.mockRejectCall(
            caller, address(withdrawalExecutionPolicy), WithdrawalExecutionPolicy.lowerRedemptionRefillRate.selector
        );

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, caller));
        vm.prank(caller);
        withdrawalExecutionPolicy.lowerRedemptionRefillRate(newRate);
    }

    function test_lowerRedemptionCapacity_reverts_ifBelowFloor(uint128 belowFloor) public {
        WithdrawalExecutionPolicy policy = _deployPolicyWithCustomFloors(1e30, 1e25);
        belowFloor = uint128(bound(belowFloor, 0, 1e30 - 1));
        // The seeded capacity sits above the floor, so a strict lowerCapacity below the floor reverts before
        // the lib's strict-less-than check matters.
        vm.expectRevert(WithdrawalExecutionPolicy.BelowMinRedemptionCapacity.selector);
        policy.lowerRedemptionCapacity(belowFloor);
    }

    function test_lowerRedemptionRefillRate_reverts_ifBelowFloor(uint128 belowFloor) public {
        WithdrawalExecutionPolicy policy = _deployPolicyWithCustomFloors(1e30, 1e25);
        belowFloor = uint128(bound(belowFloor, 0, 1e25 - 1));
        vm.expectRevert(WithdrawalExecutionPolicy.BelowMinRedemptionRefillRate.selector);
        policy.lowerRedemptionRefillRate(belowFloor);
    }

    function test_lowerRedemptionCapacity_succeedsAtFloor() public {
        WithdrawalExecutionPolicy policy = _deployPolicyWithCustomFloors(1e30, 1e25);
        vm.expectEmit(true, true, true, true, address(policy));
        emit WithdrawalExecutionPolicy.RedemptionCapacityLowered(SEED_REDEMPTION_CAPACITY, 1e30);
        policy.lowerRedemptionCapacity(1e30);
        assertEq(policy.getRedemptionBucket().capacity, 1e30, "Capacity should reach floor");
    }

    function test_lowerRedemptionRefillRate_succeedsAtFloor() public {
        WithdrawalExecutionPolicy policy = _deployPolicyWithCustomFloors(1e30, 1e25);
        vm.expectEmit(true, true, true, true, address(policy));
        emit WithdrawalExecutionPolicy.RedemptionRefillRateLowered(SEED_REDEMPTION_REFILL_RATE, 1e25);
        policy.lowerRedemptionRefillRate(1e25);
        assertEq(policy.getRedemptionBucket().refillRate, 1e25, "Refill rate should reach floor");
    }

    function test_raiseRedemptionCapacity_revertsOnNonStrictGreater(uint128 newCapacity) public {
        newCapacity = uint128(bound(newCapacity, 0, SEED_REDEMPTION_CAPACITY));
        vm.expectRevert(Errors.InvalidParameter.selector);
        withdrawalExecutionPolicy.raiseRedemptionCapacity(newCapacity);
    }

    function test_applyWithdrawalExecutionPolicy_consumesBucket(uint128 iouAmountRay) public {
        iouAmountRay = uint128(bound(iouAmountRay, 1, SEED_REDEMPTION_CAPACITY));
        RateLimitBucketLib.Bucket memory before = withdrawalExecutionPolicy.getRedemptionBucket();

        withdrawalExecutionPolicy.applyWithdrawalExecutionPolicy(
            _buildRequest(address(0xBEEF), address(0xCAFE), iouAmountRay, "")
        );

        RateLimitBucketLib.Bucket memory afterApply = withdrawalExecutionPolicy.getRedemptionBucket();
        assertEq(
            afterApply.consumed, uint128(uint256(before.consumed) + iouAmountRay), "Consumed should reflect amount"
        );
    }

    function test_applyWithdrawalExecutionPolicy_reverts_whenBucketExhausted() public {
        WithdrawalExecutionPolicy policy = _deployPolicyWithCustomFloors(1, 1);
        policy.lowerRedemptionCapacity(1000);
        policy.lowerRedemptionRefillRate(1);

        // Drain the bucket.
        policy.applyWithdrawalExecutionPolicy(_buildRequest(address(0xBEEF), address(0xCAFE), 1000, ""));

        vm.expectRevert(abi.encodeWithSelector(RateLimitBucketLib.RateLimited.selector, 1, 0));
        policy.applyWithdrawalExecutionPolicy(_buildRequest(address(0xBEEF), address(0xCAFE), 1, ""));
    }

    function test_applyWithdrawalExecutionPolicy_succeedsAfterRefill() public {
        WithdrawalExecutionPolicy policy = _deployPolicyWithCustomFloors(1, 1);
        policy.lowerRedemptionCapacity(1000);
        policy.lowerRedemptionRefillRate(10);

        policy.applyWithdrawalExecutionPolicy(_buildRequest(address(0xBEEF), address(0xCAFE), 1000, ""));

        vm.warp(block.timestamp + 100);
        policy.applyWithdrawalExecutionPolicy(_buildRequest(address(0xBEEF), address(0xCAFE), 1000, ""));
    }

    function test_previewWithdrawalExecutionPolicy_returnsZero_whenBucketExhausted() public {
        WithdrawalExecutionPolicy policy = _deployPolicyWithCustomFloors(1, 1);
        policy.lowerRedemptionCapacity(1000);
        policy.lowerRedemptionRefillRate(1);
        policy.applyWithdrawalExecutionPolicy(_buildRequest(address(0xBEEF), address(0xCAFE), 1000, ""));

        uint256 previewed =
            policy.previewWithdrawalExecutionPolicy(_buildRequest(address(0xBEEF), address(0xCAFE), 1, ""));
        assertEq(previewed, 0, "Preview should return 0 when bucket is exhausted");
    }

    function test_previewWithdrawalExecutionPolicy_returnsAmount_whenWithinBucket(uint128 iouAmountRay) public view {
        iouAmountRay = uint128(bound(iouAmountRay, 1, SEED_REDEMPTION_CAPACITY));
        uint256 previewed = withdrawalExecutionPolicy.previewWithdrawalExecutionPolicy(
            _buildRequest(address(0xBEEF), address(0xCAFE), iouAmountRay, "")
        );
        assertGt(previewed, 0, "Preview should be non-zero when within bucket");
    }

    function test_previewWithdrawalExecutionPolicy_returnsAmount_afterRefill() public {
        WithdrawalExecutionPolicy policy = _deployPolicyWithCustomFloors(1, 1);
        policy.lowerRedemptionCapacity(1000);
        policy.lowerRedemptionRefillRate(10);

        policy.applyWithdrawalExecutionPolicy(_buildRequest(address(0xBEEF), address(0xCAFE), 1000, ""));
        assertEq(
            policy.previewWithdrawalExecutionPolicy(_buildRequest(address(0xBEEF), address(0xCAFE), 1000, "")),
            0,
            "Preview should be 0 immediately after drain"
        );

        vm.warp(block.timestamp + 100);
        assertGt(
            policy.previewWithdrawalExecutionPolicy(_buildRequest(address(0xBEEF), address(0xCAFE), 1000, "")),
            0,
            "Preview should be non-zero after refill"
        );
    }

    function test_applyWithdrawalExecutionPolicy_doesNotMarkNonceWhenRateLimited() public {
        WithdrawalExecutionPolicy policy = _deployPolicyWithCustomFloors(1, 1);
        policy.lowerRedemptionCapacity(1000);
        policy.lowerRedemptionRefillRate(1);
        policy.applyWithdrawalExecutionPolicy(_buildRequest(address(0xBEEF), address(0xCAFE), 1000, ""));

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        policy.addSigner(signer);

        uint256 nonce = 42;
        bytes memory sig = _createSignedFeeDataForPolicy(
            policy, signerPk, address(0xBEEF), address(0xCAFE), 10, 0, nonce, DEFAULT_DEADLINE
        );

        vm.expectRevert();
        policy.applyWithdrawalExecutionPolicy(_buildRequest(address(0xBEEF), address(0xCAFE), 10, sig));

        assertFalse(policy.wasNonceUsed(signer, nonce), "Nonce should not be marked when consume reverts");
    }

    function _createSignedFeeDataForPolicy(
        WithdrawalExecutionPolicy policy,
        uint256 signerPk,
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeAmountRay,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 digest = _signedFeeDigestForPolicy(
            address(policy), user, assetOut, iouAmountRay, personalFeeAmountRay, nonce, deadline
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encode(
            WithdrawalExecutionPolicy.SignedFee({
                personalFeeAmountRay: personalFeeAmountRay,
                nonce: nonce,
                deadline: deadline,
                signature: abi.encodePacked(r, s, v)
            })
        );
    }

    function _signedFeeDigestForPolicy(
        address policyAddress,
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeAmountRay,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        bytes32 typeHash = WithdrawalExecutionPolicy(policyAddress).SIGNED_FEE_TYPEHASH();
        bytes32 structHash =
            keccak256(abi.encode(typeHash, user, assetOut, iouAmountRay, personalFeeAmountRay, nonce, deadline));
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256("WithdrawalExecutionPolicy"),
                keccak256("1"),
                block.chainid,
                policyAddress
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
    }
}

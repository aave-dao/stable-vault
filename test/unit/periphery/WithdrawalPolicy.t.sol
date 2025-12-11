// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {IWithdrawalPolicy} from "src/interfaces/IWithdrawalPolicy.sol";
import {ConstantsLib} from "src/libraries/ConstantsLib.sol";
import {ErrorsLib} from "src/libraries/ErrorsLib.sol";
import {WithdrawalPolicy} from "src/periphery/WithdrawalPolicy.sol";

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

    function _deployWithdrawalPolicy(address accessManager, address assetRegistry) internal returns (WithdrawalPolicy) {
        address withdrawalPolicyImpl = address(new WithdrawalPolicy(assetRegistry));
        return WithdrawalPolicy(
            address(
                new TransparentUpgradeableProxy(
                    withdrawalPolicyImpl, address(this), abi.encodeCall(WithdrawalPolicy.initialize, (accessManager))
                )
            )
        );
    }

    function setUp() public {
        mockAccessManager = new MockAccessManager(admin);
        mockAssetRegistry = new MockAssetRegistry();
        withdrawalPolicy = _deployWithdrawalPolicy(address(mockAccessManager), address(mockAssetRegistry));
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

    function test_setSigner_reverts_ifMsgSenderIsNotAuthorized(
        address unauthorizedMsgSender,
        address signer,
        bool whitelistedSigner
    ) public {
        vm.assume(unauthorizedMsgSender != address(0));
        _assumeNotProxyAdmin(unauthorizedMsgSender, address(withdrawalPolicy));
        mockAccessManager.mockRejectCall(
            unauthorizedMsgSender, address(withdrawalPolicy), WithdrawalPolicy.setSigner.selector
        );

        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedMsgSender)
        );
        vm.prank(unauthorizedMsgSender);
        withdrawalPolicy.setSigner(signer, whitelistedSigner);
    }

    // Setters & Getters tests

    function test_setAssetFeeBps_setsExpectedConfig(address asset, uint256 feeBps, bool isSet) public {
        feeBps = bound(feeBps, 0, 10_000); // ConstantsLib.MAX_BPS

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setAssetFeeBps(asset, uint16(feeBps), isSet);

        WithdrawalPolicy.AssetFeeConfig memory config = withdrawalPolicy.getAssetFeeConfig(asset);
        assertEq(config.feeBps, feeBps);
        assertEq(config.isSet, isSet);
    }

    function test_setAssetFeeBps_reverts_ifFeeBpsIsInvalid(address asset, uint256 feeBps, bool isSet) public {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 feeBps16 = uint16(bound(feeBps, 10_001, type(uint16).max));

        vm.expectRevert(ErrorsLib.InvalidParameter.selector);
        vm.prank(admin);
        withdrawalPolicy.setAssetFeeBps(asset, feeBps16, isSet);
    }

    function test_setDefaultFeeBps_setsExpectedFee(uint256 feeBps) public {
        feeBps = bound(feeBps, 0, ConstantsLib.MAX_BPS);

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(feeBps));

        assertEq(withdrawalPolicy.getDefaultFeeBps(), feeBps);
    }

    function test_setDefaultFeeBps_reverts_ifFeeBpsIsInvalid(uint256 feeBps) public {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint16 feeBps16 = uint16(bound(feeBps, ConstantsLib.MAX_BPS + 1, type(uint16).max));

        vm.expectRevert(ErrorsLib.InvalidParameter.selector);
        vm.prank(admin);
        withdrawalPolicy.setDefaultFeeBps(feeBps16);
    }

    function test_setSigner_setsSignerStatus(address signer, bool isSigner) public {
        vm.prank(admin);
        withdrawalPolicy.setSigner(signer, isSigner);

        assertEq(withdrawalPolicy.isSigner(signer), isSigner);
    }

    // Calculation tests

    function test_applyWithdrawalPolicy_returnsDefaultFee(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 baseFeeBps
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, ConstantsLib.MAX_BPS);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - ConstantsLib.MAX_BPS) / ConstantsLib.MAX_BPS);

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        // Fee rounds up, so expectedAmountOut rounds down
        uint256 expectedFee = (iouAmountRay * baseFeeBps + ConstantsLib.MAX_BPS - 1) / ConstantsLib.MAX_BPS;
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
        baseFeeBps = bound(baseFeeBps, 0, ConstantsLib.MAX_BPS);
        assetFeeBps = bound(assetFeeBps, 0, ConstantsLib.MAX_BPS);
        // Bound to prevent overflow in fee calculation: iouAmountRay * feeBps + MAX_BPS - 1
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - ConstantsLib.MAX_BPS) / ConstantsLib.MAX_BPS);

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));
        assertEq(withdrawalPolicy.getDefaultFeeBps(), baseFeeBps);

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setAssetFeeBps(assetOut, uint16(assetFeeBps), true);

        // Fee rounds up, so expectedAmountOut rounds down
        uint256 expectedFee = (iouAmountRay * assetFeeBps + ConstantsLib.MAX_BPS - 1) / ConstantsLib.MAX_BPS;
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
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - ConstantsLib.MAX_BPS) / ConstantsLib.MAX_BPS);

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
        withdrawalPolicy.setSigner(signer, true);
        assertTrue(withdrawalPolicy.isSigner(signer), "Signer is not whitelisted");

        // Build signed fee discount data
        bytes memory data = _createSignedFeeDiscountData(
            signerPk, user, assetOut, iouAmountRay, _toUint16(personalFeeBps), DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        // Fee rounds up, so expectedAmountOut rounds down
        uint256 expectedFee = (iouAmountRay * personalFeeBps + ConstantsLib.MAX_BPS - 1) / ConstantsLib.MAX_BPS;
        uint256 expectedAmountOut = iouAmountRay - expectedFee;

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

    function test_applyWithdrawalPolicy_reverts_ifPersonalFeeExceedsOtherFees(
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
        uint16 personalFeeBps16;
        if (isAssetFeeSet) {
            personalFeeBps16 = uint16(bound(personalFeeBps, 100_01, type(uint16).max));
        } else {
            personalFeeBps16 = uint16(bound(personalFeeBps, 100_01, type(uint16).max));
        }
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - ConstantsLib.MAX_BPS) / ConstantsLib.MAX_BPS);

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
        withdrawalPolicy.setSigner(signer, true);
        assertTrue(withdrawalPolicy.isSigner(signer), "Signer is not whitelisted");

        // Build signed fee discount data
        bytes memory data = _createSignedFeeDiscountData(
            signerPk, user, assetOut, iouAmountRay, personalFeeBps16, DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        vm.expectRevert(ErrorsLib.InvalidParameter.selector);
        withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
    }

    function test_applyWithdrawalPolicy_reverts_ifSignerIsNotWhitelisted(
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
        vm.assume(withdrawalPolicy.isSigner(nonWhitelistedSigner) == false);

        baseFeeBps = bound(baseFeeBps, 0, ConstantsLib.MAX_BPS);
        personalFeeBps = bound(personalFeeBps, 0, baseFeeBps);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - ConstantsLib.MAX_BPS) / ConstantsLib.MAX_BPS);

        // Setup base fee
        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        // Build signed fee discount data with non-whitelisted signer
        bytes memory data = _createSignedFeeDiscountData(
            nonWhitelistedSignerPk,
            user,
            assetOut,
            iouAmountRay,
            _toUint16(personalFeeBps),
            DEFAULT_NONCE,
            DEFAULT_DEADLINE
        );

        vm.expectRevert(WithdrawalPolicy.InvalidSignature.selector);
        withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
    }

    function test_applyWithdrawalPolicy_reverts_ifSignatureIsForDifferentUser(
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
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - ConstantsLib.MAX_BPS) / ConstantsLib.MAX_BPS);

        // Setup base fee
        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        // Create signer wallet and whitelist it
        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.setSigner(signer, true);

        // Build signed fee discount data for WRONG user
        bytes memory data = _createSignedFeeDiscountData(
            signerPk, wrongUser, assetOut, iouAmountRay, _toUint16(personalFeeBps), DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        vm.expectRevert(WithdrawalPolicy.InvalidSignature.selector);
        withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
    }

    function test_applyWithdrawalPolicy_reverts_ifSignatureIsForDifferentAsset(
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
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - ConstantsLib.MAX_BPS) / ConstantsLib.MAX_BPS);

        // Setup base fee
        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        // Create signer wallet and whitelist it
        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.setSigner(signer, true);

        // Build signed fee discount data for WRONG asset
        bytes memory data = _createSignedFeeDiscountData(
            signerPk, user, wrongAssetOut, iouAmountRay, _toUint16(personalFeeBps), DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        vm.expectRevert(WithdrawalPolicy.InvalidSignature.selector);
        withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
    }

    function test_applyWithdrawalPolicy_reverts_ifSignatureIsForDifferentAmount(
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
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - ConstantsLib.MAX_BPS) / ConstantsLib.MAX_BPS);
        wrongIouAmountRay =
            bound(wrongIouAmountRay, 0, (type(uint256).max - ConstantsLib.MAX_BPS) / ConstantsLib.MAX_BPS);
        vm.assume(iouAmountRay != wrongIouAmountRay);

        // Setup base fee
        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        // Create signer wallet and whitelist it
        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.setSigner(signer, true);

        // Build signed fee discount data for WRONG amount
        bytes memory data = _createSignedFeeDiscountData(
            signerPk, user, assetOut, wrongIouAmountRay, _toUint16(personalFeeBps), DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        vm.expectRevert(WithdrawalPolicy.InvalidSignature.selector);
        withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
    }

    function test_applyWithdrawalPolicy_reverts_ifSignatureIsForDifferentPersonalFee(
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
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - ConstantsLib.MAX_BPS) / ConstantsLib.MAX_BPS);

        // Setup base fee
        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        // Create signer wallet and whitelist it
        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.setSigner(signer, true);

        // Create data with the CORRECT personalFeeBps but signature for WRONG personalFeeBps
        bytes memory wrongData = _createSignedFeeDiscountDataWithMismatch(
            signerPk,
            user,
            assetOut,
            iouAmountRay,
            _toUint16(personalFeeBps), // claimed in data
            _toUint16(wrongPersonalFeeBps), // signed
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
        uint256 personalFeeBps,
        uint256 baseFeeBps,
        bytes memory malformedSignature
    ) public {
        vm.assume(malformedSignature.length != 65);
        baseFeeBps = bound(baseFeeBps, 0, ConstantsLib.MAX_BPS);
        personalFeeBps = bound(personalFeeBps, 0, baseFeeBps);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - ConstantsLib.MAX_BPS) / ConstantsLib.MAX_BPS);

        // Setup base fee
        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        // Create signer wallet and whitelist it
        (address signer,) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.setSigner(signer, true);

        // Manually encode SignedFeeDiscount with malformed signature
        bytes memory data = abi.encode(
            WithdrawalPolicy.SignedFeeDiscount({
                personalFeeBps: _toUint16(personalFeeBps),
                nonce: DEFAULT_NONCE,
                deadline: DEFAULT_DEADLINE,
                signature: malformedSignature
            })
        );

        vm.expectRevert();
        withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
    }

    function test_applyWithdrawalPolicy_reverts_ifAssetIsNotSupported(
        address user,
        address assetOut,
        uint256 iouAmountRay
    ) public {
        mockAssetRegistry.mockToDisallowAssetWithdrawals(assetOut);

        IWithdrawalPolicy.WithdrawalRequest memory request = _buildRequest(user, assetOut, iouAmountRay, "");

        // Both preview and apply should revert
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnsupportedAsset.selector, assetOut));
        withdrawalPolicy.previewWithdrawalPolicy(request);

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnsupportedAsset.selector, assetOut));
        withdrawalPolicy.applyWithdrawalPolicy(request);
    }

    function test_applyWithdrawalPolicy_reverts_ifDeadlineExpired() public {
        address user = makeAddr("user");
        address assetOut = makeAddr("assetOut");
        uint256 iouAmountRay = 1000e27;
        uint16 personalFeeBps = 0;
        uint16 baseFeeBps = 1000;

        vm.prank(admin);
        withdrawalPolicy.setDefaultFeeBps(baseFeeBps);

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.setSigner(signer, true);

        // Create signature with expired deadline
        uint256 expiredDeadline = block.timestamp - 1;
        bytes memory data = _createSignedFeeDiscountData(
            signerPk, user, assetOut, iouAmountRay, personalFeeBps, DEFAULT_NONCE, expiredDeadline
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
        uint16 personalFeeBps = 500; // 5% fee
        uint16 baseFeeBps = 1000; // 10% base fee

        vm.prank(admin);
        withdrawalPolicy.setDefaultFeeBps(baseFeeBps);

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.setSigner(signer, true);

        bytes memory data = _createSignedFeeDiscountData(
            signerPk, user, assetOut, iouAmountRay, personalFeeBps, DEFAULT_NONCE, DEFAULT_DEADLINE
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
        uint16 personalFeeBps = 0; // 0% fee (waiver)
        uint16 baseFeeBps = 1000; // 10% base fee

        // Setup: Configure base fee and whitelist signer
        vm.prank(admin);
        withdrawalPolicy.setDefaultFeeBps(baseFeeBps);

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.setSigner(signer, true);

        // Create signature for personal fee waiver
        bytes memory data = _createSignedFeeDiscountData(
            signerPk, user, assetOut, iouAmountRay, personalFeeBps, DEFAULT_NONCE, DEFAULT_DEADLINE
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
        withdrawalPolicy.setSigner(signer, true);

        uint256 nonce = 42;
        assertFalse(withdrawalPolicy.wasNonceUsed(signer, nonce), "Nonce should not be used initially");

        vm.prank(signer);
        withdrawalPolicy.invalidateNonce(signer, nonce);

        assertTrue(withdrawalPolicy.wasNonceUsed(signer, nonce), "Nonce should be invalidated");
    }

    function test_invalidateNonce_emitsExpectedEvent(uint256 nonceSalt) public {
        (address signer,) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.setSigner(signer, true);

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
        withdrawalPolicy.setSigner(signer, true);

        vm.prank(notSigner);
        vm.expectRevert(ErrorsLib.NotAuthorized.selector);
        withdrawalPolicy.invalidateNonce(notSigner, 1);
    }

    function test_invalidateNonce_reverts_ifSignerParamDoesNotMatchCaller() public {
        (address signer1,) = makeAddrAndKey("signer1");
        (address signer2,) = makeAddrAndKey("signer2");
        vm.prank(admin);
        withdrawalPolicy.setSigner(signer1, true);
        vm.prank(admin);
        withdrawalPolicy.setSigner(signer2, true);

        // signer1 tries to invalidate signer2's nonce
        vm.prank(signer1);
        vm.expectRevert(ErrorsLib.NotAuthorized.selector);
        withdrawalPolicy.invalidateNonce(signer2, 1);
    }

    function test_invalidateNonce_preventsSignatureFromBeingApplied(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeBps,
        uint256 baseFeeBps,
        uint256 nonce
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, ConstantsLib.MAX_BPS);
        personalFeeBps = bound(personalFeeBps, 0, baseFeeBps);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - ConstantsLib.MAX_BPS) / ConstantsLib.MAX_BPS);

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.setSigner(signer, true);

        bytes memory data = _createSignedFeeDiscountData(
            signerPk, user, assetOut, iouAmountRay, _toUint16(personalFeeBps), nonce, DEFAULT_DEADLINE
        );

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
        uint256 personalFeeBps,
        uint256 baseFeeBps,
        uint256 nonce
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, ConstantsLib.MAX_BPS);
        personalFeeBps = bound(personalFeeBps, 0, baseFeeBps);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - ConstantsLib.MAX_BPS) / ConstantsLib.MAX_BPS);

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.setSigner(signer, true);

        bytes memory data = _createSignedFeeDiscountData(
            signerPk, user, assetOut, iouAmountRay, _toUint16(personalFeeBps), nonce, DEFAULT_DEADLINE
        );

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
        uint16 personalFeeBps = 500;
        uint16 baseFeeBps = 1000;

        vm.prank(admin);
        withdrawalPolicy.setDefaultFeeBps(baseFeeBps);

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.setSigner(signer, true);

        // Deadline exactly at current timestamp should work
        uint256 deadline = block.timestamp;
        bytes memory data = _createSignedFeeDiscountData(
            signerPk, user, assetOut, iouAmountRay, personalFeeBps, DEFAULT_NONCE, deadline
        );

        // Should succeed
        uint256 amountOut = withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
        assertGt(amountOut, 0, "Should return non-zero amount");
    }

    function test_applyWithdrawalPolicy_acceptsDeadlineInFuture(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeBps,
        uint256 baseFeeBps,
        uint256 deadlineOffset
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, ConstantsLib.MAX_BPS);
        personalFeeBps = bound(personalFeeBps, 0, baseFeeBps);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - ConstantsLib.MAX_BPS) / ConstantsLib.MAX_BPS);
        deadlineOffset = bound(deadlineOffset, 1, 365 days);

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.setSigner(signer, true);

        // Deadline in the future should work
        uint256 deadline = block.timestamp + deadlineOffset;
        bytes memory data = _createSignedFeeDiscountData(
            signerPk, user, assetOut, iouAmountRay, _toUint16(personalFeeBps), DEFAULT_NONCE, deadline
        );

        // Should succeed
        uint256 amountOut = withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
        uint256 expectedFee = (iouAmountRay * personalFeeBps + ConstantsLib.MAX_BPS - 1) / ConstantsLib.MAX_BPS;
        assertEq(amountOut, iouAmountRay - expectedFee, "Should return correct amount");
    }

    // Nonce Tests

    function test_applyWithdrawalPolicy_allowsDifferentNoncesFromSameSigner(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeBps,
        uint256 baseFeeBps,
        uint256 nonce1,
        uint256 nonce2,
        uint256 nonce3
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, ConstantsLib.MAX_BPS);
        personalFeeBps = bound(personalFeeBps, 0, baseFeeBps);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - ConstantsLib.MAX_BPS) / ConstantsLib.MAX_BPS);
        vm.assume(nonce1 != nonce2 && nonce2 != nonce3 && nonce1 != nonce3);

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.setSigner(signer, true);

        // First signature with nonce1
        bytes memory data1 = _createSignedFeeDiscountData(
            signerPk, user, assetOut, iouAmountRay, _toUint16(personalFeeBps), nonce1, DEFAULT_DEADLINE
        );
        withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data1));
        assertTrue(withdrawalPolicy.wasNonceUsed(signer, nonce1), "Nonce1 should be used");

        // Second signature with nonce2 should also work
        bytes memory data2 = _createSignedFeeDiscountData(
            signerPk, user, assetOut, iouAmountRay, _toUint16(personalFeeBps), nonce2, DEFAULT_DEADLINE
        );
        withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data2));
        assertTrue(withdrawalPolicy.wasNonceUsed(signer, nonce2), "Nonce2 should be used");

        // Third signature with nonce3 should also work
        bytes memory data3 = _createSignedFeeDiscountData(
            signerPk, user, assetOut, iouAmountRay, _toUint16(personalFeeBps), nonce3, DEFAULT_DEADLINE
        );
        withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data3));
        assertTrue(withdrawalPolicy.wasNonceUsed(signer, nonce3), "Nonce3 should be used");
    }

    function test_applyWithdrawalPolicy_acceptsNonceZero() public {
        address user = makeAddr("user");
        address assetOut = makeAddr("assetOut");
        uint256 iouAmountRay = 1000e27;
        uint16 personalFeeBps = 500;
        uint16 baseFeeBps = 1000;

        vm.prank(admin);
        withdrawalPolicy.setDefaultFeeBps(baseFeeBps);

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.setSigner(signer, true);

        // Nonce 0 should be valid
        uint256 nonceZero = 0;
        bytes memory data = _createSignedFeeDiscountData(
            signerPk, user, assetOut, iouAmountRay, personalFeeBps, nonceZero, DEFAULT_DEADLINE
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
        uint256 personalFeeBps,
        uint256 baseFeeBps,
        uint256 sharedNonce
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, ConstantsLib.MAX_BPS);
        personalFeeBps = bound(personalFeeBps, 0, baseFeeBps);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - ConstantsLib.MAX_BPS) / ConstantsLib.MAX_BPS);

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        (address signer1, uint256 signerPk1) = makeAddrAndKey("signer1");
        (address signer2, uint256 signerPk2) = makeAddrAndKey("signer2");
        vm.prank(admin);
        withdrawalPolicy.setSigner(signer1, true);
        vm.prank(admin);
        withdrawalPolicy.setSigner(signer2, true);

        // Signer1 uses the shared nonce
        bytes memory data1 = _createSignedFeeDiscountData(
            signerPk1, user, assetOut, iouAmountRay, _toUint16(personalFeeBps), sharedNonce, DEFAULT_DEADLINE
        );
        withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data1));
        assertTrue(withdrawalPolicy.wasNonceUsed(signer1, sharedNonce), "Signer1 nonce should be used");
        assertFalse(withdrawalPolicy.wasNonceUsed(signer2, sharedNonce), "Signer2 nonce should not be used yet");

        // Signer2 can also use the same nonce
        bytes memory data2 = _createSignedFeeDiscountData(
            signerPk2, user, assetOut, iouAmountRay, _toUint16(personalFeeBps), sharedNonce, DEFAULT_DEADLINE
        );
        withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data2));
        assertTrue(withdrawalPolicy.wasNonceUsed(signer2, sharedNonce), "Signer2 nonce should now be used");
    }

    // Signer Removal Tests

    function test_applyWithdrawalPolicy_reverts_ifSignerWasRemoved(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeBps,
        uint256 baseFeeBps
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, ConstantsLib.MAX_BPS);
        personalFeeBps = bound(personalFeeBps, 0, baseFeeBps);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - ConstantsLib.MAX_BPS) / ConstantsLib.MAX_BPS);

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.setSigner(signer, true);

        bytes memory data = _createSignedFeeDiscountData(
            signerPk, user, assetOut, iouAmountRay, _toUint16(personalFeeBps), DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        // Remove the signer
        vm.prank(admin);
        withdrawalPolicy.setSigner(signer, false);
        assertFalse(withdrawalPolicy.isSigner(signer), "Signer should be removed");

        // Apply should revert because signer is no longer whitelisted
        vm.expectRevert(WithdrawalPolicy.InvalidSignature.selector);
        withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
    }

    function test_previewWithdrawalPolicy_reverts_ifSignerWasRemoved(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeBps,
        uint256 baseFeeBps
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, ConstantsLib.MAX_BPS);
        personalFeeBps = bound(personalFeeBps, 0, baseFeeBps);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - ConstantsLib.MAX_BPS) / ConstantsLib.MAX_BPS);

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.setSigner(signer, true);

        bytes memory data = _createSignedFeeDiscountData(
            signerPk, user, assetOut, iouAmountRay, _toUint16(personalFeeBps), DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        // Remove the signer
        vm.prank(admin);
        withdrawalPolicy.setSigner(signer, false);

        // Preview should also revert because signer is no longer whitelisted
        vm.expectRevert(WithdrawalPolicy.InvalidSignature.selector);
        withdrawalPolicy.previewWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
    }

    function test_previewWithdrawalPolicy_becomesInvalidAfterSignerRemoved(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeBps,
        uint256 baseFeeBps
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, ConstantsLib.MAX_BPS);
        personalFeeBps = bound(personalFeeBps, 0, baseFeeBps);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - ConstantsLib.MAX_BPS) / ConstantsLib.MAX_BPS);

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.setSigner(signer, true);

        bytes memory data = _createSignedFeeDiscountData(
            signerPk, user, assetOut, iouAmountRay, _toUint16(personalFeeBps), DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        IWithdrawalPolicy.WithdrawalRequest memory request = _buildRequest(user, assetOut, iouAmountRay, data);

        // Preview works while signer is whitelisted
        uint256 previewAmount = withdrawalPolicy.previewWithdrawalPolicy(request);
        uint256 expectedFee = (iouAmountRay * personalFeeBps + ConstantsLib.MAX_BPS - 1) / ConstantsLib.MAX_BPS;
        assertEq(previewAmount, iouAmountRay - expectedFee, "Preview should return correct amount");

        // Remove the signer
        vm.prank(admin);
        withdrawalPolicy.setSigner(signer, false);

        // Same preview should now revert
        vm.expectRevert(WithdrawalPolicy.InvalidSignature.selector);
        withdrawalPolicy.previewWithdrawalPolicy(request);
    }

    function test_applyWithdrawalPolicy_acceptsSignatureAfterSignerReAdded(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeBps,
        uint256 baseFeeBps
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, ConstantsLib.MAX_BPS);
        personalFeeBps = bound(personalFeeBps, 0, baseFeeBps);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - ConstantsLib.MAX_BPS) / ConstantsLib.MAX_BPS);

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        (address signer, uint256 signerPk) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.setSigner(signer, true);

        bytes memory data = _createSignedFeeDiscountData(
            signerPk, user, assetOut, iouAmountRay, _toUint16(personalFeeBps), DEFAULT_NONCE, DEFAULT_DEADLINE
        );

        // Remove the signer
        vm.prank(admin);
        withdrawalPolicy.setSigner(signer, false);

        // Apply should revert
        vm.expectRevert(WithdrawalPolicy.InvalidSignature.selector);
        withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data));

        // Re-add the signer
        vm.prank(admin);
        withdrawalPolicy.setSigner(signer, true);

        // Apply should now succeed
        uint256 amountOut = withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data));
        uint256 expectedFee = (iouAmountRay * personalFeeBps + ConstantsLib.MAX_BPS - 1) / ConstantsLib.MAX_BPS;
        assertEq(amountOut, iouAmountRay - expectedFee, "Should return correct amount after signer re-added");
    }

    function test_applyWithdrawalPolicy_otherSignersUnaffectedWhenOneRemoved(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint256 personalFeeBps,
        uint256 baseFeeBps
    ) public {
        baseFeeBps = bound(baseFeeBps, 0, ConstantsLib.MAX_BPS);
        personalFeeBps = bound(personalFeeBps, 0, baseFeeBps);
        iouAmountRay = bound(iouAmountRay, 0, (type(uint256).max - ConstantsLib.MAX_BPS) / ConstantsLib.MAX_BPS);

        vm.prank(admin);
        // forge-lint: disable-next-line(unsafe-typecast)
        withdrawalPolicy.setDefaultFeeBps(uint16(baseFeeBps));

        (address signer1, uint256 signerPk1) = makeAddrAndKey("signer1");
        (address signer2, uint256 signerPk2) = makeAddrAndKey("signer2");
        vm.prank(admin);
        withdrawalPolicy.setSigner(signer1, true);
        vm.prank(admin);
        withdrawalPolicy.setSigner(signer2, true);

        bytes memory data1 = _createSignedFeeDiscountData(
            signerPk1, user, assetOut, iouAmountRay, _toUint16(personalFeeBps), 1, DEFAULT_DEADLINE
        );
        bytes memory data2 = _createSignedFeeDiscountData(
            signerPk2, user, assetOut, iouAmountRay, _toUint16(personalFeeBps), 1, DEFAULT_DEADLINE
        );

        // Remove signer1
        vm.prank(admin);
        withdrawalPolicy.setSigner(signer1, false);

        // Signer1's signature should fail
        vm.expectRevert(WithdrawalPolicy.InvalidSignature.selector);
        withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data1));

        // Signer2's signature should still work
        uint256 amountOut = withdrawalPolicy.applyWithdrawalPolicy(_buildRequest(user, assetOut, iouAmountRay, data2));
        uint256 expectedFee = (iouAmountRay * personalFeeBps + ConstantsLib.MAX_BPS - 1) / ConstantsLib.MAX_BPS;
        assertEq(amountOut, iouAmountRay - expectedFee, "Signer2 signature should still work");
    }

    function test_invalidateNonce_reverts_ifSignerWasRemoved(uint256 nonce1, uint256 nonce2) public {
        vm.assume(nonce1 != nonce2);

        (address signer,) = makeAddrAndKey("signer");
        vm.prank(admin);
        withdrawalPolicy.setSigner(signer, true);

        // Signer can invalidate while whitelisted
        vm.prank(signer);
        withdrawalPolicy.invalidateNonce(signer, nonce1);
        assertTrue(withdrawalPolicy.wasNonceUsed(signer, nonce1), "Nonce1 should be invalidated");

        // Remove the signer
        vm.prank(admin);
        withdrawalPolicy.setSigner(signer, false);

        // Removed signer cannot invalidate nonces anymore
        vm.prank(signer);
        vm.expectRevert(ErrorsLib.NotAuthorized.selector);
        withdrawalPolicy.invalidateNonce(signer, nonce2);
    }

    // Helper to safely cast personalFeeBps to uint16 (safe because it's always bounded to MAX_BPS = 10000)
    function _toUint16(uint256 value) internal pure returns (uint16) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(value);
    }

    // Helper to create signed fee discount data
    function _createSignedFeeDiscountData(
        uint256 signerPk,
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint16 personalFeeBps,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes memory signature =
            _signFeeDiscount(signerPk, user, assetOut, iouAmountRay, personalFeeBps, nonce, deadline);

        return abi.encode(
            WithdrawalPolicy.SignedFeeDiscount({
                personalFeeBps: personalFeeBps, nonce: nonce, deadline: deadline, signature: signature
            })
        );
    }

    // Helper for mismatch test - creates data where claimed fee differs from signed fee
    function _createSignedFeeDiscountDataWithMismatch(
        uint256 signerPk,
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint16 claimedFeeBps,
        uint16 signedFeeBps,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        // Sign with signedFeeBps but encode with claimedFeeBps
        bytes memory signature = _signFeeDiscount(signerPk, user, assetOut, iouAmountRay, signedFeeBps, nonce, deadline);

        return abi.encode(
            WithdrawalPolicy.SignedFeeDiscount({
                personalFeeBps: claimedFeeBps, nonce: nonce, deadline: deadline, signature: signature
            })
        );
    }

    function _signFeeDiscount(
        uint256 signerPk,
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint16 personalFeeBps,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes memory) {
        bytes32 digest = _buildFeeDiscountDigest(user, assetOut, iouAmountRay, personalFeeBps, nonce, deadline);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _buildFeeDiscountDigest(
        address user,
        address assetOut,
        uint256 iouAmountRay,
        uint16 personalFeeBps,
        uint256 nonce,
        uint256 deadline
    ) internal view returns (bytes32) {
        // Must match FEE_DISCOUNT_TYPEHASH in WithdrawalPolicy
        bytes32 typeHash = keccak256(
            "FeeDiscount(address user,address assetOut,uint256 iouAmountRay,uint16 personalFeeBps,uint256 nonce,uint256 deadline)"
        );

        bytes32 structHash =
            keccak256(abi.encode(typeHash, user, assetOut, iouAmountRay, personalFeeBps, nonce, deadline));

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

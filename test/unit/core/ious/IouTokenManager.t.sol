// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {IouToken} from "src/core/ious/IouToken.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {IIouTokenManager} from "src/interfaces/IIouTokenManager.sol";
import {Errors} from "src/types/Errors.sol";

import {ExtendedIouTokenManager} from "test/mocks/ExtendedIouTokenManager.sol";
import {MockErc20} from "test/mocks/MockErc20.sol";
import {MockGateway} from "test/mocks/MockGateway.sol";
import {MockTransferHelper} from "test/mocks/MockTransferHelper.sol";

contract IouTokenManagerTest_AccountingChain is Test {
    ExtendedIouTokenManager public iouTokenManager;
    address public iouToken;
    address public chainGateway;
    address public vault = makeAddr("VAULT");
    address public transferHelper;
    address iouTokenManagerAddress;
    address iouTokenAddress;

    function setUp() public virtual {
        chainGateway = address(new MockGateway());
        transferHelper = address(new MockTransferHelper());

        uint256 deployerNonce = vm.getNonce(address(this));

        iouTokenManagerAddress = vm.computeCreateAddress(address(this), deployerNonce);
        iouTokenAddress = vm.computeCreateAddress(address(this), deployerNonce + 1);

        iouTokenManager = new ExtendedIouTokenManager(iouTokenAddress, chainGateway, vault, transferHelper, true);
        iouToken = address(new IouToken(iouTokenManagerAddress, "IOU: Aave USD Stable Vault", "IOU-USD"));

        assertEq(iouTokenManagerAddress, address(iouTokenManager));
        assertEq(iouTokenAddress, iouToken);
    }

    function test_constructor_reverts_ifInvalidTransferHelper() public {
        vm.expectRevert();
        new ExtendedIouTokenManager(iouTokenAddress, chainGateway, vault, address(0), true);
    }

    // Minting tokens

    function test_mintTokens_withGateway(address mintTo, uint256 amountToMint) public {
        vm.assume(mintTo != address(0));
        vm.expectCall(iouToken, abi.encodeWithSelector(IouToken.mint.selector, mintTo, amountToMint), 1);
        vm.prank(chainGateway);
        iouTokenManager.mintTokens(mintTo, amountToMint);
    }

    function test_mintTokens_withVault(address mintTo, uint256 amountToMint) public {
        vm.assume(mintTo != address(0));
        vm.expectCall(iouToken, abi.encodeWithSelector(IouToken.mint.selector, mintTo, amountToMint), 1);
        vm.prank(vault);
        iouTokenManager.mintTokens(mintTo, amountToMint);
    }

    function test_mintTokens_reverts_if_notAllowedMinter(address nonAllowedMinter, address mintTo, uint256 amountToMint)
        public
    {
        vm.assume(nonAllowedMinter != chainGateway && nonAllowedMinter != vault);
        vm.expectRevert(Errors.NotAuthorized.selector);
        vm.prank(nonAllowedMinter);
        iouTokenManager.mintTokens(mintTo, amountToMint);
    }

    // Burning tokens

    function test_burnTokens_withGateway(address burnFrom, uint256 amountToBurn) public {
        vm.assume(burnFrom != address(0));
        vm.prank(iouTokenManagerAddress);
        MockErc20(iouToken).mint(burnFrom, amountToBurn);
        vm.expectCall(iouToken, abi.encodeWithSelector(IouToken.burn.selector, burnFrom, amountToBurn), 1);
        vm.prank(chainGateway);
        iouTokenManager.burnTokens(burnFrom, amountToBurn);
    }

    function test_burnTokens_withVault(address burnFrom, uint256 amountToBurn) public {
        vm.assume(burnFrom != address(0));
        vm.prank(iouTokenManagerAddress);
        MockErc20(iouToken).mint(burnFrom, amountToBurn);
        vm.expectCall(iouToken, abi.encodeWithSelector(IouToken.burn.selector, burnFrom, amountToBurn), 1);
        vm.prank(vault);
        iouTokenManager.burnTokens(burnFrom, amountToBurn);
    }

    function test_burnTokens_reverts_if_notAllowedBurner(
        address nonAllowedBurner,
        address burnFrom,
        uint256 amountToBurn
    ) public {
        vm.assume(burnFrom != address(0));
        vm.assume(nonAllowedBurner != chainGateway && nonAllowedBurner != vault);
        vm.expectRevert(Errors.NotAuthorized.selector);
        vm.prank(nonAllowedBurner);
        iouTokenManager.burnTokens(burnFrom, amountToBurn);
    }

    // Burning locked tokens

    function test_burnLockedTokens_withGateway(uint256 lockedBalance, uint256 amountToBurn) public virtual {
        amountToBurn = bound(amountToBurn, 0, lockedBalance);
        vm.prank(iouTokenManagerAddress);
        MockErc20(iouToken).mint(address(iouTokenManager), lockedBalance);
        iouTokenManager.mockLockedBalance(lockedBalance);
        uint256 lockedBalanceBefore = iouTokenManager.getLockedBalance();
        vm.expectCall(
            iouToken, abi.encodeWithSelector(IouToken.burn.selector, address(iouTokenManager), amountToBurn), 1
        );
        vm.prank(chainGateway);
        iouTokenManager.burnLockedTokens(amountToBurn);
        uint256 lockedBalanceAfter = iouTokenManager.getLockedBalance();
        assertEq(lockedBalanceAfter, lockedBalanceBefore - amountToBurn, "Locked balance not properly updated");
    }

    function test_burnLockedTokens_withVault(uint256 lockedBalance, uint256 amountToBurn) public virtual {
        amountToBurn = bound(amountToBurn, 0, lockedBalance);
        vm.prank(iouTokenManagerAddress);
        MockErc20(iouToken).mint(address(iouTokenManager), lockedBalance);
        iouTokenManager.mockLockedBalance(lockedBalance);
        uint256 lockedBalanceBefore = iouTokenManager.getLockedBalance();
        vm.expectCall(
            iouToken, abi.encodeWithSelector(IouToken.burn.selector, address(iouTokenManager), amountToBurn), 1
        );
        vm.prank(vault);
        iouTokenManager.burnLockedTokens(amountToBurn);
        uint256 lockedBalanceAfter = iouTokenManager.getLockedBalance();
        assertEq(lockedBalanceAfter, lockedBalanceBefore - amountToBurn, "Locked balance not properly updated");
    }

    function test_burnLockedTokens_reverts_if_notAllowedBurner(address nonAllowedBurner, uint256 amountToBurn)
        public
        virtual
    {
        vm.assume(nonAllowedBurner != chainGateway && nonAllowedBurner != vault);
        vm.expectRevert(Errors.NotAuthorized.selector);
        vm.prank(nonAllowedBurner);
        iouTokenManager.burnLockedTokens(amountToBurn);
    }

    function test_burnLockedTokens_reverts_if_insufficientLockedBalance_withGateway(
        uint256 lockedBalance,
        uint256 amountToBurn
    ) public virtual {
        vm.assume(lockedBalance < type(uint256).max);
        amountToBurn = bound(amountToBurn, lockedBalance + 1, type(uint256).max);
        vm.prank(iouTokenManagerAddress);
        MockErc20(iouToken).mint(address(iouTokenManager), lockedBalance);
        vm.expectRevert(IIouTokenManager.InsufficientLockedBalance.selector);
        vm.prank(chainGateway);
        iouTokenManager.burnLockedTokens(amountToBurn);
    }

    function test_burnLockedTokens_reverts_if_insufficientLockedBalance_withVault(
        uint256 lockedBalance,
        uint256 amountToBurn
    ) public virtual {
        vm.assume(lockedBalance < type(uint256).max);
        amountToBurn = bound(amountToBurn, lockedBalance + 1, type(uint256).max);
        vm.prank(iouTokenManagerAddress);
        MockErc20(iouToken).mint(address(iouTokenManager), lockedBalance);
        vm.expectRevert(IIouTokenManager.InsufficientLockedBalance.selector);
        vm.prank(vault);
        iouTokenManager.burnLockedTokens(amountToBurn);
    }

    // Releasing tokens

    function test_releaseTokens_withGateway(uint256 lockedBalance, uint256 amountToRelease) public virtual {
        amountToRelease = bound(amountToRelease, 0, lockedBalance);
        vm.prank(iouTokenManagerAddress);
        MockErc20(iouToken).mint(address(iouTokenManager), lockedBalance);
        iouTokenManager.mockLockedBalance(lockedBalance);
        uint256 lockedBalanceBefore = iouTokenManager.getLockedBalance();
        vm.expectCall(iouToken, abi.encodeWithSelector(IERC20.transfer.selector, msg.sender, amountToRelease), 1);
        vm.prank(chainGateway);
        iouTokenManager.releaseTokens(msg.sender, amountToRelease);
        uint256 lockedBalanceAfter = iouTokenManager.getLockedBalance();
        assertEq(lockedBalanceAfter, lockedBalanceBefore - amountToRelease, "Locked balance not properly updated");
    }

    function test_releaseTokens_reverts_if_notAllowedReleaser(address nonAllowedReleaser, uint256 amountToRelease)
        public
        virtual
    {
        vm.assume(nonAllowedReleaser != chainGateway);
        vm.expectRevert(Errors.NotAuthorized.selector);
        vm.prank(nonAllowedReleaser);
        iouTokenManager.releaseTokens(msg.sender, amountToRelease);
    }

    function test_releaseTokens_reverts_if_insufficientLockedBalance(uint256 lockedBalance, uint256 amountToRelease)
        public
        virtual
    {
        vm.assume(lockedBalance < type(uint256).max);
        amountToRelease = bound(amountToRelease, lockedBalance + 1, type(uint256).max);
        vm.prank(iouTokenManagerAddress);
        MockErc20(iouToken).mint(address(iouTokenManager), lockedBalance);
        iouTokenManager.mockLockedBalance(lockedBalance);
        vm.expectRevert(IIouTokenManager.InsufficientLockedBalance.selector);
        vm.prank(chainGateway);
        iouTokenManager.releaseTokens(msg.sender, amountToRelease);
    }

    // Bridging tokens
    function test_bridgeTokens_withoutBridgeParams(
        address from,
        uint256 destinationChainId,
        address iouTokenRecipient,
        uint256 iouTokenAmountRay
    ) public {
        vm.assume(destinationChainId != block.chainid);
        vm.assume(from != address(0));
        vm.assume(iouTokenRecipient != address(0));
        vm.assume(iouTokenAmountRay > 0);

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: from, feeToken: address(0), feeAmount: 0, feeRefundThreshold: 0, gasLimit: 0, data: ""
        });
        vm.prank(iouTokenManagerAddress);
        MockErc20(iouToken).mint(from, iouTokenAmountRay);
        vm.prank(from);
        IERC20(iouToken).approve(address(iouTokenManager), iouTokenAmountRay);
        address adapter = makeAddr("adapter");
        vm.expectCall(
            chainGateway,
            abi.encodeWithSelector(
                IChainGateway.sendBridgeIouTokenMessageWithFeePayer.selector,
                destinationChainId,
                iouTokenRecipient,
                iouTokenAmountRay,
                adapter,
                bridgeParams
            )
        );
        vm.prank(from);
        iouTokenManager.bridgeTokens(destinationChainId, iouTokenRecipient, iouTokenAmountRay, adapter, bridgeParams);
    }

    function test_bridgeTokens_emitsTokensLocked_onAccountingChain() public virtual {
        address from = makeAddr("lockUser");
        uint256 destinationChainId = block.chainid + 1;
        address iouTokenRecipient = makeAddr("iouRecipient");
        uint256 iouTokenAmountRay = 1_000_000e27;

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: from, feeToken: address(0), feeAmount: 0, feeRefundThreshold: 0, gasLimit: 0, data: ""
        });

        // Mint IOU tokens to the user and approve the manager
        vm.prank(iouTokenManagerAddress);
        MockErc20(iouToken).mint(from, iouTokenAmountRay);
        vm.prank(from);
        IERC20(iouToken).approve(address(iouTokenManager), iouTokenAmountRay);

        // TokensLocked has 1 indexed param: from
        vm.expectEmit(true, false, false, true);
        emit IIouTokenManager.TokensLocked(from, iouTokenAmountRay);

        vm.prank(from);
        iouTokenManager.bridgeTokens(destinationChainId, iouTokenRecipient, iouTokenAmountRay, bridgeParams);
    }

    function test_bridgeTokens_reverts_if_invalidDestinationChainId(
        address from,
        address iouTokenRecipient,
        uint256 iouTokenAmountRay
    ) public {
        vm.assume(iouTokenRecipient != address(0));
        vm.assume(iouTokenAmountRay > 0);
        uint256 destinationChainId = block.chainid;
        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: address(0), feeToken: address(0), feeAmount: 0, feeRefundThreshold: 0, gasLimit: 0, data: ""
        });
        vm.expectRevert(Errors.InvalidDestinationChainId.selector);
        vm.prank(from);
        iouTokenManager.bridgeTokens(
            destinationChainId, iouTokenRecipient, iouTokenAmountRay, makeAddr("adapter"), bridgeParams
        );
    }

    function test_bridgeTokens_bridgeParams_ClientTransfersNonNativeFeeToken(
        address from,
        uint256 destinationChainId,
        address iouTokenRecipient,
        uint256 iouTokenAmountRay,
        uint256 feeAmount,
        uint256 gasLimit,
        bytes memory data
    ) public {
        vm.assume(from != address(0));
        vm.assume(iouTokenRecipient != address(0));
        vm.assume(destinationChainId != block.chainid);
        vm.assume(iouTokenAmountRay > 0);
        address feeToken = address(new MockErc20("Test USD", "TUSD", 6));
        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: from,
            feeToken: feeToken,
            feeAmount: feeAmount,
            feeRefundThreshold: 0,
            gasLimit: gasLimit,
            data: data
        });
        if (feeAmount > 0) {
            MockErc20(feeToken).mint(from, feeAmount);
            vm.prank(from);
            IERC20(feeToken).approve(address(iouTokenManager), feeAmount);
        }
        if (iouTokenAmountRay > 0) {
            vm.prank(iouTokenManagerAddress);
            MockErc20(iouToken).mint(from, iouTokenAmountRay);
            vm.prank(from);
            IERC20(iouToken).approve(address(iouTokenManager), iouTokenAmountRay);
        }
        address feeRecipient = makeAddr("bridgeAdapter");
        if (feeAmount > 0) {
            MockGateway(chainGateway).mockConsumeOnNextCall(transferHelper, feeAmount, feeToken, feeRecipient);
            vm.expectCall(
                bridgeParams.feeToken,
                abi.encodeWithSelector(IERC20.transferFrom.selector, from, transferHelper, feeAmount)
            );
        }
        vm.prank(from);
        iouTokenManager.bridgeTokens(
            destinationChainId, iouTokenRecipient, iouTokenAmountRay, makeAddr("adapter"), bridgeParams
        );
        assertEq(
            IERC20(feeToken).balanceOf(address(transferHelper)),
            0,
            "Token fee not properly transferred out of TransferHelper"
        );
        assertEq(
            IERC20(feeToken).balanceOf(feeRecipient), feeAmount, "Token fee not properly transferred to bridge adapter"
        );
    }

    function test_bridgeTokens_nonNativeFeeToken_msgValueDoesNotLeaveStealableNativeOnTransferHelper(
        uint256 iouTokenAmountRay,
        uint256 feeAmount,
        uint256 accidentalMsgValue
    ) public {
        address from = makeAddr("from");
        address attacker = makeAddr("attacker");
        uint256 destinationChainId = block.chainid + 1;
        address iouTokenRecipient = makeAddr("iouTokenRecipient");
        address feeToken = address(new MockErc20("Test USD", "TUSD", 6));

        iouTokenAmountRay = bound(iouTokenAmountRay, 1, 1e36);
        feeAmount = bound(feeAmount, 1, 1e18);
        accidentalMsgValue = bound(accidentalMsgValue, 1, 100 ether);

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: from, feeToken: feeToken, feeAmount: feeAmount, feeRefundThreshold: 0, gasLimit: 0, data: ""
        });

        MockErc20(feeToken).mint(from, feeAmount);
        vm.prank(from);
        IERC20(feeToken).approve(address(iouTokenManager), feeAmount);

        vm.prank(iouTokenManagerAddress);
        MockErc20(iouToken).mint(from, iouTokenAmountRay);
        vm.prank(from);
        IERC20(iouToken).approve(address(iouTokenManager), iouTokenAmountRay);

        address feeRecipient = makeAddr("bridgeAdapter");
        MockGateway(chainGateway).mockConsumeOnNextCall(transferHelper, feeAmount, feeToken, feeRecipient);

        vm.deal(from, accidentalMsgValue);
        vm.prank(from);
        vm.expectRevert(Errors.InvalidParameter.selector);
        iouTokenManager.bridgeTokens{value: accidentalMsgValue}(
            destinationChainId, iouTokenRecipient, iouTokenAmountRay, bridgeParams
        );

        assertEq(from.balance, accidentalMsgValue, "Caller's native balance should be fully preserved after revert");
        assertEq(address(transferHelper).balance, 0, "No native should have leaked to TransferHelper");
        assertEq(IERC20(iouToken).balanceOf(from), iouTokenAmountRay, "IOU tokens should not have been consumed");
        assertEq(IERC20(feeToken).balanceOf(from), feeAmount, "Fee tokens should not have been consumed");

        vm.prank(attacker);
        MockTransferHelper(payable(transferHelper)).pull(address(0), 0);
        assertEq(attacker.balance, 0, "Attacker should not be able to steal native from TransferHelper");
    }

    function test_bridgeTokens_bridgeParams_ClientTransfersNativeFeeToken(
        address from,
        uint256 destinationChainId,
        address iouTokenRecipient,
        uint256 iouTokenAmountRay,
        uint256 feeAmount,
        uint256 gasLimit,
        bytes memory data
    ) public {
        vm.assume(destinationChainId != block.chainid);
        vm.assume(from != address(chainGateway));
        vm.assume(from != address(0));
        vm.assume(iouTokenRecipient != address(0));
        vm.assume(iouTokenAmountRay > 0);
        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: from,
            feeToken: address(0),
            feeAmount: feeAmount,
            feeRefundThreshold: 0,
            gasLimit: gasLimit,
            data: data
        });
        address feeRecipient = makeAddr("bridgeAdapter");
        if (feeAmount > 0) {
            vm.deal(from, feeAmount);
            MockGateway(chainGateway).mockConsumeOnNextCall(transferHelper, feeAmount, address(0), feeRecipient);
        }
        if (iouTokenAmountRay > 0) {
            vm.prank(iouTokenManagerAddress);
            MockErc20(iouToken).mint(from, iouTokenAmountRay);
            vm.prank(from);
            IERC20(iouToken).approve(address(iouTokenManager), iouTokenAmountRay);
        }
        vm.prank(from);
        iouTokenManager.bridgeTokens{value: feeAmount}(
            destinationChainId, iouTokenRecipient, iouTokenAmountRay, makeAddr("adapter"), bridgeParams
        );
        assertEq(transferHelper.balance, 0, "Native fee not properly transferred out of TransferHelper");
        assertEq(feeRecipient.balance, feeAmount, "Native fee not properly transferred to bridge adapter");
    }

    function test_bridgeTokens_reverts_if_invalidBridgeFeePayer(
        address from,
        address feePayer,
        uint256 destinationChainId,
        address iouTokenRecipient,
        uint256 iouTokenAmountRay
    ) public {
        vm.assume(destinationChainId != block.chainid);
        vm.assume(iouTokenRecipient != address(0));
        vm.assume(feePayer != from);
        vm.assume(from != address(0));
        vm.assume(iouTokenAmountRay > 0);
        uint256 feeAmount = 1000;
        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: feePayer, feeToken: address(0), feeAmount: feeAmount, feeRefundThreshold: 0, gasLimit: 0, data: ""
        });
        vm.deal(feePayer, feeAmount);

        vm.prank(iouTokenManagerAddress);
        MockErc20(iouToken).mint(from, iouTokenAmountRay);
        vm.prank(from);
        IERC20(iouToken).approve(address(iouTokenManager), iouTokenAmountRay);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidBridgeFeePayer.selector));
        vm.prank(from);
        iouTokenManager.bridgeTokens(
            destinationChainId, iouTokenRecipient, iouTokenAmountRay, makeAddr("adapter"), bridgeParams
        );
    }

    function test_bridgeTokens_reverts_if_invalidIouTokenRecipient() public {
        address from = makeAddr("randomAccount");
        uint256 iouTokenAmountRay = 100_000;
        uint256 destinationChainId = block.chainid + 1;
        address iouTokenRecipient = address(0);
        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: from, feeToken: address(0), feeAmount: 0, feeRefundThreshold: 0, gasLimit: 0, data: ""
        });
        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(from);
        iouTokenManager.bridgeTokens(
            destinationChainId, iouTokenRecipient, iouTokenAmountRay, makeAddr("adapter"), bridgeParams
        );
    }

    function test_bridgeTokens_reverts_if_zeroAmount(address from, uint256 destinationChainId) public {
        vm.assume(from != address(0));
        vm.assume(destinationChainId != block.chainid);
        address iouTokenRecipient = makeAddr("iouTokenRecipient");
        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: from, feeToken: address(0), feeAmount: 0, feeRefundThreshold: 0, gasLimit: 0, data: ""
        });
        vm.expectRevert(Errors.ZeroAmount.selector);
        vm.prank(from);
        iouTokenManager.bridgeTokens(destinationChainId, iouTokenRecipient, 0, makeAddr("adapter"), bridgeParams);
    }

    // Getters

    function test_getLockedBalance(uint256 lockedBalance) public {
        iouTokenManager.mockLockedBalance(lockedBalance);
        assertEq(lockedBalance, iouTokenManager.getLockedBalance(), "Locked balance not properly returned");
    }

    function test_getAsset() public view {
        assertEq(iouToken, iouTokenManager.getAsset(), "Asset not properly returned");
    }
}

contract IouTokenManagerTest_EarningChain is IouTokenManagerTest_AccountingChain {
    function setUp() public override {
        super.setUp();

        uint256 deployerNonce = vm.getNonce(address(this));

        iouTokenManagerAddress = vm.computeCreateAddress(address(this), deployerNonce);
        iouTokenAddress = vm.computeCreateAddress(address(this), deployerNonce + 1);

        iouTokenManager = new ExtendedIouTokenManager(iouTokenAddress, chainGateway, vault, transferHelper, false);
        iouToken = address(new IouToken(iouTokenManagerAddress, "IOU: Aave USD Stable Vault", "IOU-USD"));

        assertEq(iouTokenManagerAddress, address(iouTokenManager));
        assertEq(iouTokenAddress, iouToken);
    }

    // Skip TokensLocked test on non-Accounting chain (earning chain burns instead of locking).
    function test_bridgeTokens_emitsTokensLocked_onAccountingChain() public override {}

    // Skip Release Tokens tests on non-Accounting chain.
    function test_releaseTokens_withGateway(uint256 lockedBalance, uint256 amountToRelease) public override {}

    // Skip Burn Locked Tokens tests on non-Accounting chain.
    function test_burnLockedTokens_withGateway(uint256 lockedBalance, uint256 amountToBurn) public override {}
    function test_burnLockedTokens_withVault(uint256 lockedBalance, uint256 amountToBurn) public override {}
    function test_burnLockedTokens_reverts_if_notAllowedBurner(address nonAllowedBurner, uint256 amountToBurn)
        public
        override
    {}
    function test_burnLockedTokens_reverts_if_insufficientLockedBalance_withGateway(
        uint256 lockedBalance,
        uint256 amountToBurn
    ) public override {}
    function test_burnLockedTokens_reverts_if_insufficientLockedBalance_withVault(
        uint256 lockedBalance,
        uint256 amountToBurn
    ) public override {}

    function test_releaseTokens_reverts_if_notAllowedReleaser(address nonAllowedReleaser, uint256 amountToRelease)
        public
        override
    {}

    function test_releaseTokens_reverts_if_insufficientLockedBalance(uint256 lockedBalance, uint256 amountToRelease)
        public
        override
    {}

    function test_releaseTokens_reverts_earningChain(uint256 amountToRelease) public {
        vm.expectRevert(IIouTokenManager.OnlyAccountingChain.selector);
        vm.prank(chainGateway);
        iouTokenManager.releaseTokens(msg.sender, amountToRelease);
    }

    function test_burnLockedTokens_reverts_earningChain(uint256 amountToBurn) public {
        vm.expectRevert(IIouTokenManager.OnlyAccountingChain.selector);
        vm.prank(chainGateway);
        iouTokenManager.burnLockedTokens(amountToBurn);
    }
}

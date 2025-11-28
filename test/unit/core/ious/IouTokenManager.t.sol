// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Test} from "forge-std/Test.sol";

import {IouToken} from "src/core/ious/IouToken.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {IIouTokenManager} from "src/interfaces/IIouTokenManager.sol";
import {ErrorsLib} from "src/libraries/ErrorsLib.sol";

import {ExtendedIouTokenManager} from "test/mocks/ExtendedIouTokenManager.sol";
import {MockErc20} from "test/mocks/MockErc20.sol";
import {MockGateway} from "test/mocks/MockGateway.sol";
import {MockTransferHelper} from "test/mocks/MockTransferHelper.sol";

contract IouTokenManagerTest_AccountingChain is Test {
    ExtendedIouTokenManager public iouTokenManager;
    address public iouToken;
    address payable public chainGateway;
    address public vault = makeAddr("VAULT");
    address public transferHelper;
    address iouTokenManagerAddress;
    address iouTokenAddress;

    function setUp() public virtual {
        chainGateway = payable(new MockGateway());
        transferHelper = address(new MockTransferHelper());

        uint256 deployerNonce = vm.getNonce(address(this));

        iouTokenManagerAddress = vm.computeCreateAddress(address(this), deployerNonce);
        iouTokenAddress = vm.computeCreateAddress(address(this), deployerNonce + 1);

        iouTokenManager = new ExtendedIouTokenManager(iouTokenAddress, chainGateway, vault, transferHelper, true);
        iouToken = address(new IouToken(iouTokenManagerAddress));

        assertEq(iouTokenManagerAddress, address(iouTokenManager));
        assertEq(iouTokenAddress, iouToken);
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
        vm.expectRevert(ErrorsLib.NotAuthorized.selector);
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
        vm.expectRevert(ErrorsLib.NotAuthorized.selector);
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
        vm.expectRevert(ErrorsLib.NotAuthorized.selector);
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
        vm.expectRevert(ErrorsLib.NotAuthorized.selector);
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

        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: address(0), feeToken: address(0), feeAmount: 0, feeRefundThreshold: 0, gasLimit: 0, data: ""
        });
        vm.prank(iouTokenManagerAddress);
        MockErc20(iouToken).mint(from, iouTokenAmountRay);
        vm.prank(from);
        IERC20(iouToken).approve(address(iouTokenManager), iouTokenAmountRay);
        vm.expectCall(
            chainGateway,
            abi.encodeWithSelector(
                IChainGateway.sendBridgeIouTokenMessageWithFeePayer.selector,
                destinationChainId,
                iouTokenRecipient,
                iouTokenAmountRay,
                bridgeParams
            )
        );
        vm.prank(from);
        iouTokenManager.bridgeTokens(destinationChainId, iouTokenRecipient, iouTokenAmountRay, bridgeParams);
    }

    function test_bridgeTokens_reverts_if_invalidDestinationChainId(
        address from,
        address iouTokenRecipient,
        uint256 iouTokenAmountRay
    ) public {
        uint256 destinationChainId = block.chainid;
        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: address(0), feeToken: address(0), feeAmount: 0, feeRefundThreshold: 0, gasLimit: 0, data: ""
        });
        vm.expectRevert(ErrorsLib.InvalidDestinationChainId.selector);
        vm.prank(from);
        iouTokenManager.bridgeTokens(destinationChainId, iouTokenRecipient, iouTokenAmountRay, bridgeParams);
    }

    function test_bridgeTokens_bridgeParams_ClientTransfersNonNativeFeeToken(
        address from,
        uint256 destinationChainId,
        address feePayer,
        address iouTokenRecipient,
        uint256 iouTokenAmountRay,
        uint256 feeAmount,
        uint256 gasLimit,
        bytes memory data
    ) public {
        vm.assume(from != address(0));
        vm.assume(destinationChainId != block.chainid);
        address feeToken = address(new MockErc20("Test USD", "TUSD", 6));
        vm.assume(feePayer != address(0));
        vm.assume(feePayer != address(iouTokenManager));
        vm.assume(feePayer != transferHelper);
        vm.assume(feePayer != address(chainGateway));
        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: feePayer,
            feeToken: feeToken,
            feeAmount: feeAmount,
            feeRefundThreshold: 0,
            gasLimit: gasLimit,
            data: data
        });
        if (feeAmount > 0) {
            MockErc20(feeToken).mint(feePayer, feeAmount);
            vm.prank(feePayer);
            IERC20(feeToken).approve(address(iouTokenManager), feeAmount);
        }
        if (iouTokenAmountRay > 0) {
            vm.prank(iouTokenManagerAddress);
            MockErc20(iouToken).mint(from, iouTokenAmountRay);
            vm.prank(from);
            IERC20(iouToken).approve(address(iouTokenManager), iouTokenAmountRay);
        }
        if (feeAmount > 0) {
            MockGateway(chainGateway).mockConsumeOnNextCall(transferHelper, feeAmount, feeToken);
            vm.expectCall(
                bridgeParams.feeToken,
                abi.encodeWithSelector(IERC20.transferFrom.selector, feePayer, transferHelper, feeAmount)
            );
        }
        vm.prank(from);
        iouTokenManager.bridgeTokens(destinationChainId, iouTokenRecipient, iouTokenAmountRay, bridgeParams);
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
        IBridgeAdapter.BridgeParams memory bridgeParams = IBridgeAdapter.BridgeParams({
            feePayer: address(0),
            feeToken: address(0),
            feeAmount: feeAmount,
            feeRefundThreshold: 0,
            gasLimit: gasLimit,
            data: data
        });
        if (feeAmount > 0) {
            vm.deal(from, feeAmount);
            MockGateway(chainGateway).mockConsumeOnNextCall(transferHelper, feeAmount, address(0));
        }
        if (iouTokenAmountRay > 0) {
            vm.prank(iouTokenManagerAddress);
            MockErc20(iouToken).mint(from, iouTokenAmountRay);
            vm.prank(from);
            IERC20(iouToken).approve(address(iouTokenManager), iouTokenAmountRay);
        }
        uint256 balanceBefore = address(chainGateway).balance;
        vm.prank(from);
        iouTokenManager.bridgeTokens{value: feeAmount}(
            destinationChainId, iouTokenRecipient, iouTokenAmountRay, bridgeParams
        );
        uint256 balanceAfter = address(chainGateway).balance;
        assertEq(balanceAfter, balanceBefore + feeAmount, "Native fee not properly transferred to Gateway");
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
        iouToken = address(new IouToken(iouTokenManagerAddress));

        assertEq(iouTokenManagerAddress, address(iouTokenManager));
        assertEq(iouTokenAddress, iouToken);
    }

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

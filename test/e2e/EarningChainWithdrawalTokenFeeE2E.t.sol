// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {BasedBoostedVault} from "../../src/accounting/BasedBoostedVault.sol";
import {BasedBoostedVault} from "../../src/accounting/BasedBoostedVault.sol";
import {IouTokenManager} from "../../src/common/IouTokenManager.sol";
import {EarningChainGateway} from "../../src/earning/EarningChainGateway.sol";
import {IBasedBoostedVault} from "../../src/interfaces/IBasedBoostedVault.sol";
import {IBridgeAdapter} from "../../src/interfaces/IBridgeAdapter.sol";
import {AssetLib} from "../../src/libraries/AssetLib.sol";
import {ErrorsLib} from "../../src/libraries/ErrorsLib.sol";
import {BaseTest} from "../BaseTest.t.sol";
import {MockErc20} from "../mocks/MockErc20.sol";

/// @title EarningChainWithdrawalTokenFeeE2ETest
/// @notice Test the withdrawal of funds from the Earning Chain to the Accounting Chain.
/// @dev Deposit made to BBV on Accounting Chain, IOU tokens bridged to Earning Chain, and then used to withdraw assets.
contract EarningChainWithdrawalTokenFeeE2ETest is BaseTest {
    using AssetLib for uint256;

    address user1 = makeAddr("USER1");
    address user2 = makeAddr("USER2");

    MockErc20 bridgeFeeToken = USDC;
    uint256 bridgeFeeAmount = 1000;

    function setUp() public override {
        super.setUp();
    }

    function _deployBasedBoostedVault(
        address adminParam,
        uint256,
        /* maxPerSecondRate */
        uint256 defaultSubVaultPerSecondRate,
        address iouToken,
        address fundsHandler,
        address assetRegistry,
        address transferHelper,
        address withdrawalFeeCalculator
    ) internal virtual override returns (BasedBoostedVault) {
        // Deploy a vault without restriction in the valid per-second rate
        address vaultImpl = address(
            new BasedBoostedVault(type(uint256).max, iouToken, fundsHandler, transferHelper, withdrawalFeeCalculator)
        );
        return BasedBoostedVault(
            address(
                new TransparentUpgradeableProxy(
                    address(vaultImpl),
                    proxyAdmin,
                    abi.encodeCall(
                        BasedBoostedVault.initialize, (adminParam, defaultSubVaultPerSecondRate, assetRegistry)
                    )
                )
            )
        );
    }

    function test_earningChainWithdrawalTokenFeeE2E() public {
        console.log("\nEarningChainWithdrawalTokenFeeE2ETest");

        uint256 userInitialDeposit = 500 * (10 ** 6);

        // 0. Set the default rate on BBV to 5% APY
        vm.prank(everyRoleAccount);
        vault.setDefaultSubVault(1_000000001547125957863212449);

        // 1. User1 deposits 500 USDC to Vault on Accounting Chain
        _mintAndDepositUsdcToBBV(user1, userInitialDeposit);

        // Check the deposit was made into the default earning strategy for USDC
        address defaultUsdcVault_AccountingChain = allocator_accountingChain.getDefaultStrategy(address(USDC));
        assertEq(
            IERC20(address(USDC)).balanceOf(defaultUsdcVault_AccountingChain),
            userInitialDeposit,
            "Default USDC strategy vault should have the deposited amount of USDC"
        );
        assertEq(
            fundsHandler.getAggregatedBalance(),
            userInitialDeposit.assetDecimalsToRay(address(USDC)),
            "Funds handler should have the deposited amount of USDC"
        );

        // 2. Bridge the assets to the Earning Chain
        _mintAndApproveBridgeFeeToken(everyRoleAccount, address(fundsHandler));
        vm.prank(everyRoleAccount);
        fundsHandler.pushFundsToChain(
            address(bridgeFeeToken),
            userInitialDeposit,
            EARNING_CHAIN_ID,
            IBridgeAdapter.BridgeParams({
                feePayer: everyRoleAccount,
                feeToken: address(bridgeFeeToken),
                feeAmount: bridgeFeeAmount,
                feeRefundThreshold: 0,
                gasLimit: 300000,
                data: ""
            })
        );

        // Check the funds were bridged to the Earning Chain
        address defaultUsdcVault_earningChain = allocator_earningChain.getDefaultStrategy(address(USDC));
        assertEq(
            IERC20(address(USDC)).balanceOf(defaultUsdcVault_earningChain),
            userInitialDeposit,
            "Default USDC strategy vault on Earning Chain should have the deposited amount of USDC"
        );

        // 3. Mimic time passing so that user1's balances increase.
        vm.warp(183 days);
        console.log("\nHalf a year has gone by so fast...");

        // Check the user's balance in the BBV on the Accounting Chain
        assertGt(
            vault.getUserBalance(user1),
            userInitialDeposit.assetDecimalsToRay(address(USDC)),
            "User should have the deposited amount of USDC"
        );
        uint256 userBalanceAfterHalfYearInRay = vault.getUserBalance(user1);

        // 4. Check that user1's withdrawal request fails because the system is not able to cover the withdrawal
        // request.
        vm.expectRevert(
            abi.encodeWithSelector(
                IBasedBoostedVault.InsufficientAssets.selector,
                user1,
                userBalanceAfterHalfYearInRay,
                userInitialDeposit.assetDecimalsToRay(address(USDC))
            )
        );
        vm.prank(user1);
        vault.requestWithdrawal(user1, userBalanceAfterHalfYearInRay);

        // 5. User requests to withdrawal their original deposit
        uint256 iouAmountRequestedRay = userInitialDeposit.assetDecimalsToRay(address(USDC));
        vm.prank(user1);
        console.log("!!! Actual requesting withdrawal for user1", user1);
        vault.requestWithdrawal(user1, iouAmountRequestedRay);
        // Check the IOU token balance went up (units are in RAY)
        assertEq(
            iouToken_accountingChain.balanceOf(user1),
            userInitialDeposit.assetDecimalsToRay(address(USDC)),
            "User should have minted IOU tokens"
        );

        // 6. Bridge user1 IOUs to Earning chain and check supplies are expected
        // The user will use native asset to pay for bridge fees
        // User must approve the IOU token manager to spend the IOU tokens
        _mintAndApproveBridgeFeeToken(user1, address(iouTokenManager_accountingChain));
        _runIouTokenBridge(iouTokenManager_accountingChain, user1, iouAmountRequestedRay, EARNING_CHAIN_ID);
        // Check the IOU token balance on Accounting Chain went down
        assertEq(iouToken_accountingChain.balanceOf(user1), 0, "User should have bridged IOU tokens");
        // Check that supply on Accounting Chain stayed the same
        assertEq(
            iouToken_accountingChain.totalSupply(),
            iouAmountRequestedRay,
            "Supply on Accounting Chain should stay the same"
        );
        // Check the IOU token balance on Earning Chain went up
        assertEq(
            iouToken_earningChain.balanceOf(user1), iouAmountRequestedRay, "Should have minted IOU tokens for user1"
        );
        // Check that supply on Earning Chain went up
        assertEq(iouToken_earningChain.totalSupply(), iouAmountRequestedRay, "Supply on Earning Chain should go up");

        // Check that requesting another withdrawal fails because the user was alredy given IOUs.
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InvalidAmount.selector));
        vm.prank(user1);
        vault.requestWithdrawal(user1, iouAmountRequestedRay);

        // 7. A second depositor deposits and tries to withdraw (check the iousInCirculationRay math)
        _mintAndDepositUsdcToBBV(user2, userInitialDeposit);
        // Set the rate to be 99%
        vm.prank(everyRoleAccount);
        vault.setSubVaultRate(2, 1_000000021820606489223699321);
        // Mimic time passing so that user2's balances increase.
        vm.warp(block.timestamp + 365 days);
        console.log("User2 balance after 1 years", vault.getUserBalance(user2));
        // User1's IOUs should be considered when calc'ing withdrawal ability (use1's IOUs sitting on Earning chain
        // should be considered).
        uint256 user2BalanceAfterOneYearInRay = vault.getUserBalance(user2);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBasedBoostedVault.InsufficientAssets.selector,
                user2,
                user2BalanceAfterOneYearInRay,
                userInitialDeposit.assetDecimalsToRay(address(USDC))
            )
        );
        vm.prank(user2);
        vault.requestWithdrawal(user2, user2BalanceAfterOneYearInRay);

        // User2 should be able to withdraw their original deposit
        vm.prank(user2);
        vault.requestWithdrawal(user2, iouAmountRequestedRay);
        // Check the IOU token balance on Accounting Chain went up
        assertEq(
            iouToken_accountingChain.balanceOf(user2),
            userInitialDeposit.assetDecimalsToRay(address(USDC)),
            "User should have minted IOU tokens"
        );

        // IOU supply on Accounting chain should now be initial deposit * 2
        assertEq(
            iouToken_accountingChain.totalSupply(),
            userInitialDeposit.assetDecimalsToRay(address(USDC)) * 2,
            "Supply on Accounting Chain should be initial deposit * 2"
        );

        // 8. Check that a user bridging IOUs to/from Earning chain updates the supply on both chains properly.
        uint256 iousOnAccountBeforeUser2BridgeToEarningChain = iouToken_accountingChain.totalSupply();
        console.log(
            "IOUS ON ACCOUNTING CHAIN (BEFORE USER2 BRIDGE TO EARNING CHAIN) =",
            iousOnAccountBeforeUser2BridgeToEarningChain
        );
        uint256 iousOnEarningBeforeUser2BridgeToAccountingChain = iouToken_earningChain.totalSupply();
        console.log(
            "IOUS ON EARNING CHAIN (BEFORE USER2 BRIDGE TO ACCOUNTING CHAIN) =",
            iousOnEarningBeforeUser2BridgeToAccountingChain
        );
        _mintAndApproveBridgeFeeToken(user2, address(iouTokenManager_accountingChain));
        _runIouTokenBridge(iouTokenManager_accountingChain, user2, iouAmountRequestedRay, EARNING_CHAIN_ID);
        require(
            iouToken_accountingChain.totalSupply() == iousOnAccountBeforeUser2BridgeToEarningChain,
            "Supply on Accounting Chain should NOT have decreased by the amount of IOUs bridged"
        );
        require(
            iouToken_earningChain.totalSupply()
                == iousOnEarningBeforeUser2BridgeToAccountingChain + iouAmountRequestedRay,
            "Supply on Earning Chain should increase by the amount of IOUs bridged"
        );

        // Bridge the tokens back to Accounting chain and check the supply on both chains is expected
        _mintAndApproveBridgeFeeToken(user2, address(iouTokenManager_earningChain));
        _runIouTokenBridge(iouTokenManager_earningChain, user2, iouAmountRequestedRay, ACCOUNTING_CHAIN_ID);
        require(
            iouToken_accountingChain.totalSupply() == iousOnAccountBeforeUser2BridgeToEarningChain,
            "Supply on Accounting Chain should increase by the amount of IOUs bridged"
        );
        require(
            iouToken_earningChain.totalSupply() == iousOnEarningBeforeUser2BridgeToAccountingChain,
            "Supply on Earning Chain should decrease by the amount of IOUs bridged"
        );

        // 9. User1 exchanges IOUs for assets on Earning chain and checks their balance is expected
        {
            uint256 assetsOnEarningBeforeUser1ExchangeIous = earningChainGateway.getAggregatedBalance();
            // Tokens should be burned from iouTokenManager_accountingChain
            uint256 iouSupplyOnAccountingChainBeforeIouExchange = iouToken_accountingChain.totalSupply();
            uint256 iouLockedBalanceOnAccountingChainBeforeIouExchange =
                iouTokenManager_accountingChain.getLockedBalance();
            // Tokens on Earning chain should be burned
            uint256 iouSupplyOnEarningChainBeforeIouExchange = iouToken_earningChain.totalSupply();

            uint256 user1IouBalanceOnEarningChainBeforeIouExchange = iouToken_earningChain.balanceOf(user1);
            uint256 amountIouToExchange = 225 * (10 ** 27);
            assertGt(
                iouToken_earningChain.balanceOf(user1), amountIouToExchange, "User should have enough IOUs to exchange"
            );
            {
                _runExchangeIouTokens(earningChainGateway, user1, amountIouToExchange);
            }

            // Check user1 IOU balance on Earning chain went down
            assertEq(
                iouToken_earningChain.balanceOf(user1),
                user1IouBalanceOnEarningChainBeforeIouExchange - amountIouToExchange,
                "User should have less IOUs after exchanging"
            );
            // Check IOU supply on Earning chain went down
            assertEq(
                iouToken_earningChain.totalSupply(),
                iouSupplyOnEarningChainBeforeIouExchange - amountIouToExchange,
                "Supply on Earning Chain should decrease by the amount of IOUs exchanged"
            );
            // Check IOU supply on Accounting chain went down
            assertEq(
                iouToken_accountingChain.totalSupply(),
                iouSupplyOnAccountingChainBeforeIouExchange - amountIouToExchange,
                "Supply on Accounting Chain should decrease by the amount of IOUs exchanged"
            );
            assertEq(
                iouTokenManager_accountingChain.getLockedBalance(),
                iouLockedBalanceOnAccountingChainBeforeIouExchange - amountIouToExchange,
                "Locked balance on Accounting Chain should decrease by the amount of IOUs exchanged"
            );
            // Check the assets in the Earning chain went down
            assertEq(
                earningChainGateway.getAggregatedBalance(),
                assetsOnEarningBeforeUser1ExchangeIous - amountIouToExchange,
                "Assets on Earning Chain should decrease by the amount of IOUs exchanged"
            );
            // Check the assets in the Accounting chain are now the 500 deposit from user2 + the snapshot update after
            // User1's withdrawal on Earning chain of 225 (500 + 500 - 225)
            assertEq(
                fundsHandler.getAggregatedBalance(),
                775000000000000000000000000000,
                "Assets on Accounting Chain should increase by the amount of IOUs exchanged"
            );
        }
    }

    function _mintAndDepositUsdcToBBV(address user, uint256 amount) internal {
        USDC.mint(user, amount);
        vm.startPrank(user);
        USDC.approve(address(vault), amount);
        vault.deposit(user, address(USDC), amount);
        vm.stopPrank();
    }

    function _mintAndApproveBridgeFeeToken(address feePayer, address feeSpender) internal {
        bridgeFeeToken.mint(feePayer, bridgeFeeAmount);
        vm.prank(feePayer);
        bridgeFeeToken.approve(feeSpender, bridgeFeeAmount);
    }

    function _runIouTokenBridge(
        IouTokenManager iouTokenManager,
        address user,
        uint256 iouAmountRequestedRay,
        uint256 destinationChainId
    ) internal {
        vm.prank(user);
        iouTokenManager.bridgeTokens(
            destinationChainId,
            user,
            iouAmountRequestedRay,
            IBridgeAdapter.BridgeParams({
                feePayer: user,
                feeToken: address(bridgeFeeToken),
                feeAmount: bridgeFeeAmount,
                feeRefundThreshold: 0,
                gasLimit: 100000,
                data: ""
            })
        );
    }

    function _runExchangeIouTokens(EarningChainGateway earningChainGateway, address user, uint256 iouAmountRequestedRay)
        internal
    {
        _mintAndApproveBridgeFeeToken(user1, address(earningChainGateway));
        vm.prank(user);
        earningChainGateway.exchangeIouTokens(
            iouAmountRequestedRay,
            address(USDC),
            user,
            IBridgeAdapter.BridgeParams({
                feePayer: user,
                feeToken: address(bridgeFeeToken),
                feeAmount: bridgeFeeAmount,
                feeRefundThreshold: 0,
                gasLimit: 100000,
                data: ""
            }),
            ""
        );
    }
}

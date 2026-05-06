// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Logger} from "test/helpers/Logger.sol";

import {BridgeParamsCodec} from "src/bridging/BridgeParamsCodec.sol";
import {StableVault} from "src/core/accounting/StableVault.sol";
import {StableVault} from "src/core/accounting/StableVault.sol";
import {EarningChainGateway} from "src/core/earning/EarningChainGateway.sol";
import {IouTokenManager} from "src/core/ious/IouTokenManager.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {IStableVault} from "src/interfaces/IStableVault.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {Errors} from "src/types/Errors.sol";

import {BaseTest} from "test/BaseTest.t.sol";
import {MockErc20} from "test/mocks/MockErc20.sol";

/// @title EarningChainWithdrawalTokenFeeE2ETest
/// @notice Test the withdrawal of funds from the Earning Chain to the Accounting Chain.
/// @dev Deposit made to Stable Vault on Accounting Chain, IOU tokens bridged to Earning Chain, and then used to
/// withdraw assets.
contract EarningChainWithdrawalTokenFeeE2ETest is BaseTest {
    using AssetLib for uint256;

    address user1 = makeAddr("USER1");
    address user2 = makeAddr("USER2");

    MockErc20 bridgeFeeToken = USDC;
    uint256 bridgeFeeAmount = 1000;

    function setUp() public override {
        super.setUp();
    }

    function _deployStableVault(
        address adminParam,
        uint256,
        /* maxPerSecondRate */
        uint256 defaultSubVaultPerSecondRate,
        address iouToken,
        address fundsHandler,
        address assetRegistry,
        address transferHelper,
        address withdrawalFeeCalculator,
        address priceOracle,
        uint256 maxActiveSubVaults,
        address treasuryAddress
    ) internal virtual override returns (StableVault) {
        // Deploy a vault without restriction in the valid per-second rate
        address vaultImpl = address(
            new StableVault(
                type(uint256).max,
                assetRegistry,
                iouToken,
                fundsHandler,
                transferHelper,
                withdrawalFeeCalculator,
                priceOracle,
                maxActiveSubVaults
            )
        );
        return StableVault(
            address(
                new TransparentUpgradeableProxy(
                    address(vaultImpl),
                    proxyAdmin,
                    abi.encodeCall(
                        StableVault.initialize,
                        (adminParam, treasuryAddress, defaultSubVaultPerSecondRate, "Aave USD Stable Vault", "ASV-USD")
                    )
                )
            )
        );
    }

    function test_earningChainWithdrawalTokenFeeE2E() public {
        Logger.log("\nEarningChainWithdrawalTokenFeeE2ETest");

        uint256 userInitialDeposit = 500 * (10 ** 6);

        // 0. Set the default rate on Stable Vault to 5% APY
        vm.prank(everyRoleAccount);
        vault.setDefaultSubVault(1_000000001547125957863212449);

        // 1. User1 deposits 500 USDC to Vault on Accounting Chain
        _mintAndDepositUsdcToStableVault(user1, userInitialDeposit);

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

        // 2. Bridge the assets to the Earning Chain — approval targets the adapter under the
        // opaque-bytes shape (adapter owns the safeTransferFrom for the fee token).
        _mintAndApproveBridgeFeeToken(everyRoleAccount, address(ccipAdapter_accountingChain));
        vm.prank(everyRoleAccount);
        fundsHandler.pushFundsToChain(
            address(bridgeFeeToken),
            userInitialDeposit,
            EARNING_CHAIN_ID,
            address(ccipAdapter_accountingChain),
            BridgeParamsCodec.encode(
                IBridgeAdapter.BridgeParams({
                    feeToken: address(bridgeFeeToken),
                    feeAmount: bridgeFeeAmount,
                    feeRefundThreshold: 0,
                    gasLimit: 350000,
                    data: ""
                })
            )
        );

        // Check the funds were bridged to the Earning Chain
        address defaultUsdcVault_earningChain = allocator_earningChain.getDefaultStrategy(address(USDC));
        assertEq(
            IERC20(address(USDC)).balanceOf(defaultUsdcVault_earningChain),
            userInitialDeposit,
            "Default USDC strategy vault on Earning Chain should have the deposited amount of USDC"
        );

        // Publish a chain balance snapshot via MockBundleFeed so the adapter/oracle path reflects Earning Chain funds.
        uint256 earningChainBalanceRay = userInitialDeposit.assetDecimalsToRay(address(USDC));
        _mockChainBalance(
            EARNING_CHAIN_ID,
            earningChainBalanceRay,
            block.timestamp,
            block.timestamp - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS,
            false
        );

        // Verify the FundsHandler now sees the earning chain balance via the oracle
        assertEq(
            fundsHandler.getAggregatedBalance(),
            earningChainBalanceRay,
            "FundsHandler should see the earning chain balance via the oracle"
        );

        // 3. Mimic time passing so that user1's balances increase.
        vm.warp(block.timestamp + 183 days);
        Logger.log("\nHalf a year has gone by so fast...");

        // Check the user's balance in the Stable Vault on the Accounting Chain
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
                IStableVault.InsufficientAssets.selector,
                user1,
                userBalanceAfterHalfYearInRay,
                userInitialDeposit.assetDecimalsToRay(address(USDC))
            )
        );
        vm.prank(user1);
        vault.requestWithdrawal(user1, userBalanceAfterHalfYearInRay, "");

        // 5. User requests to withdrawal their original deposit
        uint256 iouAmountRequestedRay = userInitialDeposit.assetDecimalsToRay(address(USDC));
        vm.prank(user1);
        Logger.log("!!! Actual requesting withdrawal for user1", user1);
        vault.requestWithdrawal(user1, iouAmountRequestedRay, "");
        // Check the IOU token balance went up (units are in RAY)
        assertEq(
            iouToken_accountingChain.balanceOf(user1),
            userInitialDeposit.assetDecimalsToRay(address(USDC)),
            "User should have minted IOU tokens"
        );

        // 6. Bridge user1 IOUs to Earning chain and check supplies are expected
        // Approval targets the adapter under the opaque-bytes shape.
        _mintAndApproveBridgeFeeToken(user1, address(ccipAdapter_accountingChain));
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
        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAmount.selector));
        vm.prank(user1);
        vault.requestWithdrawal(user1, iouAmountRequestedRay, "");

        // 7. A second depositor deposits and tries to withdraw (check the iousInCirculationRay math)
        _mintAndDepositUsdcToStableVault(user2, userInitialDeposit);
        // Set the rate to be 99%
        vm.prank(everyRoleAccount);
        vault.setSubVaultRate(2, 1_000000021820606489223699321);
        // Mimic time passing so that user2's balances increase.
        vm.warp(block.timestamp + 365 days);
        Logger.log("User2 balance after 1 years", vault.getUserBalance(user2));
        // User1's IOUs should be considered when calc'ing withdrawal ability (use1's IOUs sitting on Earning chain
        // should be considered).
        uint256 user2BalanceAfterOneYearInRay = vault.getUserBalance(user2);
        vm.expectRevert(
            abi.encodeWithSelector(
                IStableVault.InsufficientAssets.selector,
                user2,
                user2BalanceAfterOneYearInRay,
                userInitialDeposit.assetDecimalsToRay(address(USDC))
            )
        );
        vm.prank(user2);
        vault.requestWithdrawal(user2, user2BalanceAfterOneYearInRay, "");

        // User2 should be able to withdraw their original deposit
        vm.prank(user2);
        vault.requestWithdrawal(user2, iouAmountRequestedRay, "");
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
        Logger.log(
            "IOUS ON ACCOUNTING CHAIN (BEFORE USER2 BRIDGE TO EARNING CHAIN) =",
            iousOnAccountBeforeUser2BridgeToEarningChain
        );
        uint256 iousOnEarningBeforeUser2BridgeToAccountingChain = iouToken_earningChain.totalSupply();
        Logger.log(
            "IOUS ON EARNING CHAIN (BEFORE USER2 BRIDGE TO ACCOUNTING CHAIN) =",
            iousOnEarningBeforeUser2BridgeToAccountingChain
        );
        _mintAndApproveBridgeFeeToken(user2, address(ccipAdapter_accountingChain));
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
        _mintAndApproveBridgeFeeToken(user2, address(ccipAdapter_earningChain));
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
                // Publish a fresh pre-burn snapshot so AccountingChainGateway accepts inbound BURN_IOU_TOKEN
                // (time has warped since the last snapshot).
                _mockChainBalance(
                    EARNING_CHAIN_ID,
                    assetsOnEarningBeforeUser1ExchangeIous,
                    block.timestamp,
                    block.timestamp - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS,
                    false
                );
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

            // Publish the post-burn chain balance snapshot (after the IOU exchange) to the feed.
            // Earning chain balance was 500 USDC worth, now decreased by 225 RAY (amountIouToExchange)
            uint256 remainingEarningChainBalanceRay = assetsOnEarningBeforeUser1ExchangeIous - amountIouToExchange;
            _mockChainBalance(
                EARNING_CHAIN_ID,
                remainingEarningChainBalanceRay,
                block.timestamp,
                block.timestamp - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS,
                false
            );

            // Check the assets in the Accounting chain (cross-chain aggregated balance via oracle)
            // Local balance: User2's 500 USDC deposit = 500 * 10^27 RAY
            // Earning chain balance: (500 - 225) * 10^27 RAY = 275 * 10^27 RAY
            // Total: 775 * 10^27 RAY
            uint256 localBalanceRay = 500000000000000000000000000000; // 500 * 10^27 RAY
            uint256 expectedTotalBalanceRay = localBalanceRay + remainingEarningChainBalanceRay;
            assertEq(
                fundsHandler.getAggregatedBalance(),
                expectedTotalBalanceRay,
                "FundsHandler should see local balance + earning chain balance via oracle"
            );
        }
    }

    function _mintAndDepositUsdcToStableVault(address user, uint256 amount) internal {
        USDC.mint(user, amount);
        vm.startPrank(user);
        USDC.approve(address(vault), amount);
        vault.deposit(user, address(USDC), amount, "");
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
        bool isFromAccountingChain = destinationChainId == EARNING_CHAIN_ID;
        // Determine the right bridge adapter based on which chain is the source
        address bridgeAdapter =
            isFromAccountingChain ? address(ccipAdapter_accountingChain) : address(ccipAdapter_earningChain);
        // User must approve the IouTokenManager to lock/burn their IOUs.
        vm.prank(user);
        IERC20(iouTokenManager.getAsset()).approve(address(iouTokenManager), iouAmountRequestedRay);
        bytes memory bp = BridgeParamsCodec.encode(
            IBridgeAdapter.BridgeParams({
                feeToken: address(bridgeFeeToken),
                feeAmount: bridgeFeeAmount,
                feeRefundThreshold: 0,
                gasLimit: 150000,
                data: ""
            })
        );
        if (isFromAccountingChain) {
            vm.prank(user);
            vault.bridgeIouTokens(destinationChainId, user, iouAmountRequestedRay, bridgeAdapter, bp, "");
        } else {
            vm.prank(user);
            earningChainGateway.bridgeIouTokens(destinationChainId, user, iouAmountRequestedRay, bridgeAdapter, bp, "");
        }
    }

    function _runExchangeIouTokens(EarningChainGateway earningChainGateway, address user, uint256 iouAmountRequestedRay)
        internal
    {
        _mintAndApproveBridgeFeeToken(user1, address(ccipAdapter_earningChain));
        vm.prank(user);
        earningChainGateway.exchangeIouTokens(
            iouAmountRequestedRay,
            address(USDC),
            0,
            user,
            address(ccipAdapter_earningChain),
            BridgeParamsCodec.encode(
                IBridgeAdapter.BridgeParams({
                    feeToken: address(bridgeFeeToken),
                    feeAmount: bridgeFeeAmount,
                    feeRefundThreshold: 0,
                    // Use a higher gas limit to ensure the transaction is successful on Accounting Chain because the
                    // snapshot
                    // struct may be pushed to the FH storage.
                    gasLimit: 350000,
                    data: ""
                })
            ),
            ""
        );
    }
}

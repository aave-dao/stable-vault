// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {console} from "forge-std/console.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {BasedBoostedVault} from "src/core/accounting/BasedBoostedVault.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {IFundsHandler} from "src/interfaces/IFundsHandler.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";

import {BaseTest} from "test/BaseTest.t.sol";

/// @title EarningChainDistrustedAssetE2ETest
/// @notice Test the withdrawal of funds on the Earning Chain when an asset is distrusted.
contract EarningChainDistrustedAssetE2ETest is BaseTest {
    using AssetLib for uint256;

    address user1 = makeAddr("USER1");
    address user2 = makeAddr("USER2");

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
        address withdrawalFeeCalculator,
        uint256 maxActiveSubVaults
    ) internal virtual override returns (BasedBoostedVault) {
        // Deploy a vault without restriction in the valid per-second rate
        address vaultImpl = address(
            new BasedBoostedVault(
                type(uint256).max,
                assetRegistry,
                iouToken,
                fundsHandler,
                transferHelper,
                withdrawalFeeCalculator,
                maxActiveSubVaults
            )
        );
        return BasedBoostedVault(
            address(
                new TransparentUpgradeableProxy(
                    address(vaultImpl),
                    proxyAdmin,
                    abi.encodeCall(BasedBoostedVault.initialize, (adminParam, defaultSubVaultPerSecondRate))
                )
            )
        );
    }

    function test_givenSingleAssetDepegs_userCanStillWithdrawFromEarningChain() public {
        console.log("\nEarningChainDistrustedAssetE2ETest: givenSingleAssetDepegs_userCanStillWithdraw");

        uint256 userInitialDeposit = 500 * (10 ** 6);

        // Set the default rate on BBV to 5% APY
        vm.prank(everyRoleAccount);
        vault.setDefaultSubVault(1_000000001547125957863212449);

        // User1 deposits 500 USDC to Vault on Accounting Chain
        _mintAndDepositUsdcToBBV(user1, userInitialDeposit);

        // Bridge the assets to the Earning Chain
        vm.prank(everyRoleAccount);
        uint256 bridgeFeeAmount = 1000;
        vm.deal(everyRoleAccount, bridgeFeeAmount);
        fundsHandler.pushFundsToChain{value: bridgeFeeAmount}(
            address(USDC),
            userInitialDeposit,
            EARNING_CHAIN_ID,
            IBridgeAdapter.BridgeParams({
                feePayer: everyRoleAccount,
                feeToken: address(0),
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

        // Mimic time passing so that user1's balances increase.
        vm.warp(block.timestamp + 183 days);

        IFundsHandler.AssetBalance[] memory assetBalances = fundsHandler.getAssetBalances();
        assertEq(assetBalances.length, 3);
        bool snapshotBalanceFound = false;
        for (uint256 i = 0; i < assetBalances.length; i++) {
            // Look for address(0) since the snapshot is an aggregate of all assets on the Earning Chain
            if (assetBalances[i].asset == address(0) && assetBalances[i].chainId == EARNING_CHAIN_ID) {
                snapshotBalanceFound = true;
                assertEq(assetBalances[i].amountRay, userInitialDeposit.assetDecimalsToRay(address(USDC)));
                break;
            }
        }
        assertTrue(snapshotBalanceFound, "Snapshot balance from Earning Chain should be found");

        vm.deal(everyRoleAccount, bridgeFeeAmount);
        // Asset depegs so mark it as distrusted on both chains
        vm.startPrank(everyRoleAccount);
        // Distrust the asset on the Accounting Chain
        assetRegistry_accountingChain.distrustAsset(address(USDC));
        // Distrust the asset on the Earning Chain
        assetRegistry_earningChain.distrustAsset(address(USDC));
        // Send snapshot back to the Accounting Chain: this should send a snapshot of 0
        earningChainGateway.sendBalanceUpdateWithFeePayer{value: bridgeFeeAmount}(
            IBridgeAdapter.BridgeParams({
                feePayer: everyRoleAccount,
                feeToken: address(0),
                feeAmount: bridgeFeeAmount,
                feeRefundThreshold: 0,
                gasLimit: 300000,
                data: ""
            })
        );
        vm.stopPrank();

        // Check the Allocator has the USDC bridged over
        assertEq(allocator_earningChain.getAssetBalance(address(USDC)), userInitialDeposit);

        // Check snapshot is now zero'ed out
        IFundsHandler.AssetBalance[] memory assetBalancesAfterSnapshot = fundsHandler.getAssetBalances();
        // Length is 2 out of 3 because the USDC balance is not longer included from Accounting Chain's Allocator
        assertEq(assetBalancesAfterSnapshot.length, 2);
        snapshotBalanceFound = false;
        bool usdcBalanceFound = false;
        for (uint256 i = 0; i < assetBalancesAfterSnapshot.length; i++) {
            if (
                assetBalancesAfterSnapshot[i].asset == address(0)
                    && assetBalancesAfterSnapshot[i].chainId == EARNING_CHAIN_ID
            ) {
                snapshotBalanceFound = true;
                assertEq(assetBalancesAfterSnapshot[i].amountRay, 0);
            }
            if (
                assetBalancesAfterSnapshot[i].asset == address(USDC)
                    && assetBalancesAfterSnapshot[i].chainId == block.chainid
            ) {
                usdcBalanceFound = true;
            }
        }
        assertTrue(
            snapshotBalanceFound,
            "Snapshot balance from Earning Chain should be found after marking asset as distrusted"
        );
        assertFalse(
            usdcBalanceFound, "USDC balance from Accounting Chain should not be found after marking asset as distrusted"
        );

        // User requests withdrawal of their original deposit
        uint256 iouAmountRequestedRay = userInitialDeposit.assetDecimalsToRay(address(USDC));
        vm.prank(user1);
        vault.requestWithdrawal(user1, iouAmountRequestedRay);
        // User should have minted IOU tokens
        assertEq(iouToken_accountingChain.balanceOf(user1), iouAmountRequestedRay);

        // User bridges IOUs to the Earning Chain
        vm.prank(user1);
        vm.deal(user1, bridgeFeeAmount);
        iouTokenManager_accountingChain.bridgeTokens{value: bridgeFeeAmount}(
            EARNING_CHAIN_ID,
            user1,
            iouAmountRequestedRay,
            IBridgeAdapter.BridgeParams({
                feePayer: user1,
                feeToken: address(0),
                feeAmount: bridgeFeeAmount,
                feeRefundThreshold: 0,
                gasLimit: 300000,
                data: ""
            })
        );

        // Check the IOU token balance on Accounting Chain went down
        assertEq(iouToken_accountingChain.balanceOf(user1), 0, "User should have bridged IOU tokens");
        // Check the IOU token balance on Earning Chain went up
        assertEq(
            iouToken_earningChain.balanceOf(user1), iouAmountRequestedRay, "Should have minted IOU tokens for user1"
        );

        // Check the user can withdraw their original deposit from the Earning Chain
        vm.deal(user1, bridgeFeeAmount);
        vm.prank(user1);
        earningChainGateway.exchangeIouTokens{value: bridgeFeeAmount}(
            iouAmountRequestedRay,
            address(USDC),
            0,
            user1,
            IBridgeAdapter.BridgeParams({
                feePayer: user1,
                feeToken: address(0),
                feeAmount: bridgeFeeAmount,
                feeRefundThreshold: 0,
                gasLimit: 300000,
                data: ""
            }),
            ""
        );

        // Check the user has the USDC on the Earning Chain
        assertEq(IERC20(address(USDC)).balanceOf(user1), userInitialDeposit);
        // Check the user has the IOU tokens on the Earning Chain went down
        assertEq(iouToken_earningChain.balanceOf(user1), 0, "User should have less IOUs after withdrawing");
    }

    function _mintAndDepositUsdcToBBV(address user, uint256 amount) internal {
        USDC.mint(user, amount);
        vm.startPrank(user);
        USDC.approve(address(vault), amount);
        vault.deposit(user, address(USDC), amount);
        vm.stopPrank();
    }
}

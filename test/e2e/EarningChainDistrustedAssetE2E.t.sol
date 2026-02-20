// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Logger} from "test/helpers/Logger.sol";

import {StableVault} from "src/core/accounting/StableVault.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
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
                    abi.encodeCall(StableVault.initialize, (adminParam, treasuryAddress, defaultSubVaultPerSecondRate))
                )
            )
        );
    }

    function test_givenSingleAssetDepegs_userCanStillWithdrawFromEarningChain() public {
        Logger.log("\nEarningChainDistrustedAssetE2ETest: givenSingleAssetDepegs_userCanStillWithdraw");

        uint256 userInitialDeposit = 500 * (10 ** 6);

        // Set the default rate on Stable Vault to 5% APY
        vm.prank(everyRoleAccount);
        vault.setDefaultSubVault(1_000000001547125957863212449);

        // User1 deposits 500 USDC to Vault on Accounting Chain
        _mintAndDepositUsdcToStableVault(user1, userInitialDeposit);

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

        // Asset depegs so mark it as distrusted on both chains
        vm.startPrank(everyRoleAccount);
        // Distrust the asset on the Accounting Chain
        assetRegistry_accountingChain.distrustAsset(address(USDC));
        // Distrust the asset on the Earning Chain
        assetRegistry_earningChain.distrustAsset(address(USDC));
        vm.stopPrank();

        // Check the Allocator has the USDC bridged over
        assertEq(allocator_earningChain.getAssetBalance(address(USDC)), userInitialDeposit);

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
        // Publish a pre-burn chain balance snapshot so AccountingChainGateway accepts inbound BURN_IOU_TOKEN.
        _mockChainBalance(
            EARNING_CHAIN_ID,
            0,
            block.timestamp,
            block.timestamp - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS,
            false
        );
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

    function _mintAndDepositUsdcToStableVault(address user, uint256 amount) internal {
        USDC.mint(user, amount);
        vm.startPrank(user);
        USDC.approve(address(vault), amount);
        vault.deposit(user, address(USDC), amount);
        vm.stopPrank();
    }
}

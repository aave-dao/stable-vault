// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {Logger} from "test/helpers/Logger.sol";

import {CcipAdapter} from "src/bridging/ccip/CcipAdapter.sol";
import {IAllocator} from "src/interfaces/IAllocator.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {IStableVault} from "src/interfaces/IStableVault.sol";
import {ISwapper} from "src/interfaces/ISwapper.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {Swapper} from "src/periphery/Swapper.sol";
import {Constants} from "src/types/Constants.sol";

import {BaseTest} from "test/BaseTest.t.sol";

contract EndToEndTest is BaseTest {
    using AssetLib for uint256;

    address user = makeAddr("USER");

    function setUp() public override {
        super.setUp();
    }

    function test_endToEnd() public {
        Logger.log("\nEndToEndTest");

        uint256 userInitialDeposit = 500 * (10 ** 6);
        USDC.mint(user, userInitialDeposit);

        // BaseTest setUp already configures liquidity strategies on both chains.

        // // Steps: ////
        // 1. User1 deposits 500 USDC to Vault on Accounting Chain
        vm.startPrank(user);
        USDC.approve(address(vault), userInitialDeposit);
        vault.deposit(user, address(USDC), userInitialDeposit, "");
        vm.stopPrank();

        // - check that funds are held as idle allocator liquidity
        {
            Logger.log("User deposited %s USDC into Vault", userInitialDeposit);
            assertEq(
                IERC20(address(USDC)).balanceOf(address(allocator_accountingChain)),
                userInitialDeposit,
                "Allocator should have the deposited amount of USDC"
            );
        }

        // 2. Manager sets the % rate to user to 5% APY
        {
            uint256 userPerSecondRate = 1_000000001547125957863212449; // 5% APY
            vm.prank(everyRoleAccount);
            IStableVault.UserRateData[] memory userRateData = new IStableVault.UserRateData[](1);
            userRateData[0] = IStableVault.UserRateData(user, userPerSecondRate);
            vault.setUserRate(userRateData);

            // - check that the % rate is set correctly
            Logger.log("User's per second rate is: %s", vault.getUserSubVault(user).perSecondRate);
            assertEq(vault.getUserSubVault(user).perSecondRate, userPerSecondRate);
        }

        // 3. Manager sends the money to the Earning Chain via CCIP
        uint256 bridgeFeeAmount = 1000;
        {
            vm.prank(everyRoleAccount);
            vm.deal(everyRoleAccount, bridgeFeeAmount);
            fundsHandler.pushFundsToChain{value: bridgeFeeAmount}(
                address(USDC),
                userInitialDeposit,
                EARNING_CHAIN_ID,
                address(ccipAdapter_accountingChain),
                DEFAULT_GAS_LIMIT,
                abi.encode(
                    CcipAdapter.CcipFeeParams({feeToken: Constants.NATIVE_CURRENCY, nativeFeeRefundThreshold: 0})
                ),
                ""
            );

            // - check that the funds land on Earning Chain as idle allocator liquidity
            assertEq(
                IERC20(address(USDC)).balanceOf(address(allocator_earningChain)),
                userInitialDeposit,
                "Allocator should have the deposited amount of USDC"
            );

            // Publish a chain balance snapshot via MockBundleFeed so the adapter/oracle path reflects bridged funds.
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
        }

        // 4. Manager rebalances & swaps the funds on the Earning Chain from USDC to GHO (via Swapper)
        address ghoVault_earningChain;
        {
            uint256 userInitialDepositInGho = userInitialDeposit.convertAssetDecimals(address(USDC), address(GHO));
            GHO.mint(address(swapper_earningChain), userInitialDepositInGho);

            address[] memory targets = new address[](1);
            targets[0] = address(USDC);
            bytes[] memory callDatas = new bytes[](1);
            callDatas[0] = abi.encodeCall(IERC20.transfer, (address(this), userInitialDeposit));
            uint16 slippageToleranceBps = 0;

            // Deallocation params
            IAllocator.DeallocationParams[] memory deallocationParams = new IAllocator.DeallocationParams[](0);

            // Swap params
            IAllocator.SwapParams[] memory swapParams = new IAllocator.SwapParams[](1);
            swapParams[0] = IAllocator.SwapParams({
                assetIn: address(USDC),
                amountIn: userInitialDeposit,
                assetOut: address(GHO),
                swapper: address(swapper_earningChain),
                data: abi.encode(targets, callDatas, slippageToleranceBps)
            });

            // Allocation params
            ghoVault_earningChain = address(ghoStrategyVault_earningChain);
            IAllocator.AllocationParams[] memory allocationParams = new IAllocator.AllocationParams[](1);
            allocationParams[0] = IAllocator.AllocationParams({
                asset: address(GHO), strategy: ghoVault_earningChain, amount: userInitialDepositInGho
            });

            IAllocator.RebalanceParams memory rebalanceParams = IAllocator.RebalanceParams({
                deallocations: deallocationParams, swaps: swapParams, allocations: allocationParams
            });

            IAllocator.RebalanceParams[] memory rebalances = new IAllocator.RebalanceParams[](1);
            rebalances[0] = rebalanceParams;

            Logger.log("Rebalancing by swap from USDC to GHO on the Earning chain...");
            vm.prank(everyRoleAccount);
            allocator_earningChain.rebalance(rebalances, "");

            // - check that the funds are swapped to GHO
            Logger.log(
                "\tBalance of GHO in The GHO Vault is: %s", IERC20(address(GHO)).balanceOf(ghoVault_earningChain)
            );
            assertEq(
                IERC20(address(GHO)).balanceOf(ghoVault_earningChain),
                userInitialDepositInGho,
                "Vault should have the swapped amount of GHO"
            );
            // - check that the funds land on the GHO vault
            Logger.log(
                "Allocator has %s shares of it",
                IERC4626(ghoVault_earningChain).balanceOf(address(allocator_earningChain))
            );
            assertTrue(
                IERC4626(ghoVault_earningChain).balanceOf(address(allocator_earningChain)) > 0,
                "Allocator should have shares of the vault"
            );
        }

        // 5. We wait for half a year
        vm.warp(block.timestamp + 183 days);
        Logger.log("\nHalf a year has gone by so fast...");

        // - check how much funds we owe to the user
        uint256 userEarningsInRay = vault.getUserBalance(user);
        Logger.log("User balance in RAY: %s", vault.getUserBalance(user));
        Logger.log("User balance in USDC: %s", userEarningsInRay.rayToAssetDecimals(address(USDC)));
        Logger.log("User balance in GHO: %s", userEarningsInRay.rayToAssetDecimals(address(GHO)));
        assertTrue(vault.getUserBalance(user) > userInitialDeposit, "User balance didn't grow in half a year");

        // - mock the 8% APY earnings on the GHO vault for half a year
        GHO.mint(ghoVault_earningChain, 19_615242270663188059);
        Logger.log(
            "GHO vault earned something in this time and it's balance now is: %s GHO",
            IERC4626(ghoVault_earningChain).balanceOf(address(allocator_earningChain))
        );

        // 6. Manager brings back the money from the Earning Chain to the Accounting Chain via CCIP in GHO
        // NOTE: With the oracle-based balance system, funds must be on the Accounting Chain before withdrawal
        // requests can be processed. The FundsHandler uses the chain balance oracle to track cross-chain balances.
        uint256 userEarningsInGho;
        {
            // Publish a fresh pre-return snapshot (time has warped since step 3).
            // AccountingChainGateway requires sourceChainBlockNumber >= RETURN_FUNDS message block number.
            uint256 currentEarningChainBalanceRay = earningChainGateway.getAggregatedBalance();
            _mockChainBalance(
                EARNING_CHAIN_ID,
                currentEarningChainBalanceRay,
                block.timestamp,
                block.timestamp - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS,
                false
            );

            userEarningsInGho = userEarningsInRay.rayToAssetDecimals(address(GHO));
            vm.prank(everyRoleAccount);
            vm.deal(everyRoleAccount, bridgeFeeAmount);

            {

                bytes memory bp = abi.encode(
                    CcipAdapter.CcipFeeParams({feeToken: Constants.NATIVE_CURRENCY, nativeFeeRefundThreshold: 0})
                );
                earningChainGateway.pushFundsToAccountingChain{value: bridgeFeeAmount}(
                    address(GHO), userEarningsInGho, address(ccipAdapter_earningChain), DEFAULT_GAS_LIMIT, bp, ""
                );
            }

            // Publish the post-return snapshot reflecting reduced Earning Chain balance after bridging back.
            uint256 remainingEarningChainBalanceRay = earningChainGateway.getAggregatedBalance();
            _mockChainBalance(
                EARNING_CHAIN_ID,
                remainingEarningChainBalanceRay,
                block.timestamp,
                block.timestamp - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS,
                false
            );

            // - check that the funds land on the Accounting Chain as idle allocator liquidity
            assertEq(
                IERC20(address(GHO)).balanceOf(address(allocator_accountingChain)),
                userEarningsInGho,
                "Allocator should have the returned amount of GHO"
            );
        }

        // 7. Manager rebalances & swaps the funds on the Accounting Chain from GHO to USDC (via Swapper)
        uint256 userEarningsInUsdc;
        {
            userEarningsInUsdc = userEarningsInRay.rayToAssetDecimals(address(USDC));
            // Add 1 wei extra to cover precision loss when converting from RAY to USDC decimals
            USDC.mint(address(swapper_accountingChain), userEarningsInUsdc + 1);

            address[] memory targets = new address[](1);
            targets[0] = address(GHO);
            bytes[] memory callDatas = new bytes[](1);
            uint256 divisor = 10 ** (AssetLib.getDecimals(address(GHO)) - AssetLib.getDecimals(address(USDC)));
            uint256 amountGhoIn = userEarningsInGho / divisor * divisor;
            callDatas[0] = abi.encodeCall(IERC20.transfer, (address(this), amountGhoIn));
            uint16 slippageToleranceBps = 0;

            address usdcVault_accountingChain = address(usdcStrategyVault_accountingChain);
            IAllocator.DeallocationParams[] memory deallocationParams = new IAllocator.DeallocationParams[](0);

            IAllocator.SwapParams[] memory swapParams = new IAllocator.SwapParams[](1);
            swapParams[0] = IAllocator.SwapParams({
                assetIn: address(GHO),
                amountIn: amountGhoIn,
                assetOut: address(USDC),
                swapper: address(swapper_accountingChain),
                data: abi.encode(targets, callDatas, slippageToleranceBps)
            });

            IAllocator.AllocationParams[] memory allocationParams = new IAllocator.AllocationParams[](1);
            allocationParams[0] = IAllocator.AllocationParams({
                asset: address(USDC), strategy: usdcVault_accountingChain, amount: userEarningsInUsdc + 1
            });

            IAllocator.RebalanceParams memory rebalanceParams = IAllocator.RebalanceParams({
                deallocations: deallocationParams, swaps: swapParams, allocations: allocationParams
            });

            IAllocator.RebalanceParams[] memory rebalances = new IAllocator.RebalanceParams[](1);
            rebalances[0] = rebalanceParams;

            Logger.log("Rebalancing by swap from GHO to USDC on the Accounting chain...");
            vm.prank(everyRoleAccount);
            allocator_accountingChain.rebalance(rebalances, "");

            // - check that the funds are swapped to USDC (includes 1 extra wei for precision)
            Logger.log(
                "\tBalance of USDC in The USDC Vault is: %s", IERC20(address(USDC)).balanceOf(usdcVault_accountingChain)
            );
            assertEq(
                IERC20(address(USDC)).balanceOf(usdcVault_accountingChain),
                userEarningsInUsdc + 1,
                "Vault should have the swapped amount of USDC"
            );
            // - check that the funds land on the USDC vault
            Logger.log(
                "Allocator has %s shares of it",
                IERC4626(usdcVault_accountingChain).balanceOf(address(allocator_accountingChain))
            );
            assertTrue(
                IERC4626(usdcVault_accountingChain).balanceOf(address(allocator_accountingChain)) > 0,
                "Allocator should have shares of the vault"
            );
        }

        // 8. User asks for withdrawal of the whole amount of his earnings (which are $500+ - in USDC)
        // Now that funds are back on the Accounting Chain, the withdrawal request can be processed.
        uint256 iouAmountRequestedRay;
        {
            Logger.log("User creates a WithdrawalRequest...");
            Logger.log("Total system balance: %s", fundsHandler.getAggregatedBalance());

            // Request withdrawal
            vm.prank(user);
            iouAmountRequestedRay = vault.requestWithdrawal(user, 0, "");

            Logger.log("... request withdrawal minted IOU tokens: %s", iouAmountRequestedRay);
            // Check user IOU token balance
            assertGt(iouToken_accountingChain.balanceOf(user), 0, "User should have minted IOU tokens");

            // - check that we don't owe the user any funds
            Logger.log("User balance in RAY after withdrawal request: %s", vault.getUserBalance(user));
            assertEq(vault.getUserBalance(user), 0, "User balance should be down to 0 after full withdrawal request");
        }

        // 9. User triggers the execute() withdrawal to send the funds back to the user
        {
            vm.prank(user);
            vault.executeWithdrawal(user, address(USDC), 0, iouAmountRequestedRay, "");
            // Check IOU token balance went down
            assertEq(iouToken_accountingChain.balanceOf(user), 0, "User should have minted IOU tokens");

            // - check that the funds are received by the user correctly
            Logger.log("User balance in USDC after withdrawal: %s USDC", IERC20(address(USDC)).balanceOf(user));
            assertEq(
                IERC20(address(USDC)).balanceOf(user),
                userEarningsInUsdc,
                "User should have the withdrawn amount of USDC"
            );

            // - check that we don't owe the user any funds
            Logger.log("User balance in RAY after withdrawal request: %s", vault.getUserBalance(user));
            assertEq(vault.getUserBalance(user), 0, "User balance should be down to 0 after full withdrawal request");
        }

        // Manager claims fees (withdraws profits)
        {
            uint256 ghoBalanceOnVaultLeft = IERC4626(ghoVault_earningChain).balanceOf(address(allocator_earningChain));
            Logger.log("Earning chain GHO vault balance after withdrawal is now: %s GHO", ghoBalanceOnVaultLeft);

            // Update oracle so the AccountingChainGateway accepts the inbound RETURN_FUNDS message
            _mockChainBalance(
                EARNING_CHAIN_ID,
                earningChainGateway.getAggregatedBalance(),
                block.timestamp,
                block.timestamp - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS,
                false
            );

            vm.prank(everyRoleAccount);
            vm.deal(everyRoleAccount, bridgeFeeAmount);
            {

                bytes memory bp = abi.encode(
                    CcipAdapter.CcipFeeParams({feeToken: Constants.NATIVE_CURRENCY, nativeFeeRefundThreshold: 0})
                );
                earningChainGateway.pushFundsToAccountingChain{value: bridgeFeeAmount}(
                    address(GHO), ghoBalanceOnVaultLeft, address(ccipAdapter_earningChain), DEFAULT_GAS_LIMIT, bp, ""
                );
            }

            address[] memory assets = new address[](1);
            uint256[] memory amounts = new uint256[](1);
            assets[0] = address(GHO);
            amounts[0] = ghoBalanceOnVaultLeft;

            Logger.log("Treasury's GHO balance before claiming fees profits: %s GHO", GHO.balanceOf(treasury));

            vm.prank(everyRoleAccount);
            vault.claimSurplusInterest(assets, amounts);

            uint256 newTreasuryGhoBalance = GHO.balanceOf(treasury);
            Logger.log("Treasury's GHO balance after claiming fees profits: %s GHO", newTreasuryGhoBalance);
            assertEq(
                newTreasuryGhoBalance,
                ghoBalanceOnVaultLeft,
                "Treasury should have the same amount of GHO after claiming fees profits"
            );
        }
    }
}

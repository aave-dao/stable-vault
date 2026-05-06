// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {IERC4626} from "forge-std/interfaces/IERC4626.sol";
import {Logger} from "test/helpers/Logger.sol";

import {BridgeParamsCodec} from "src/bridging/BridgeParamsCodec.sol";
import {IAllocator} from "src/interfaces/IAllocator.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {IStableVault} from "src/interfaces/IStableVault.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {Swapper} from "src/periphery/Swapper.sol";
import {Constants} from "src/types/Constants.sol";
import {Errors} from "src/types/Errors.sol";

import {BaseTest} from "test/BaseTest.t.sol";

contract EndToEndTest is BaseTest {
    using AssetLib for uint256;

    address user = makeAddr("USER");

    function setUp() public override {
        super.setUp();
    }

    function testDepositSlippageBase() public {
        USDC.mint(user, 100e6);

        // User deposits directly into the strategy vault.
        vm.startPrank(user);
        USDC.approve(address(usdcStrategyVault_accountingChain), 1e6);
        usdcStrategyVault_accountingChain.deposit(1e6, user);
        vm.stopPrank();

        // Inflate the funds in the strategy vault.
        USDC.mint(address(usdcStrategyVault_accountingChain), 1e3);

        // User makes a deposit of 2 wei into Stable Vault.
        vm.startPrank(user);
        USDC.approve(address(vault), 2);
        vault.deposit(user, address(USDC), 2);

        uint256 userBalanceInRay = vault.getUserBalance(user);
        uint256 vaultAssetsInRay = vault.getAggregatedBalance();
        Logger.log("userBalanceInRay %e", userBalanceInRay);
        Logger.log("vaultAssetsInRay %e", vaultAssetsInRay);
        assert(userBalanceInRay > vaultAssetsInRay);
        // The user's balance in Stable Vault is 1 unit of USDC greater than the actual assets in the system (this is
        // treated as interest the system owes to the user).
        assertEq(userBalanceInRay - vaultAssetsInRay, 1e21);
        uint256 originalDepositRay = vault.getGlobalOriginalDepositAmount();
        // Check that the original deposit is incremented by the amount of the net deposit.
        assertEq(originalDepositRay, vaultAssetsInRay);
    }

    function testDepositSlippageInflatedVault_reverts_ifSlippageExceeded() public {
        USDC.mint(user, 100e6);

        // User deposits directly into the strategy vault.
        vm.startPrank(user);
        USDC.approve(address(usdcStrategyVault_accountingChain), 1);
        usdcStrategyVault_accountingChain.deposit(1, user);
        vm.stopPrank();

        // Inflate the funds in the strategy vault.
        USDC.mint(address(usdcStrategyVault_accountingChain), 1e6);

        // Get the user to make a deposit of the amount for maximum loss - check that the deposit reverts if a slippage
        // tolerane is exceeded.
        uint256 amountForMaximumLoss = usdcStrategyVault_accountingChain.previewMint(2) - 1;
        vm.startPrank(user);
        USDC.approve(address(vault), amountForMaximumLoss);
        vm.expectRevert(Errors.InsufficientAmountOut.selector);
        vault.deposit(user, address(USDC), amountForMaximumLoss);

        uint256 userBalanceInRay = vault.getUserBalance(user);
        uint256 vaultAssetsInRay = vault.getAggregatedBalance();
        assertEq(userBalanceInRay, vaultAssetsInRay);
        assertEq(userBalanceInRay, 0);
    }

    function test_endToEnd() public {
        Logger.log("\nEndToEndTest");

        uint256 userInitialDeposit = 500 * (10 ** 6);
        USDC.mint(user, userInitialDeposit);

        // BaseTest setUp already configures default liquidity vaults/strategies on both chains.

        // // Steps: ////
        // 1. User1 deposits 500 USDC to Vault on Accounting Chain
        vm.startPrank(user);
        USDC.approve(address(vault), userInitialDeposit);
        vault.deposit(user, address(USDC), userInitialDeposit);
        vm.stopPrank();

        // - check that funds are dropped into default liquidity vault
        {
            Logger.log("User deposited %s USDC into Vault", userInitialDeposit);
            address defaultUsdcVault_AccountingChain = allocator_accountingChain.getDefaultStrategy(address(USDC));
            Logger.log("Default vault for USDC is: %s", defaultUsdcVault_AccountingChain);
            Logger.log("It's balance of USDC is: %s", IERC20(address(USDC)).balanceOf(defaultUsdcVault_AccountingChain));
            // TODO: Replace with Before/After balance
            assertEq(
                IERC20(address(USDC)).balanceOf(defaultUsdcVault_AccountingChain),
                userInitialDeposit,
                "Vault should have the deposited amount of USDC"
            );
            Logger.log(
                "Allocator has %s shares of it",
                IERC4626(defaultUsdcVault_AccountingChain).balanceOf(address(allocator_accountingChain))
            );
            assertTrue(
                IERC4626(defaultUsdcVault_AccountingChain).balanceOf(address(allocator_accountingChain)) > 0,
                "Allocator should have shares of the vault"
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
        address defaultUsdcVault_earningChain = allocator_earningChain.getDefaultStrategy(address(USDC));
        {
            vm.prank(everyRoleAccount);
            vm.deal(everyRoleAccount, bridgeFeeAmount);
            fundsHandler.pushFundsToChain{value: bridgeFeeAmount}(
                address(USDC),
                userInitialDeposit,
                EARNING_CHAIN_ID,
                address(ccipAdapter_accountingChain),
                DEFAULT_GAS_LIMIT,
                BridgeParamsCodec.encode(
                    BridgeParamsCodec.BridgeParams({
                        feeToken: Constants.NATIVE_CURRENCY, feeAmount: bridgeFeeAmount, feeRefundThreshold: 0, data: ""
                    })
                )
            );

            // - check that the funds land on Earning Chain and are dropped into default liquidity vault there
            Logger.log("Earning Chain default vault for USDC is: %s", defaultUsdcVault_earningChain);
            Logger.log("It's balance of USDC is: %s", IERC20(address(USDC)).balanceOf(defaultUsdcVault_earningChain));
            assertEq(
                IERC20(address(USDC)).balanceOf(defaultUsdcVault_earningChain),
                userInitialDeposit,
                "Vault should have the deposited amount of USDC"
            );
            Logger.log(
                "Allocator has %s shares of it",
                IERC4626(defaultUsdcVault_earningChain).balanceOf(address(allocator_earningChain))
            );
            assertTrue(
                IERC4626(defaultUsdcVault_earningChain).balanceOf(address(allocator_earningChain)) > 0,
                "Allocator should have shares of the vault"
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
        address defaultGhoVault_earningChain;
        {
            uint256 userInitialDepositInGho = userInitialDeposit.convertAssetDecimals(address(USDC), address(GHO));
            GHO.mint(address(swapper_earningChain), userInitialDepositInGho);

            address[] memory targets = new address[](1);
            targets[0] = address(USDC);
            bytes[] memory callDatas = new bytes[](1);
            callDatas[0] = abi.encodeCall(IERC20.transfer, (address(this), userInitialDeposit));
            Swapper.SlippageParams memory slippageParams = Swapper.SlippageParams(0, address(0));

            defaultGhoVault_earningChain = allocator_earningChain.getDefaultStrategy(address(GHO));
            // Deallocation params
            IAllocator.DeallocationParams[] memory deallocationParams = new IAllocator.DeallocationParams[](1);
            deallocationParams[0] =
                IAllocator.DeallocationParams(address(USDC), defaultUsdcVault_earningChain, userInitialDeposit);

            // Swap params
            IAllocator.SwapParams[] memory swapParams = new IAllocator.SwapParams[](1);
            swapParams[0] = IAllocator.SwapParams({
                assetIn: address(USDC),
                amountIn: userInitialDeposit,
                assetOut: address(GHO),
                swapper: address(swapper_earningChain),
                data: abi.encode(targets, callDatas, slippageParams)
            });

            // Allocation params
            IAllocator.AllocationParams[] memory allocationParams = new IAllocator.AllocationParams[](1);
            allocationParams[0] = IAllocator.AllocationParams({
                asset: address(GHO), strategy: defaultGhoVault_earningChain, amount: userInitialDepositInGho
            });

            IAllocator.RebalanceParams memory rebalanceParams = IAllocator.RebalanceParams({
                deallocations: deallocationParams, swaps: swapParams, allocations: allocationParams
            });

            IAllocator.RebalanceParams[] memory rebalances = new IAllocator.RebalanceParams[](1);
            rebalances[0] = rebalanceParams;

            Logger.log("Rebalancing by swap from USDC to GHO on the Earning chain...");
            vm.prank(everyRoleAccount);
            allocator_earningChain.rebalance(rebalances);

            // - check that the funds are swapped to GHO
            Logger.log(
                "\tBalance of GHO in The GHO Vault is: %s", IERC20(address(GHO)).balanceOf(defaultGhoVault_earningChain)
            );
            assertEq(
                IERC20(address(GHO)).balanceOf(defaultGhoVault_earningChain),
                userInitialDepositInGho,
                "Vault should have the swapped amount of GHO"
            );
            // - check that the funds land on the GHO vault
            Logger.log(
                "Allocator has %s shares of it",
                IERC4626(defaultGhoVault_earningChain).balanceOf(address(allocator_earningChain))
            );
            assertTrue(
                IERC4626(defaultGhoVault_earningChain).balanceOf(address(allocator_earningChain)) > 0,
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
        GHO.mint(defaultGhoVault_earningChain, 19_615242270663188059);
        Logger.log(
            "GHO vault earned something in this time and it's balance now is: %s GHO",
            IERC4626(defaultGhoVault_earningChain).balanceOf(address(allocator_earningChain))
        );

        // 6. Manager brings back the money from the Earning Chain to the Accounting Chain via CCIP in GHO
        // NOTE: With the oracle-based balance system, funds must be on the Accounting Chain before withdrawal
        // requests can be processed. The FundsHandler uses the chain balance oracle to track cross-chain balances.
        uint256 userEarningsInGho;
        address defaultGhoVault_accountingChain = allocator_accountingChain.getDefaultStrategy(address(GHO));
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
                bytes memory bp = BridgeParamsCodec.encode(
                    BridgeParamsCodec.BridgeParams({
                        feeToken: Constants.NATIVE_CURRENCY, feeAmount: bridgeFeeAmount, feeRefundThreshold: 0, data: ""
                    })
                );
                earningChainGateway.pushFundsToAccountingChain{value: bridgeFeeAmount}(
                    address(GHO), userEarningsInGho, address(ccipAdapter_earningChain), DEFAULT_GAS_LIMIT, bp
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

            // - check that the funds land on the Accounting Chain and are dropped into default liquidity vault there
            Logger.log("Accounting Chain default vault for GHO is: %s", defaultGhoVault_accountingChain);
            Logger.log("It's balance of GHO is: %s", IERC20(address(GHO)).balanceOf(defaultGhoVault_accountingChain));
            assertEq(
                IERC20(address(GHO)).balanceOf(defaultGhoVault_accountingChain),
                userEarningsInGho,
                "Vault should have the exited amount of GHO"
            );
            Logger.log(
                "Allocator has %s shares of it",
                IERC4626(defaultGhoVault_accountingChain).balanceOf(address(allocator_accountingChain))
            );
            assertTrue(
                IERC4626(defaultGhoVault_accountingChain).balanceOf(address(allocator_accountingChain)) > 0,
                "Allocator should have shares of the vault"
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
            Swapper.SlippageParams memory slippageParams = Swapper.SlippageParams(0, address(0));

            address defaultUsdcVault_accountingChain = allocator_accountingChain.getDefaultStrategy(address(USDC));
            IAllocator.DeallocationParams[] memory deallocationParams = new IAllocator.DeallocationParams[](1);
            deallocationParams[0] =
                IAllocator.DeallocationParams(address(GHO), defaultGhoVault_accountingChain, amountGhoIn);

            IAllocator.SwapParams[] memory swapParams = new IAllocator.SwapParams[](1);
            swapParams[0] = IAllocator.SwapParams({
                assetIn: address(GHO),
                amountIn: amountGhoIn,
                assetOut: address(USDC),
                swapper: address(swapper_accountingChain),
                data: abi.encode(targets, callDatas, slippageParams)
            });

            IAllocator.AllocationParams[] memory allocationParams = new IAllocator.AllocationParams[](1);
            allocationParams[0] = IAllocator.AllocationParams({
                asset: address(USDC), strategy: defaultUsdcVault_accountingChain, amount: userEarningsInUsdc + 1
            });

            IAllocator.RebalanceParams memory rebalanceParams = IAllocator.RebalanceParams({
                deallocations: deallocationParams, swaps: swapParams, allocations: allocationParams
            });

            IAllocator.RebalanceParams[] memory rebalances = new IAllocator.RebalanceParams[](1);
            rebalances[0] = rebalanceParams;

            Logger.log("Rebalancing by swap from GHO to USDC on the Accounting chain...");
            vm.prank(everyRoleAccount);
            allocator_accountingChain.rebalance(rebalances);

            // - check that the funds are swapped to USDC (includes 1 extra wei for precision)
            Logger.log(
                "\tBalance of USDC in The USDC Vault is: %s",
                IERC20(address(USDC)).balanceOf(defaultUsdcVault_accountingChain)
            );
            assertEq(
                IERC20(address(USDC)).balanceOf(defaultUsdcVault_accountingChain),
                userEarningsInUsdc + 1,
                "Vault should have the swapped amount of USDC"
            );
            // - check that the funds land on the USDC vault
            Logger.log(
                "Allocator has %s shares of it",
                IERC4626(defaultUsdcVault_accountingChain).balanceOf(address(allocator_accountingChain))
            );
            assertTrue(
                IERC4626(defaultUsdcVault_accountingChain).balanceOf(address(allocator_accountingChain)) > 0,
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
            iouAmountRequestedRay = vault.requestWithdrawal(user, 0);

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
            uint256 ghoBalanceOnVaultLeft =
                IERC4626(defaultGhoVault_earningChain).balanceOf(address(allocator_earningChain));
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
                bytes memory bp = BridgeParamsCodec.encode(
                    BridgeParamsCodec.BridgeParams({
                        feeToken: Constants.NATIVE_CURRENCY, feeAmount: bridgeFeeAmount, feeRefundThreshold: 0, data: ""
                    })
                );
                earningChainGateway.pushFundsToAccountingChain{value: bridgeFeeAmount}(
                    address(GHO), ghoBalanceOnVaultLeft, address(ccipAdapter_earningChain), DEFAULT_GAS_LIMIT, bp
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

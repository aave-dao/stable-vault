// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {console} from "forge-std/console.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

import {Swapper} from "../../src/common/Swapper.sol";
import {IAllocator} from "../../src/interfaces/IAllocator.sol";
import {IBasedBoostedVault} from "../../src/interfaces/IBasedBoostedVault.sol";
import {IChainGateway} from "../../src/interfaces/IChainGateway.sol";
import {AssetLib} from "../../src/libraries/AssetLib.sol";
import {BaseTest} from "../BaseTest.t.sol";

contract EndToEndTest is BaseTest {
    using AssetLib for uint256;

    address user = makeAddr("USER");

    function setUp() public override {
        super.setUp();
    }

    function test_endToEnd() public {
        console.log("\nEndToEndTest");

        uint256 userInitialDeposit = 500 * (10 ** 6);
        USDC.mint(user, userInitialDeposit);

        // TODO:
        /*
            1. Setup default liquidity vaults/strategies on both chains for every currency
        */

        // // Steps: ////
        // 1. User1 deposits 500 USDC to Vault on Accounting Chain
        vm.startPrank(user);
        USDC.approve(address(vault), userInitialDeposit);
        vault.deposit(user, address(USDC), userInitialDeposit);
        vm.stopPrank();

        // - check that funds are dropped into default liquidity vault
        {
            console.log("User deposited %s USDC into Vault", userInitialDeposit);
            address defaultUsdcVault_AccountingChain = allocator_accountingChain.getDefaultStrategy(address(USDC));
            console.log("Default vault for USDC is: %s", defaultUsdcVault_AccountingChain);
            console.log(
                "It's balance of USDC is: %s", IERC20(address(USDC)).balanceOf(defaultUsdcVault_AccountingChain)
            );
            // TODO: Replace with Before/After balance
            assertEq(
                IERC20(address(USDC)).balanceOf(defaultUsdcVault_AccountingChain),
                userInitialDeposit,
                "Vault should have the deposited amount of USDC"
            );
            console.log(
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
            IBasedBoostedVault.UserRateData[] memory userRateData = new IBasedBoostedVault.UserRateData[](1);
            userRateData[0] = IBasedBoostedVault.UserRateData(user, userPerSecondRate);
            vault.setUserRate(userRateData);

            // - check that the % rate is set correctly
            console.log("User's per second rate is: %s", vault.getUserSubVault(user).perSecondRate);
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
                IChainGateway.BridgeParams({
                    feePayer: everyRoleAccount,
                    feeToken: address(0),
                    feeAmount: bridgeFeeAmount,
                    gasLimit: 300000,
                    data: ""
                })
            );

            // - check that the funds land on Earning Chain and are dropped into default liquidity vault there
            console.log("Earning Chain default vault for USDC is: %s", defaultUsdcVault_earningChain);
            console.log("It's balance of USDC is: %s", IERC20(address(USDC)).balanceOf(defaultUsdcVault_earningChain));
            assertEq(
                IERC20(address(USDC)).balanceOf(defaultUsdcVault_earningChain),
                userInitialDeposit,
                "Vault should have the deposited amount of USDC"
            );
            console.log(
                "Allocator has %s shares of it",
                IERC4626(defaultUsdcVault_earningChain).balanceOf(address(allocator_earningChain))
            );
            assertTrue(
                IERC4626(defaultUsdcVault_earningChain).balanceOf(address(allocator_earningChain)) > 0,
                "Allocator should have shares of the vault"
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

            console.log("Rebalancing by swap from USDC to GHO on the Earning chain...");
            vm.prank(everyRoleAccount);
            allocator_earningChain.rebalance(rebalances);

            // - check that the funds are swapped to GHO
            console.log(
                "\tBalance of GHO in The GHO Vault is: %s", IERC20(address(GHO)).balanceOf(defaultGhoVault_earningChain)
            );
            assertEq(
                IERC20(address(GHO)).balanceOf(defaultGhoVault_earningChain),
                userInitialDepositInGho,
                "Vault should have the swapped amount of GHO"
            );
            // - check that the funds land on the GHO vault
            console.log(
                "Allocator has %s shares of it",
                IERC4626(defaultGhoVault_earningChain).balanceOf(address(allocator_earningChain))
            );
            assertTrue(
                IERC4626(defaultGhoVault_earningChain).balanceOf(address(allocator_earningChain)) > 0,
                "Allocator should have shares of the vault"
            );
        }

        // 5. We wait for half a year
        vm.warp(183 days);
        console.log("\nHalf a year has gone by so fast...");

        // - check how much funds we owe to the user
        uint256 userEarningsInRay = vault.getUserBalance(user);
        console.log("User balance in RAY: %s", vault.getUserBalance(user));
        console.log("User balance in USDC: %s", userEarningsInRay.rayToAssetDecimals(address(USDC)));
        console.log("User balance in GHO: %s", userEarningsInRay.rayToAssetDecimals(address(GHO)));
        assertTrue(vault.getUserBalance(user) > userInitialDeposit, "User balance didn't grow in half a year");

        // - mock the 8% APY earnings on the GHO vault for half a year
        GHO.mint(defaultGhoVault_earningChain, 19_615242270663188059);
        console.log(
            "GHO vault earned something in this time and it's balance now is: %s GHO",
            IERC4626(defaultGhoVault_earningChain).balanceOf(address(allocator_earningChain))
        );

        // 6. User asks for withdrawal of the whole amount of his earnings (which are $500+ - in USDC)
        uint256 iouAmountRequestedRay;
        {
            console.log("User creates a WithdrawalRequest...");
            vm.prank(user);
            vm.expectRevert(
                abi.encodeWithSelector(
                    IBasedBoostedVault.InsufficientAssets.selector,
                    user,
                    512381781828396559943369876000,
                    500000000000000000000000000000
                )
            );
            iouAmountRequestedRay = vault.requestWithdrawal(user, 0);

            // Send balance snap shot update so that Accounting chain has latest assets balances
            vm.prank(everyRoleAccount);
            vm.deal(everyRoleAccount, bridgeFeeAmount);
            earningChainGateway.sendBalanceUpdateWithFeePayer{value: bridgeFeeAmount}(
                IChainGateway.BridgeParams({
                    feePayer: everyRoleAccount,
                    feeToken: address(0),
                    feeAmount: bridgeFeeAmount,
                    gasLimit: 300000,
                    data: ""
                })
            );

            console.log("Total system balance: %s", fundsHandler.getAggregatedBalance());

            // Try the request again
            vm.prank(user);
            iouAmountRequestedRay = vault.requestWithdrawal(user, iouAmountRequestedRay);

            console.log("... request withdrawal minted IOU tokens: %s", iouAmountRequestedRay);
            // Check user IOU token balance
            assertGt(iouToken_accountingChain.balanceOf(user), 0, "User should have minted IOU tokens");

            // vm.expectRevert(
            // abi.encodeWithSelector(ERC4626ExceededMaxWithdraw.selector, allocator_accountingChain, userBalanceInUsdc,
            // 0) );
            vm.prank(user);
            vm.expectRevert("TestErc20: transfer amount exceeds balance");
            vault.executeWithdrawal(user, address(USDC), iouAmountRequestedRay);

            // - check that we don't owe the user any funds
            console.log("User balance in RAY after withdrawal request: %s", vault.getUserBalance(user));
            assertEq(vault.getUserBalance(user), 0, "User balance should be down to 0 after full withdrawal request");
        }

        // 7. Manager brings back the money from the Earning Chain to the Accounting Chain via CCIP in GHO
        uint256 userEarningsInGho;
        address defaultGhoVault_accountingChain = allocator_accountingChain.getDefaultStrategy(address(GHO));
        {
            userEarningsInGho = userEarningsInRay.rayToAssetDecimals(address(GHO));
            vm.prank(everyRoleAccount);
            vm.deal(everyRoleAccount, bridgeFeeAmount);
            earningChainGateway.pushFundsToAccountingChain{value: bridgeFeeAmount}(
                address(GHO),
                userEarningsInGho,
                IChainGateway.BridgeParams({
                    feePayer: everyRoleAccount,
                    feeToken: address(0),
                    feeAmount: bridgeFeeAmount,
                    gasLimit: 300000,
                    data: ""
                })
            );

            // - check that the funds land on the Accounting Chain and are dropped into default liquidity vault there
            console.log("Accounting Chain default vault for GHO is: %s", defaultGhoVault_accountingChain);
            console.log("It's balance of GHO is: %s", IERC20(address(GHO)).balanceOf(defaultGhoVault_accountingChain));
            assertEq(
                IERC20(address(GHO)).balanceOf(defaultGhoVault_accountingChain),
                userEarningsInGho,
                "Vault should have the exited amount of GHO"
            );
            console.log(
                "Allocator has %s shares of it",
                IERC4626(defaultGhoVault_accountingChain).balanceOf(address(allocator_accountingChain))
            );
            assertTrue(
                IERC4626(defaultGhoVault_accountingChain).balanceOf(address(allocator_accountingChain)) > 0,
                "Allocator should have shares of the vault"
            );
        }

        // 8. Manager rebalances & swaps the funds on the Accounting Chain from GHO to USDC (via Swapper)
        uint256 userEarningsInUsdc;
        {
            userEarningsInUsdc = userEarningsInRay.rayToAssetDecimals(address(USDC));
            USDC.mint(address(swapper_accountingChain), userEarningsInUsdc);

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
                asset: address(USDC), strategy: defaultUsdcVault_accountingChain, amount: userEarningsInUsdc
            });

            IAllocator.RebalanceParams memory rebalanceParams = IAllocator.RebalanceParams({
                deallocations: deallocationParams, swaps: swapParams, allocations: allocationParams
            });

            IAllocator.RebalanceParams[] memory rebalances = new IAllocator.RebalanceParams[](1);
            rebalances[0] = rebalanceParams;

            console.log("Rebalancing by swap from GHO to USDC on the Accounting chain...");
            vm.prank(everyRoleAccount);
            allocator_accountingChain.rebalance(rebalances);

            // - check that the funds are swapped to USDC
            console.log(
                "\tBalance of USDC in The USDC Vault is: %s",
                IERC20(address(USDC)).balanceOf(defaultUsdcVault_accountingChain)
            );
            assertEq(
                IERC20(address(USDC)).balanceOf(defaultUsdcVault_accountingChain),
                userEarningsInUsdc,
                "Vault should have the swapped amount of USDC"
            );
            // - check that the funds land on the USDC vault
            console.log(
                "Allocator has %s shares of it",
                IERC4626(defaultUsdcVault_accountingChain).balanceOf(address(allocator_accountingChain))
            );
            assertTrue(
                IERC4626(defaultUsdcVault_accountingChain).balanceOf(address(allocator_accountingChain)) > 0,
                "Allocator should have shares of the vault"
            );
        }

        // 9. User triggers the execute() withdrawal to send the funds back to the user
        {
            vm.prank(user);
            vault.executeWithdrawal(user, address(USDC), iouAmountRequestedRay);
            // Check IOU token balance went down
            assertEq(iouToken_accountingChain.balanceOf(user), 0, "User should have minted IOU tokens");

            // - check that the funds are received by the user correctly
            console.log("User balance in USDC after withdrawal: %s USDC", IERC20(address(USDC)).balanceOf(user));
            assertEq(
                IERC20(address(USDC)).balanceOf(user),
                userEarningsInUsdc,
                "User should have the withdrawn amount of USDC"
            );

            // - check that we don't owe the user any funds
            console.log("User balance in RAY after withdrawal request: %s", vault.getUserBalance(user));
            assertEq(vault.getUserBalance(user), 0, "User balance should be down to 0 after full withdrawal request");
        }

        // Manager claims fees (withdraws profits)
        {
            uint256 ghoBalanceOnVaultLeft =
                IERC4626(defaultGhoVault_earningChain).balanceOf(address(allocator_earningChain));
            console.log("Earning chain GHO vault balance after withdrawal is now: %s GHO", ghoBalanceOnVaultLeft);
            vm.prank(everyRoleAccount);
            vm.deal(everyRoleAccount, bridgeFeeAmount);
            earningChainGateway.pushFundsToAccountingChain{value: bridgeFeeAmount}(
                address(GHO),
                ghoBalanceOnVaultLeft,
                IChainGateway.BridgeParams({
                    feePayer: everyRoleAccount,
                    feeToken: address(0),
                    feeAmount: bridgeFeeAmount,
                    gasLimit: 300000,
                    data: ""
                })
            );

            address[] memory assets = new address[](1);
            uint256[] memory amounts = new uint256[](1);
            assets[0] = address(GHO);
            amounts[0] = ghoBalanceOnVaultLeft;

            console.log("Manager's GHO balance before claiming fees profits: %s GHO", GHO.balanceOf(everyRoleAccount));

            vm.prank(everyRoleAccount);
            vault.claimFees(assets, amounts);

            uint256 newManagerGhoBalance = GHO.balanceOf(everyRoleAccount);
            console.log("Manager's GHO balance after claiming fees profits: %s GHO", newManagerGhoBalance);
            assertEq(
                newManagerGhoBalance,
                ghoBalanceOnVaultLeft,
                "Manager should have the same amount of GHO after claiming fees profits"
            );
        }
    }
}

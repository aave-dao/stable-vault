// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {console} from "forge-std/console.sol";
import {BaseTest} from "./BaseTest.t.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IERC4626} from "forge-std/interfaces/IERC4626.sol";

contract EndToEndTest is BaseTest {
    function setUp() public override {
        super.setUp();
    }

    function test_endToEnd() public {
        console.log("\nEndToEndTest");

        address user = makeAddr("USER");
        uint256 userInitialDeposit = 500 * (10 ** 6);
        USDC.mint(user, userInitialDeposit);

        // TODO:
        /*
            1. Setup default liquidity vaults/strategies on both chains for every currency
        */

        //// Steps: ////
        //    1. User1 deposits 500 USDC to Vault on Accounting Chain
        vm.startPrank(user);
        USDC.approve(address(vault), userInitialDeposit);
        vault.deposit(user, address(USDC), userInitialDeposit);
        vm.stopPrank();

        //        - check that funds are dropped into default liquidity vault
        console.log("User deposited %s USDC into Vault", userInitialDeposit);
        address defaultUsdcVault_AccountingChain = allocator_accountingChain.getVault(address(USDC));
        console.log("Default vault for USDC is: %s", defaultUsdcVault_AccountingChain);
        console.log("It's balance of USDC is: %s", IERC20(address(USDC)).balanceOf(defaultUsdcVault_AccountingChain));
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

        //    2. Manager sets the % rate to user to 5% APY
        uint256 userPerSecondRate = 1_000000001547125957863212449; // 5% APY
        vm.prank(manager);
        vault.setUserRate(user, userPerSecondRate);

        //        - check that the % rate is set correctly
        console.log("User's per second rate is: %s", vault.getUserSubVault(user).perSecondRate);
        assertEq(vault.getUserSubVault(user).perSecondRate, userPerSecondRate);

        //    3. Manager sends the money to the Earning Chain via CCIP
        vm.prank(manager);
        fundsHandler.pushFundsToChain(address(USDC), userInitialDeposit, EARNING_CHAIN_ID);

        //        - check that the funds land on Earning Chain and are dropped into default liquidity vault there
        address defaultUsdcVault_EarningChain = allocator_earningChain.getVault(address(USDC));
        console.log("Earning Chain default vault for USDC is: %s", defaultUsdcVault_EarningChain);
        console.log("It's balance of USDC is: %s", IERC20(address(USDC)).balanceOf(defaultUsdcVault_EarningChain));
        assertEq(
            IERC20(address(USDC)).balanceOf(defaultUsdcVault_EarningChain),
            userInitialDeposit,
            "Vault should have the deposited amount of USDC"
        );
        console.log(
            "Allocator has %s shares of it",
            IERC4626(defaultUsdcVault_EarningChain).balanceOf(address(allocator_earningChain))
        );
        assertTrue(
            IERC4626(defaultUsdcVault_EarningChain).balanceOf(address(allocator_earningChain)) > 0,
            "Allocator should have shares of the vault"
        );

        //    4. Manager rebalances & swaps the funds on the Earning Chain from USDC to GHO (via Swapper)
        //        - check that the funds are swapped to GHO
        //        - check that the funds land on the GHO vault
        //    5. We wait for half a year
        //        - check how much funds we owe to the user
        //        - mock the 8% APY earnings on the GHO vault for half a year
        //    6. User asks for withdrawal of the whole amount of his earnings (which are $500+ - in USDC)
        //        - check that the withdrawalId is created and passed to FundsHandler and execute() fails for now
        //        - check that we don't owe the user any funds
        //    7. Manager brings back the money from the Earning Chain to the Accounting Chain via CCIP in GHO
        //        - check that the funds land on the Accounting Chain and are dropped into default liquidity vault there
        //    8. Manager rebalances & swaps the funds on the Accounting Chain from GHO to USDC (via Swapper)
        //        - check that the funds are swapped to USDC
        //        - check that the funds land on the USDC vault
        //    9. Manager triggers the execute() withdrawal to send the funds back to the user
        //        - check that the funds are received by the user correctly
        //        - check that the withdrawal request is deleted and gone
        //        - check that we don't owe the user any funds
        //
    }
}

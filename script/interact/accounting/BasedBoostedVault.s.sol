// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AccountingChainBaseScript} from "script/interact/accounting/AccountingChainBaseScript.s.sol";

import {IBasedBoostedVault} from "src/interfaces/IBasedBoostedVault.sol";

/// @dev See example usage below:
/// 1. > export RPC_URL=<rpc-url>
/// 2. > cast wallet import <account_name> --private-key 0xYOUR_PRIVATE_KEY
/// 3. > forge script script/interact/accounting/BasedBoostedVault.s.sol \
///  --rpc-url $RPC_URL \
///  --sig "executeWithdrawal()" \
///  --account <account_name> \
///  --sender <account_address> \
///  --broadcast // leave this out to simular the tx
contract BasedBoostedVault is AccountingChainBaseScript {
    address constant BASED_BOOSTED_VAULT = 0xb49bD8C7fa9d910D77eF5A356CcFdF6A4ba14602;

    function deposit() public {
        address asset = USDC;
        uint256 amount = 123456;

        vm.startBroadcast();
        IERC20(asset).approve(BASED_BOOSTED_VAULT, amount);
        IBasedBoostedVault(BASED_BOOSTED_VAULT).deposit(msg.sender, asset, amount);
        vm.stopBroadcast();
    }

    function requestWithdrawal() public {
        uint256 amountInRay = 123456000000000000000000000;

        vm.startBroadcast();
        IBasedBoostedVault(BASED_BOOSTED_VAULT).requestWithdrawal(msg.sender, amountInRay);
        vm.stopBroadcast();
    }

    function executeWithdrawal() public {
        address asset = USDC;
        uint256 amountInRay = 123456000000000000000000000;

        vm.startBroadcast();
        IBasedBoostedVault(BASED_BOOSTED_VAULT).executeWithdrawal(msg.sender, asset, amountInRay, "");
        vm.stopBroadcast();
    }
}

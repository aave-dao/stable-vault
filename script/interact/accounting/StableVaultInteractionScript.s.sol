// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {AccountingChainBaseScript} from "script/interact/accounting/AccountingChainBaseScript.s.sol";

import {IStableVault} from "src/interfaces/IStableVault.sol";

/// @dev See example usage below:
/// 1. > export RPC_URL=<rpc-url>
/// 2. > cast wallet import <account_name> --private-key 0xYOUR_PRIVATE_KEY
/// 3. > forge script script/interact/accounting/StableVaultInteractionScript.s.sol \
///  --rpc-url $RPC_URL \
///  --sig "executeWithdrawal()" \
///  --account <account_name> \
///  --sender <account_address>
/// 4. > Add --broadcast to send the tx instead of simulating it.
/// 5. > Add --slow to force foundry to execute txs sequentially.
contract StableVaultInteractionScript is AccountingChainBaseScript {
    function deposit() public {
        address asset = GHO;
        uint256 amount = 8766 * 10 ** 18;

        vm.startBroadcast();
        IERC20(asset).approve(STABLE_VAULT, amount);
        IStableVault(STABLE_VAULT).deposit(msg.sender, asset, amount, "");
        vm.stopBroadcast();
    }

    function requestWithdrawal() public {
        uint256 amountInRay = 1 * 10 ** 27;

        vm.startBroadcast();
        IStableVault(STABLE_VAULT).requestWithdrawal(msg.sender, amountInRay, "");
        vm.stopBroadcast();
    }

    function executeWithdrawal() public {
        address asset = USDC;
        uint256 amountInRay = 1 * 10 ** 18;

        vm.startBroadcast();
        IStableVault(STABLE_VAULT).executeWithdrawal(msg.sender, asset, 0, amountInRay, "");
        vm.stopBroadcast();
    }

    function getAggregatedBalance() public view returns (uint256) {
        return IStableVault(STABLE_VAULT).getAggregatedBalance();
    }
}

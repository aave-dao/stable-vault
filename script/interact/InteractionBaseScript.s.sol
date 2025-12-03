// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract InteractionBaseScript is Script {
    /// @dev use the `--account <account_name>` flag to set the account to use
    /// @dev add an account to keystore with `cast wallet import <account_name> --private-key 0xYOUR_PRIVATE_KEY`
    function approveMax(address token, address spender) public virtual {
        vm.startBroadcast();
        IERC20(token).approve(spender, type(uint256).max);
        vm.stopBroadcast();
    }
}

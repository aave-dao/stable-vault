// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev See example usage below:
/// 1. > export RPC_URL=<rpc-url>
/// 2. > cast wallet import <account_name> --private-key 0xYOUR_PRIVATE_KEY
/// 3. > forge script script/interact/InteractionBaseScript.s.sol \
///  --rpc-url $RPC_URL \
///  --sig "approveMax(address,address)" <token_address> <spender_address> \
///  --account <account_name> \
///  --sender <account_address>
/// 4. > Add --broadcast to send the tx instead of simulating it.
contract InteractionBaseScript is Script {
    function approveMax(address token, address spender) public virtual {
        vm.startBroadcast();
        IERC20(token).approve(spender, type(uint256).max);
        vm.stopBroadcast();
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {InteractionBaseScript} from "script/interact/InteractionBaseScript.s.sol";

contract AccountingChainBaseScript is InteractionBaseScript {
    address constant USDC = address(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);
    address constant GHO = address(0x6Bb7a212910682DCFdbd5BCBb3e28FB4E8da10Ee);
    address constant LINK = address(0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196);
}

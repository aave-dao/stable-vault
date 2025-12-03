// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {InteractionBaseScript} from "script/interact/InteractionBaseScript.s.sol";

contract EarningChainBaseScript is InteractionBaseScript {
    address constant USDC = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address constant USDT = address(0xdAC17F958D2ee523a2206206994597C13D831ec7);
    address constant GHO = address(0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f);
    address constant LINK = address(0x514910771AF9Ca656af840dff83E8264EcF986CA);
}

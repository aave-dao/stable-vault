// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {InteractionBaseScript} from "script/interact/InteractionBaseScript.s.sol";

contract AccountingChainBaseScript is InteractionBaseScript {
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant USDT = 0x1217BfE6c773EEC6cc4A38b5Dc45B92292B6E189;
    address constant GHO = 0x6Bb7a212910682DCFdbd5BCBb3e28FB4E8da10Ee;
    address constant LINK = 0x88Fb150BDc53A65fe94Dea0c9BA0a6dAf8C6e196;

    address constant ALLOCATOR = 0x07623d7cb79B98ffceecEf180C3eC41ef0c90789;
    address constant BASED_BOOSTED_VAULT = 0xb49bD8C7fa9d910D77eF5A356CcFdF6A4ba14602;
    address constant FUNDS_HANDLER = 0xd2F851e7A5f4f43B3347376cd93824524A1b0187;
}

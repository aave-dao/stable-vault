// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {console} from "forge-std/console.sol";

/// @notice Helpers for deployment scripts to surface idempotency decisions in the foundry log so an operator running
/// `forge script` can see which txs were skipped because a prior run already applied them.
function logSkip(string memory ctx, string memory desc) pure {
    console.log(string.concat("[SKIPPED][", ctx, "] ", desc));
}

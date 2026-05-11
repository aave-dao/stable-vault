// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {IouTokenManager} from "src/core/ious/IouTokenManager.sol";

contract ExtendedIouTokenManager is IouTokenManager {
    constructor(address iouToken, address chainGateway, address vault, address transferHelper, bool isAccountingChain)
        IouTokenManager(iouToken, chainGateway, vault, transferHelper, isAccountingChain)
    {}

    function mockLockedBalance(uint256 lockedBalance) external {
        $IouTokenManager().lockedBalance = lockedBalance;
    }
}

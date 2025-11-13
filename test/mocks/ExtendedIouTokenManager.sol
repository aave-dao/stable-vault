// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IouTokenManager} from "../../src/common/IouTokenManager.sol";

contract ExtendedIouTokenManager is IouTokenManager {
    constructor(address iouToken, address chainGateway, address vault, address transferHelper, bool isCanonicalChain)
        IouTokenManager(iouToken, chainGateway, vault, transferHelper, isCanonicalChain)
    {}

    function mockLockedBalance(uint256 lockedBalance) external {
        $IouTokenManager().lockedBalance = lockedBalance;
    }
}

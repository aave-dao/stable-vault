// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

contract ExtendedAccessManager is AccessManager {
    uint32 internal constant EXPIRATION = 21 days;

    constructor(address initialAdmin) AccessManager(initialAdmin) {}

    /// @inheritdoc AccessManager
    /// @dev Extends the expiration time from 1 week to 21 days to provide sufficient time for timelocked functions.
    function expiration() public pure override returns (uint32) {
        return EXPIRATION;
    }
}

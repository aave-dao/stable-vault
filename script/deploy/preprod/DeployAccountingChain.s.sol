// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {AccountingChainDeployment} from "script/base/AccountingChainDeployment.sol";

contract DeployAccountingChain is AccountingChainDeployment {
    function _configPath() internal pure override returns (string memory) {
        return "config/deployment-config.preprod.jsonc";
    }
}

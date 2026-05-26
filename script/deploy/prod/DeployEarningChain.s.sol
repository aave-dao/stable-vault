// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {EarningChainDeployment} from "script/base/EarningChainDeployment.sol";

contract DeployEarningChain is EarningChainDeployment {
    function _configPath() internal pure override returns (string memory) {
        return "config/deployment-config.prod.jsonc";
    }
}

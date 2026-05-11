// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {Create3AddressBook} from "script/base/Create3AddressBook.sol";
import {Upgrade} from "script/base/Upgrade.sol";
import {WithdrawalExecutionPolicy} from "src/policies/WithdrawalExecutionPolicy.sol";

contract UpgradeWithdrawalExecutionPolicy is Create3AddressBook, Upgrade {
    using Strings for address;

    address WITHDRAWAL_EXECUTION_POLICY_PROXY;
    address DEPLOYER = 0xBB700dA5CCC9Ec5605780Fc40695f1206B090303;

    function run() public {
        WITHDRAWAL_EXECUTION_POLICY_PROXY = getWithdrawalExecutionPolicyAddress(DEPLOYER);

        vm.startBroadcast(DEPLOYER);
        _upgrade();
        vm.stopBroadcast();
    }

    function _upgrade() internal {
        address implementation = address(new WithdrawalExecutionPolicy(getStableVaultAddress(DEPLOYER)));
        _logDeployment("WithdrawalExecutionPolicy::Implementation", "", implementation);
        address proxyAdmin = _getAdminFromSlot(WITHDRAWAL_EXECUTION_POLICY_PROXY);
        ProxyAdmin(proxyAdmin)
            .upgradeAndCall(ITransparentUpgradeableProxy(WITHDRAWAL_EXECUTION_POLICY_PROXY), implementation, "");
    }

    function _logDeployment(string memory name, string memory saltSeed, address addr) internal {
        string memory jsonObject =
            string.concat('{ "address": "', addr.toHexString(), '", "saltSeed": "', saltSeed, '" }');
        vm.writeJson(jsonObject, "deployments/vnet/accounting.json", string.concat(".", name));
    }
}

// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {Create3AddressBook} from "script/base/Create3AddressBook.sol";
import {Upgrade} from "script/base/Upgrade.sol";
import {WithdrawalPolicy} from "src/periphery/WithdrawalPolicy.sol";

contract UpgradeWithdrawalPolicy is Create3AddressBook, Upgrade {
    using Strings for address;

    address WITHDRAWAL_POLICY_PROXY;
    address DEPLOYER = 0xBB700dA5CCC9Ec5605780Fc40695f1206B090303;

    function run() public {
        WITHDRAWAL_POLICY_PROXY = getWithdrawalPolicyAddress(DEPLOYER);

        vm.startBroadcast(DEPLOYER);
        _upgrade();
        vm.stopBroadcast();
    }

    function _upgrade() internal {
        address implementation = address(
            new WithdrawalPolicy({
                assetRegistry: getAssetRegistryAddress(DEPLOYER),
                withdrawalPolicyApplier: getBasedBoostedVaultAddress(DEPLOYER)
            })
        );
        _logDeployment("WithdrawalPolicy::Implementation", "", implementation);
        address proxyAdmin = _getAdminFromSlot(WITHDRAWAL_POLICY_PROXY);
        ProxyAdmin(proxyAdmin).upgradeAndCall(ITransparentUpgradeableProxy(WITHDRAWAL_POLICY_PROXY), implementation, "");
    }

    function _logDeployment(string memory name, string memory saltSeed, address addr) internal {
        string memory jsonObject =
            string.concat('{ "address": "', addr.toHexString(), '", "saltSeed": "', saltSeed, '" }');
        vm.writeJson(jsonObject, "deployments/vnet/accounting.json", string.concat(".", name));
    }
}

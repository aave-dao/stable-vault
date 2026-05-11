// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {Create3AddressBook} from "script/base/Create3AddressBook.sol";
import {Upgrade} from "script/base/Upgrade.sol";
import {StableVault} from "src/core/accounting/StableVault.sol";

contract UpgradeStableVault is Create3AddressBook, Upgrade {
    using Strings for address;

    address STABLE_VAULT_PROXY;
    address DEPLOYER = 0xBB700dA5CCC9Ec5605780Fc40695f1206B090303;
    address constant PROXY_ADMIN_OWNER = 0xBB700dA5CCC9Ec5605780Fc40695f1206B090303;

    uint256 constant DEFAULT_MAX_PER_SECOND_RATE = 1000000005781378656804591713; // ~20% APY
    uint256 constant DEFAULT_MAX_ACTIVE_SUB_VAULTS = 201;

    function run() public {
        STABLE_VAULT_PROXY = getStableVaultAddress(DEPLOYER);

        vm.startBroadcast(DEPLOYER);
        _upgrade();
        vm.stopBroadcast();
    }

    function _upgrade() internal {
        address implementation = address(
            new StableVault({
                maxValidPerSecondRate: DEFAULT_MAX_PER_SECOND_RATE,
                assetRegistry: getAssetRegistryAddress(DEPLOYER),
                iouTokenManager: getIouTokenManagerAddress(DEPLOYER),
                fundsHandler: getFundsHandlerAddress(DEPLOYER),
                transferHelper: getTransferHelperAddress(DEPLOYER),
                withdrawalExecutionPolicy: getWithdrawalExecutionPolicyAddress(DEPLOYER),
                priceOracle: address(0), // TODO: Deploy Price Oracle properly
                maxActiveSubVaults: DEFAULT_MAX_ACTIVE_SUB_VAULTS,
                policyRegistry: getPolicyRegistryAddress(DEPLOYER)
            })
        );
        _logDeployment("StableVault::Implementation", "", implementation);
        address proxyAdmin = _getAdminFromSlot(STABLE_VAULT_PROXY);
        ProxyAdmin(proxyAdmin).upgradeAndCall(ITransparentUpgradeableProxy(STABLE_VAULT_PROXY), implementation, "");
    }

    function _logDeployment(string memory name, string memory saltSeed, address addr) internal {
        string memory jsonObject =
            string.concat('{ "address": "', addr.toHexString(), '", "saltSeed": "', saltSeed, '" }');
        vm.writeJson(jsonObject, "deployments/vnet/accounting.json", string.concat(".", name));
    }
}

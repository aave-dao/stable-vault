// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {BasedBoostedVault} from "src/core/accounting/BasedBoostedVault.sol";

contract UpgradeBasedBoostedVault is Script {
    using Strings for address;

    // EIP-1967 implementation slot: bytes32(uint256(keccak256('eip1967.proxy.implementation')) - 1)
    bytes32 constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    // This is the keccak-256 hash of "eip1967.proxy.admin" subtracted by 1.
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    // Existing proxy and admin addresses (from deployments/vnet/accounting.json)
    address constant BASED_BOOSTED_VAULT_PROXY = 0xb49bD8C7fa9d910D77eF5A356CcFdF6A4ba14602;
    address DEPLOYER = 0xBB700dA5CCC9Ec5605780Fc40695f1206B090303;
    address constant PROXY_ADMIN_OWNER = 0xBB700dA5CCC9Ec5605780Fc40695f1206B090303;

    // Immutable constructor parameters (must match original deployment)
    uint256 constant DEFAULT_MAX_PER_SECOND_RATE = 1000000005781378656804591713; // ~20% APY
    address constant ASSET_REGISTRY = 0xB0b9a4b122CfF529b6dC4f93E0B9496aFafAef3B;
    address constant IOU_TOKEN_MANAGER = 0x14fC7C26e112ac6f7ed7E5b6Adcb795562FDaf10;
    address constant FUNDS_HANDLER = 0xd2F851e7A5f4f43B3347376cd93824524A1b0187;
    address constant TRANSFER_HELPER = 0x9C0d4c4e85dF91a16b79b405676f289cDb06632B;
    address constant WITHDRAWAL_POLICY = 0x96Ec72Dd6a226c9FC2187F00b65f41851FF2643C;
    uint256 constant DEFAULT_MAX_ACTIVE_SUB_VAULTS = 201;

    function run() public {
        vm.startBroadcast(DEPLOYER);
        _upgrade();
        vm.stopBroadcast();
    }

    function _upgrade() internal {
        address implementation = address(
            new BasedBoostedVault({
                maxValidPerSecondRate: DEFAULT_MAX_PER_SECOND_RATE,
                assetRegistry: ASSET_REGISTRY,
                iouTokenManager: IOU_TOKEN_MANAGER,
                fundsHandler: FUNDS_HANDLER,
                transferHelper: TRANSFER_HELPER,
                withdrawalPolicy: WITHDRAWAL_POLICY,
                maxActiveSubVaults: DEFAULT_MAX_ACTIVE_SUB_VAULTS
            })
        );
        _logDeployment("BasedBoostedVault::Implementation", "", implementation);
        address proxyAdmin = _getAdminFromSlot(BASED_BOOSTED_VAULT_PROXY);
        ProxyAdmin(proxyAdmin)
            .upgradeAndCall(ITransparentUpgradeableProxy(BASED_BOOSTED_VAULT_PROXY), implementation, "");
    }

    function _logDeployment(string memory name, string memory saltSeed, address addr) internal {
        string memory jsonObject =
            string.concat('{ "address": "', addr.toHexString(), '", "saltSeed": "', saltSeed, '" }');
        vm.writeJson(jsonObject, "deployments/vnet/accounting.json", string.concat(".", name));
    }

    /// @notice Get the current implementation address by reading EIP-1967 storage slot
    function getCurrentImplementation() public view returns (address) {
        return _getImplementationFromSlot(BASED_BOOSTED_VAULT_PROXY);
    }

    /// @notice Read implementation address directly from EIP-1967 storage slot
    /// @param proxy The proxy contract address
    /// @return impl The implementation address stored in the proxy
    function _getImplementationFromSlot(address proxy) internal view returns (address impl) {
        bytes32 slot = vm.load(proxy, IMPLEMENTATION_SLOT);
        impl = address(uint160(uint256(slot)));
    }

    function _getAdminFromSlot(address proxy) internal view returns (address admin) {
        bytes32 slot = vm.load(proxy, ADMIN_SLOT);
        admin = address(uint160(uint256(slot)));
    }
}


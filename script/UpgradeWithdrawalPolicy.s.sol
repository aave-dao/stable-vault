// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";

import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {WithdrawalPolicy} from "src/periphery/WithdrawalPolicy.sol";

contract UpgradeWithdrawalPolicy is Script {
    using Strings for address;

    // EIP-1967 implementation slot: bytes32(uint256(keccak256('eip1967.proxy.implementation')) - 1)
    bytes32 constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    // This is the keccak-256 hash of "eip1967.proxy.admin" subtracted by 1.
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    // Existing proxy and admin addresses (from deployments/vnet/accounting.json)
    address constant WITHDRAWAL_POLICY_PROXY = 0x96Ec72Dd6a226c9FC2187F00b65f41851FF2643C;
    address DEPLOYER = 0xBB700dA5CCC9Ec5605780Fc40695f1206B090303;

    // Immutable constructor parameters (must match original deployment)
    address constant ASSET_REGISTRY = 0xB0b9a4b122CfF529b6dC4f93E0B9496aFafAef3B;

    function run() public {
        vm.startBroadcast(DEPLOYER);
        _upgrade();
        vm.stopBroadcast();
    }

    function _upgrade() internal {
        address implementation = address(new WithdrawalPolicy({assetRegistry: ASSET_REGISTRY}));
        _logDeployment("WithdrawalPolicy::Implementation", "", implementation);
        address proxyAdmin = _getAdminFromSlot(WITHDRAWAL_POLICY_PROXY);
        ProxyAdmin(proxyAdmin).upgradeAndCall(ITransparentUpgradeableProxy(WITHDRAWAL_POLICY_PROXY), implementation, "");
    }

    function _logDeployment(string memory name, string memory saltSeed, address addr) internal {
        string memory jsonObject =
            string.concat('{ "address": "', addr.toHexString(), '", "saltSeed": "', saltSeed, '" }');
        vm.writeJson(jsonObject, "deployments/vnet/accounting.json", string.concat(".", name));
    }

    /// @notice Get the current implementation address by reading EIP-1967 storage slot
    function getCurrentImplementation() public view returns (address) {
        return _getImplementationFromSlot(WITHDRAWAL_POLICY_PROXY);
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


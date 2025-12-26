// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {Script} from "forge-std/Script.sol";

contract Upgrade is Script {
    // EIP-1967 implementation slot: bytes32(uint256(keccak256('eip1967.proxy.implementation')) - 1)
    bytes32 constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    // This is the keccak-256 hash of "eip1967.proxy.admin" subtracted by 1.
    bytes32 internal constant ADMIN_SLOT = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;

    /// @notice Read implementation address directly from EIP-1967 storage slot
    /// @param proxy The proxy contract address
    /// @return impl The implementation address stored in the proxy
    function _getImplementationFromSlot(address proxy) internal view returns (address impl) {
        bytes32 slot = vm.load(proxy, IMPLEMENTATION_SLOT);
        impl = address(uint160(uint256(slot)));
    }

    /// @notice Read admin address directly from EIP-1967 storage slot
    /// @param proxy The proxy contract address
    /// @return admin The admin address stored in the proxy
    function _getAdminFromSlot(address proxy) internal view returns (address admin) {
        bytes32 slot = vm.load(proxy, ADMIN_SLOT);
        admin = address(uint160(uint256(slot)));
    }
}

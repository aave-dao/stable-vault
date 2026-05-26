// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

library ATokenVaultProxyAddressLib {
    /// @dev Computes the address of the first contract deployed by `proxyDeployer` via CREATE.
    /// New contracts start with nonce 1, so this is the CREATE address for
    /// `keccak256(rlp([proxyDeployer, 1]))`, encoded as `0xd6 0x94 <proxyDeployer> 0x01`.
    function computeProxyAddress(address proxyDeployer) internal pure returns (address) {
        return
            address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xd6), bytes1(0x94), proxyDeployer, bytes1(0x01)))))
            );
    }
}

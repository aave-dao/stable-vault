// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library Create3AddressLib {
    /// @notice @pcaversaccio/createx's address
    /// @dev Used as CREATE3 factory for deterministic deployments, not depending on the init code.
    address constant CREATEX_ADDRESS = address(0xba5Ed099633D3B313e4D5F7bdc1305d3c28ba5Ed);

    bytes32 internal constant DEPLOYER_ADDRESS_ZEROING_MASK =
        bytes32(0x0000000000000000000000000000000000000000ffffffffffffffffffffffff);

    bytes32 internal constant CROSS_CHAIN_PROTECTION_MASK =
        bytes32(0xffffffffffffffffffffffffffffffffffffffff00ffffffffffffffffffffff);

    uint256 internal constant BITS_TO_SHIFT_DEPLOYER_ADDRESS = 96;

    function computeCreate3Address(string memory namespacedSaltSeed, address deployer) internal pure returns (address) {
        address createxAddress = CREATEX_ADDRESS;
        bytes32 create3GuardedSalt = _computeCreate3GuardedSalt(namespacedSaltSeed, deployer);
        address computedAddress;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(0x00, createxAddress)
            mstore8(0x0b, 0xff)
            mstore(0x20, create3GuardedSalt)
            mstore(0x40, hex"21c35dbe1b344a2488cf3321d6ce542f8e9f305544ff09e4993a62319a497c1f")
            mstore(0x14, keccak256(0x0b, 0x55))
            mstore(0x40, ptr)
            mstore(0x00, 0xd694)
            mstore8(0x34, 0x01)
            computedAddress := keccak256(0x1e, 0x17)
        }
        return computedAddress;
    }

    /// @notice Computes the CREATE3 salt for a deterministic deployment.
    /// @dev The salt computed has deployed-based protection and cross-chain protection enabled.
    /// @param namespacedSaltSeed The namespaced salt seed.
    /// @param deployer The deployer address.
    /// @return The computed CREATE3 salt.
    function computeCreate3Salt(string memory namespacedSaltSeed, address deployer) internal pure returns (bytes32) {
        return (keccak256(abi.encodePacked(namespacedSaltSeed))
                & DEPLOYER_ADDRESS_ZEROING_MASK
                & CROSS_CHAIN_PROTECTION_MASK) | bytes32(uint256(uint160(deployer)) << BITS_TO_SHIFT_DEPLOYER_ADDRESS);
    }

    /////////////////////////////////////////// PRIVATE HELPERS ///////////////////////////////////////////

    function _efficientHash(bytes32 a, bytes32 b) private pure returns (bytes32 hash) {
        assembly ("memory-safe") {
            mstore(0x00, a)
            mstore(0x20, b)
            hash := keccak256(0x00, 0x40)
        }
    }

    function _computeCreate3GuardedSalt(string memory namespacedSaltSeed, address deployer)
        private
        pure
        returns (bytes32)
    {
        return _efficientHash({
            a: bytes32(uint256(uint160(deployer))), b: computeCreate3Salt(namespacedSaltSeed, deployer)
        });
    }
}

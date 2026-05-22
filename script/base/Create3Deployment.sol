// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {ICreateX} from "@pcaversaccio/createx/ICreateX.sol";

import {Create3AddressLib} from "script/libraries/Create3AddressLib.sol";

contract Create3Deployment {
    ICreateX CREATE3_FACTORY = ICreateX(Create3AddressLib.CREATEX_ADDRESS);

    function _deployTransparentProxy_create3(
        string memory namespacedSaltSeed,
        address deployer,
        address implementation,
        address proxyAdminOwner,
        bytes memory initCalldata
    ) internal returns (address) {
        address predicted = Create3AddressLib.computeCreate3Address(namespacedSaltSeed, deployer);
        if (predicted.code.length != 0) {
            return predicted;
        }
        return CREATE3_FACTORY.deployCreate3({
            salt: Create3AddressLib.computeCreate3Salt(namespacedSaltSeed, deployer),
            initCode: abi.encodePacked(
                type(TransparentUpgradeableProxy).creationCode,
                abi.encode(implementation, proxyAdminOwner, initCalldata)
            )
        });
    }

    function _deploy_create3(string memory namespacedSaltSeed, address deployer, bytes memory initCode)
        internal
        returns (address)
    {
        address predicted = Create3AddressLib.computeCreate3Address(namespacedSaltSeed, deployer);
        if (predicted.code.length != 0) {
            return predicted;
        }
        return CREATE3_FACTORY.deployCreate3({
            salt: Create3AddressLib.computeCreate3Salt(namespacedSaltSeed, deployer), initCode: initCode
        });
    }

    /// @dev Reverts if the deployed runtime code at `addr` does not match `expectedRuntimeCodeHash`. Pass
    /// `keccak256(type(X).runtimeCode)` for contracts without immutables; for contracts with immutables the deployed
    /// code differs from the template, so this check is not applicable and callers should fall back to a presence
    /// check.
    function _assertDeployedRuntimeCode(address addr, bytes32 expectedRuntimeCodeHash, string memory name)
        internal
        view
    {
        require(
            keccak256(addr.code) == expectedRuntimeCodeHash,
            string.concat(name, " at ", Strings.toHexString(addr), ": deployed runtime code hash mismatch")
        );
    }
}

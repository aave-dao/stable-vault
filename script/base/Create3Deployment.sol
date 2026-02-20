// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
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
        return CREATE3_FACTORY.deployCreate3({
            salt: Create3AddressLib.computeCreate3Salt(namespacedSaltSeed, deployer), initCode: initCode
        });
    }
}

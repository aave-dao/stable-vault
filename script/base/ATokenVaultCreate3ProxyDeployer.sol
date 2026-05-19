// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ATokenVaultProxyAddressLib} from "script/libraries/ATokenVaultProxyAddressLib.sol";

contract ATokenVaultCreate3ProxyDeployer {
    using SafeERC20 for IERC20;

    address public immutable proxy;

    constructor(
        address underlying,
        address implementation,
        address proxyAdminOwner,
        bytes memory initCalldata,
        address depositor,
        uint256 initialLockDeposit
    ) {
        address proxyAddress = ATokenVaultProxyAddressLib.computeProxyAddress(address(this));

        IERC20(underlying).safeTransferFrom(depositor, address(this), initialLockDeposit);
        IERC20(underlying).forceApprove(proxyAddress, initialLockDeposit);

        proxy = address(new TransparentUpgradeableProxy(implementation, proxyAdminOwner, initCalldata));
        require(proxy == proxyAddress, "aTokenVault proxy address mismatch");
    }
}

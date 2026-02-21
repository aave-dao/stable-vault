// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";

import {IPoolAddressesProvider} from "@aave-v3-core/interfaces/IPoolAddressesProvider.sol";
import {ATokenVault} from "@aave-vault/ATokenVault.sol";
import {ATokenVaultMerklRewardClaimer} from "@aave-vault/ATokenVaultMerklRewardClaimer.sol";

contract ATokenVaultDeployment {
    using SafeERC20 for IERC20;

    function _deployATokenVault(address underlying, address poolAddressProvider, address owner)
        internal
        returns (address vault)
    {
        uint256 initialLockDeposit = 10 ** IERC20Metadata(underlying).decimals();

        address implementation =
            address(new ATokenVaultMerklRewardClaimer(underlying, 0, IPoolAddressesProvider(poolAddressProvider)));

        bytes memory initCalldata = abi.encodeCall(
            ATokenVault.initialize,
            (
                owner,
                0,
                string(abi.encodePacked("StableVault's ", IERC20Metadata(underlying).name())),
                string(abi.encodePacked("StableVault/", IERC20Metadata(underlying).symbol())),
                initialLockDeposit
            )
        );

        bytes32 salt = keccak256(abi.encode(underlying));
        bytes memory creationCode = abi.encodePacked(
            type(TransparentUpgradeableProxy).creationCode, abi.encode(implementation, owner, initCalldata)
        );

        vault = Create2.computeAddress(salt, keccak256(creationCode));
        IERC20(underlying).forceApprove(vault, initialLockDeposit);

        new TransparentUpgradeableProxy{salt: salt}(implementation, owner, initCalldata);
    }
}

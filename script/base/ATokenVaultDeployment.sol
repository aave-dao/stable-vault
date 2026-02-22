// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IPoolAddressesProvider} from "@aave-v3-core/interfaces/IPoolAddressesProvider.sol";
import {ATokenVault} from "@aave-vault/ATokenVault.sol";
import {ATokenVaultMerklRewardClaimer} from "@aave-vault/ATokenVaultMerklRewardClaimer.sol";

contract ATokenVaultDeployment is Script {
    using SafeERC20 for IERC20;

    function _deployATokenVault(address underlying, address poolAddressProvider, address owner, address deployer)
        internal
        returns (address)
    {
        uint256 initialLockDeposit = 10 ** IERC20Metadata(underlying).decimals();

        address implementation =
            address(new ATokenVaultMerklRewardClaimer(underlying, 0, IPoolAddressesProvider(poolAddressProvider)));

        // Compute proxy address: approve call consumes a nonce, then proxy deploy consumes the next.
        uint64 proxyNonce = vm.getNonce(deployer) + 1;
        address vaultAddress = vm.computeCreateAddress(deployer, proxyNonce);

        IERC20(underlying).forceApprove(vaultAddress, initialLockDeposit);

        bytes memory initCalldata = abi.encodeCall(
            ATokenVault.initialize,
            (
                owner,
                0,
                // TODO: Consider another name for prod deployment
                string(abi.encodePacked("StableVault's ", IERC20Metadata(underlying).name())),
                // TODO: Consider another symbol for prod deployment
                string(abi.encodePacked("StableVault/", IERC20Metadata(underlying).symbol())),
                initialLockDeposit
            )
        );

        address proxyAddress = address(new TransparentUpgradeableProxy(implementation, owner, initCalldata));

        require(proxyAddress == vaultAddress, "aTokenVault address does not match expected address");

        return proxyAddress;
    }
}

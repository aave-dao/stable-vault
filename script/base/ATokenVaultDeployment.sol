// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract ATokenVaultDeployment {
    using SafeERC20 for IERC20;

    IATokenVaultFactory ATOKEN_VAULT_FACTORY = IATokenVaultFactory(0xa35995bb2fFC5F2b33379C2e95d00C20FbF71E70);

    function _deployATokenVault(address underlying, address poolAddressProvider, address owner)
        internal
        returns (address vault)
    {
        uint256 initialLockDeposit = 10 ** IERC20Metadata(underlying).decimals();
        IERC20(underlying).forceApprove(address(ATOKEN_VAULT_FACTORY), initialLockDeposit);
        IATokenVaultFactory.VaultParams memory params = IATokenVaultFactory.VaultParams({
            underlying: underlying,
            referralCode: 0,
            poolAddressesProvider: poolAddressProvider,
            owner: owner,
            initialFee: 0,
            shareName: string(abi.encodePacked("StableVault's ", IERC20Metadata(underlying).name())),
            shareSymbol: string(abi.encodePacked("StableVault/", IERC20Metadata(underlying).symbol())),
            initialLockDeposit: initialLockDeposit,
            revenueRecipients: new IATokenVaultFactory.Recipient[](0)
        });
        return ATOKEN_VAULT_FACTORY.deployVault(params);
    }
}

interface IATokenVaultFactory {
    struct Recipient {
        address addr;
        uint16 shareInBps;
    }

    struct VaultParams {
        address underlying;
        uint16 referralCode;
        address poolAddressesProvider;
        address owner;
        uint256 initialFee;
        string shareName;
        string shareSymbol;
        uint256 initialLockDeposit;
        Recipient[] revenueRecipients;
    }

    function deployVault(VaultParams memory params) external returns (address vault);
}

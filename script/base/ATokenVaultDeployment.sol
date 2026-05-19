// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICreateX} from "@pcaversaccio/createx/ICreateX.sol";

import {ATokenVault} from "@aave-vault/ATokenVault.sol";
import {ATokenVaultCreate3ProxyDeployer} from "script/base/ATokenVaultCreate3ProxyDeployer.sol";
import {ATokenVaultProxyAddressLib} from "script/libraries/ATokenVaultProxyAddressLib.sol";
import {Create3AddressLib} from "script/libraries/Create3AddressLib.sol";

abstract contract ATokenVaultDeployment is Script {
    using SafeERC20 for IERC20;

    struct ATokenVaultEntry {
        address addr;
        string assetSymbol;
    }

    string[] internal _aTokenVaultAssets;
    address[] internal _aTokenVaultDeployedAddresses;

    function _deployATokenVault(address underlying, address poolAddressProvider, address owner, address deployer)
        internal
        returns (address)
    {
        // One unit of the underlying asset.
        uint256 initialLockDeposit = 1 * 10 ** IERC20Metadata(underlying).decimals();

        string memory proxyDeployerSaltSeed = _aTokenVaultProxyDeployerSaltSeed(underlying);
        address proxyDeployerAddress = Create3AddressLib.computeCreate3Address(proxyDeployerSaltSeed, deployer);
        address vaultAddress = ATokenVaultProxyAddressLib.computeProxyAddress(proxyDeployerAddress);
        if (vaultAddress.code.length != 0) {
            _trackATokenVaultDeployment(underlying, vaultAddress);
            _logATokenVaultDeployments();
            return vaultAddress;
        }
        require(proxyDeployerAddress.code.length == 0, "aTokenVault proxy deployer already deployed");

        // Do not import `ATokenVaultMerklRewardClaimer` contract here, as it will force the entire set of dependencies
        // of this contract (and any other contract using it) to be compiled with the size-optimized profile.
        // Instead, we deploy manually reading the bytecode from the compiled artifact.
        // See `CompileATokenVaultMerklRewardClaimer.sol` for more details.
        address implementation;
        {
            string memory artifactPath = "out/ATokenVaultMerklRewardClaimer.sol/ATokenVaultMerklRewardClaimer.json";
            // forge-lint: disable-next-line(unsafe-cheatcode)
            string memory artifact = vm.readFile(artifactPath);
            bytes memory initCode = abi.encodePacked(
                vm.parseJsonBytes(artifact, ".bytecode.object"), abi.encode(underlying, uint16(0), poolAddressProvider)
            );
            assembly {
                implementation := create(0, add(initCode, 0x20), mload(initCode))
            }
            require(implementation != address(0), "ATokenVaultMerklRewardClaimer deployment failed");
        }

        bytes memory initCalldata = abi.encodeCall(
            ATokenVault.initialize,
            (
                owner,
                0,
                // TODO(naming): finalize the aToken-vault name for prod; current value is a dev placeholder derived
                // from the underlying.
                string(abi.encodePacked("StableVault's ", IERC20Metadata(underlying).name())),
                // TODO(naming): finalize the aToken-vault symbol for prod; current value is a dev placeholder derived
                // from the underlying.
                string(abi.encodePacked("StableVault/", IERC20Metadata(underlying).symbol())),
                initialLockDeposit
            )
        );

        IERC20(underlying).forceApprove(proxyDeployerAddress, initialLockDeposit);

        bytes memory proxyDeployerInitCode = abi.encodePacked(
            type(ATokenVaultCreate3ProxyDeployer).creationCode,
            abi.encode(underlying, implementation, owner, initCalldata, deployer, initialLockDeposit)
        );
        bytes32 proxyDeployerSalt = Create3AddressLib.computeCreate3Salt(proxyDeployerSaltSeed, deployer);
        address proxyDeployer = ICreateX(Create3AddressLib.CREATEX_ADDRESS)
            .deployCreate3({salt: proxyDeployerSalt, initCode: proxyDeployerInitCode});
        require(proxyDeployer == proxyDeployerAddress, "aTokenVault proxy deployer address mismatch");

        _trackATokenVaultDeployment(underlying, vaultAddress);
        _logATokenVaultDeployments();

        return vaultAddress;
    }

    function _trackATokenVaultDeployment(address underlying, address vaultAddress) private {
        string memory symbol = IERC20Metadata(underlying).symbol();
        bool found = false;
        for (uint256 i = 0; i < _aTokenVaultAssets.length; i++) {
            if (keccak256(bytes(_aTokenVaultAssets[i])) == keccak256(bytes(symbol))) {
                _aTokenVaultDeployedAddresses[i] = vaultAddress;
                found = true;
                break;
            }
        }
        if (!found) {
            _aTokenVaultAssets.push(symbol);
            _aTokenVaultDeployedAddresses.push(vaultAddress);
        }
    }

    function _logATokenVaultDeployments() internal virtual {}

    function _aTokenVaultProxyDeployerSaltSeed(address underlying) internal pure virtual returns (string memory);

    function _buildATokenVaultsJson() internal returns (string memory) {
        string memory json = "[";
        for (uint256 i = 0; i < _aTokenVaultDeployedAddresses.length; i++) {
            if (i > 0) {
                json = string.concat(json, ",");
            }
            string memory key = string.concat("aTokenVault", vm.toString(i));
            vm.serializeString(key, "assetSymbol", _aTokenVaultAssets[i]);
            string memory element = vm.serializeAddress(key, "address", _aTokenVaultDeployedAddresses[i]);
            json = string.concat(json, element);
        }
        return string.concat(json, "]");
    }

    function _readATokenVaultAddresses(string memory outputPath) internal view returns (address[] memory) {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile(outputPath);
        bytes memory raw = vm.parseJson(json, ".aTokenVaults");
        ATokenVaultEntry[] memory entries = abi.decode(raw, (ATokenVaultEntry[]));
        address[] memory addresses = new address[](entries.length);
        for (uint256 i = 0; i < entries.length; i++) {
            addresses[i] = entries[i].addr;
        }
        return addresses;
    }
}

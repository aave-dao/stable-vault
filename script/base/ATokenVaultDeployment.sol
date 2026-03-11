// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {ATokenVault} from "@aave-vault/ATokenVault.sol";

contract ATokenVaultDeployment is Script {
    using SafeERC20 for IERC20;
    using Strings for address;

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

        string memory symbol = IERC20Metadata(underlying).symbol();
        bool found = false;
        for (uint256 i = 0; i < _aTokenVaultAssets.length; i++) {
            if (keccak256(bytes(_aTokenVaultAssets[i])) == keccak256(bytes(symbol))) {
                _aTokenVaultDeployedAddresses[i] = proxyAddress;
                found = true;
                break;
            }
        }
        if (!found) {
            _aTokenVaultAssets.push(symbol);
            _aTokenVaultDeployedAddresses.push(proxyAddress);
        }

        _logATokenVaultDeployments();

        return proxyAddress;
    }

    function _logATokenVaultDeployments() internal virtual {}

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

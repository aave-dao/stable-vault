// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";

import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {ProxyAdmin} from "@openzeppelin/contracts/proxy/transparent/ProxyAdmin.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ICreateX} from "@pcaversaccio/createx/ICreateX.sol";

import {ATokenVault} from "@aave-vault/ATokenVault.sol";
import {ATokenVaultCreate3ProxyDeployer} from "script/base/ATokenVaultCreate3ProxyDeployer.sol";
import {ATokenVaultProxyAddressLib} from "script/libraries/ATokenVaultProxyAddressLib.sol";
import {Create3AddressLib} from "script/libraries/Create3AddressLib.sol";
import {logSkip} from "script/libraries/DeploymentLogLib.sol";

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
            /// @custom:tx-already-executed-check Predicted vault address (derived from the CREATE3 proxy-deployer)
            /// already has code — a prior run deployed both the impl and the proxy via the proxy-deployer contract.
            /// Validate that what's deployed matches what this run would produce before accepting it; a partial /
            /// stale prior deploy with different constructor args (different impl, owner, or underlying) must surface
            /// as a hard error rather than silently get reused.
            address expectedImpl = _deployATokenVaultMerklRewardClaimerImpl(underlying, poolAddressProvider, deployer);
            _assertExistingATokenVault(vaultAddress, proxyDeployerAddress, expectedImpl, owner, underlying);
            logSkip("_deployATokenVault", "aTokenVault already deployed for underlying");
            _trackATokenVaultDeployment(underlying, vaultAddress);
            _logATokenVaultDeployments();
            return vaultAddress;
        }
        require(
            proxyDeployerAddress.code.length == 0,
            "aTokenVault proxy-deployer (CREATE3 helper contract) address unexpectedly has code"
        );

        // Do not import `ATokenVaultMerklRewardClaimer` contract here, as it will force the entire set of dependencies
        // of this contract (and any other contract using it) to be compiled with the size-optimized profile.
        // Instead, we deploy manually reading the bytecode from the compiled artifact.
        // See `CompileATokenVaultMerklRewardClaimer.sol` for more details.
        //
        // CREATE3-deploy so the impl address is deterministic across re-runs (otherwise its address depends on
        // deployer nonce, which would cascade into a different ATokenVaultCreate3ProxyDeployer address since the impl
        // is encoded into its constructor args).
        address implementation = _deployATokenVaultMerklRewardClaimerImpl(underlying, poolAddressProvider, deployer);

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
        require(
            proxyDeployer == proxyDeployerAddress,
            "aTokenVault proxy-deployer (CREATE3 helper contract) deployed at unexpected address"
        );

        _trackATokenVaultDeployment(underlying, vaultAddress);
        _logATokenVaultDeployments();

        return vaultAddress;
    }

    function _deployATokenVaultMerklRewardClaimerImpl(address underlying, address poolAddressProvider, address deployer)
        private
        returns (address)
    {
        string memory implSaltSeed = _aTokenVaultMerklRewardClaimerImplSaltSeed(underlying);
        address predictedImpl = Create3AddressLib.computeCreate3Address(implSaltSeed, deployer);
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory artifact = vm.readFile("out/ATokenVaultMerklRewardClaimer.sol/ATokenVaultMerklRewardClaimer.json");
        bytes memory implInitCode = abi.encodePacked(
            vm.parseJsonBytes(artifact, ".bytecode.object"), abi.encode(underlying, uint16(0), poolAddressProvider)
        );
        if (predictedImpl.code.length != 0) {
            /// @custom:tx-already-executed-check Predicted address has code.
            _assertATokenVaultMerklRewardClaimerImplBytecode(predictedImpl, implInitCode);
            logSkip(
                "_deployATokenVaultMerklRewardClaimerImpl",
                "ATokenVaultMerklRewardClaimer impl already deployed for underlying"
            );
            return predictedImpl;
        }
        address implementation = ICreateX(Create3AddressLib.CREATEX_ADDRESS)
            .deployCreate3({salt: Create3AddressLib.computeCreate3Salt(implSaltSeed, deployer), initCode: implInitCode});
        require(implementation == predictedImpl, "ATokenVaultMerklRewardClaimer impl address mismatch");
        return implementation;
    }

    /// @dev Reference-deploys the claimer impl with the same init code and compares bytecode. Defined as an abstract
    /// hook so the concrete check (and broadcast pause) lives on `BaseChainDeployment`, which holds the broadcast
    /// state flag; here we don't want to take a dependency on that contract.
    function _assertATokenVaultMerklRewardClaimerImplBytecode(address actual, bytes memory implInitCode)
        internal
        virtual;

    /// @dev Sanity-checks an already-deployed aTokenVault on the idempotency skip path. Covers the cases that a bare
    /// `vaultAddress.code.length != 0` test misses: stale prior deploy with a different impl, owner, or underlying.
    /// Impl bytecode is verified separately by the caller via `_deployATokenVaultMerklRewardClaimerImpl` (which itself
    /// reference-deploys and compares runtime code), so here we only need to confirm the proxy points at it.
    function _assertExistingATokenVault(
        address vaultAddress,
        address proxyDeployerAddress,
        address expectedImpl,
        address expectedOwner,
        address expectedUnderlying
    ) private view {
        require(
            proxyDeployerAddress.code.length != 0,
            "aTokenVault proxy-deployer (CREATE3 helper contract) has no code; vault deploy state is inconsistent"
        );
        require(
            ATokenVaultCreate3ProxyDeployer(proxyDeployerAddress).proxy() == vaultAddress,
            "aTokenVault proxy-deployer.proxy() does not match predicted vault address"
        );

        address actualImpl = address(uint160(uint256(vm.load(vaultAddress, ERC1967Utils.IMPLEMENTATION_SLOT))));
        require(
            actualImpl == expectedImpl, "aTokenVault ERC-1967 implementation slot does not match expected impl address"
        );

        address admin = address(uint160(uint256(vm.load(vaultAddress, ERC1967Utils.ADMIN_SLOT))));
        require(admin != address(0), "aTokenVault ERC-1967 admin slot is zero");
        require(
            ProxyAdmin(admin).owner() == expectedOwner,
            "aTokenVault ProxyAdmin.owner() does not match expected owner (AccessManager)"
        );

        require(
            ATokenVault(vaultAddress).asset() == expectedUnderlying,
            "aTokenVault.asset() does not match expected underlying"
        );
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

    /// @dev Predicted aTokenVault proxy address for `underlying`, matching the CREATE3-derived address used by
    /// `_deployATokenVault`. `deployer` is the broadcasting EOA whose CREATE3 namespace produces the per-vault
    /// `ATokenVaultCreate3ProxyDeployer` contract (a separate, throwaway deployer used to give the vault proxy a
    /// deterministic address). Returns the address regardless of whether the vault has actually been deployed yet;
    /// callers should check `.code.length` to determine that.
    function _predictedATokenVaultAddress(address underlying, address deployer) internal pure returns (address) {
        address aTokenVaultProxyDeployerAddress =
            Create3AddressLib.computeCreate3Address(_aTokenVaultProxyDeployerSaltSeed(underlying), deployer);
        return ATokenVaultProxyAddressLib.computeProxyAddress(aTokenVaultProxyDeployerAddress);
    }

    function _aTokenVaultMerklRewardClaimerImplSaltSeed(address underlying)
        internal
        pure
        virtual
        returns (string memory);

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
        // Read from the deployment output so interrupted scripts can be resumed and still wire every previously
        // recorded aTokenVault target.
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

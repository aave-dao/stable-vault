// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {DeployAccountingChain} from "script/deploy/preprod/DeployAccountingChain.s.sol";
import {DeployEarningChain} from "script/deploy/preprod/DeployEarningChain.s.sol";

/// @dev Earning-chain preprod deploy wrapped for fork tests: exposes deterministic CREATE3 addresses and redirects
/// the deployment output JSON to a throwaway path so a run never mutates the tracked deployments/preprod/v1 files.
contract EarningChainForkHarness is DeployEarningChain {
    string private _outputOverride;

    /// @notice Seed `throwawayPath` from the tracked deployment JSON (so mid-run aTokenVault reads resolve) and route
    /// every subsequent deployment write there. Call before `run()`.
    function redirectOutputTo(string memory throwawayPath) external {
        vm.writeFile(throwawayPath, vm.readFile(super._deploymentOutputPath()));
        _outputOverride = throwawayPath;
    }

    function _deploymentOutputPath() internal view override returns (string memory) {
        return bytes(_outputOverride).length == 0 ? super._deploymentOutputPath() : _outputOverride;
    }

    function deployerAddr() external view returns (address) {
        return _deployer();
    }

    function accessManagerAddr() external view returns (address) {
        return getAccessManagerAddress(_deployer());
    }

    function adiAdapterAddr() external view returns (address) {
        return getAdiAdapterAddress(_deployer());
    }

    function adiCccAddr() external view returns (address) {
        return _adiCrossChainController();
    }

    function gatewayAddr() external view returns (address) {
        return getGatewayAddress(_deployer());
    }

    function iouTokenAddr() external view returns (address) {
        return getIouTokenAddress(_deployer());
    }

    function allocatorAddr() external view returns (address) {
        return getAllocatorAddress(_deployer());
    }
}

/// @dev Accounting-chain counterpart of {EarningChainForkHarness}.
contract AccountingChainForkHarness is DeployAccountingChain {
    string private _outputOverride;

    function redirectOutputTo(string memory throwawayPath) external {
        vm.writeFile(throwawayPath, vm.readFile(super._deploymentOutputPath()));
        _outputOverride = throwawayPath;
    }

    function _deploymentOutputPath() internal view override returns (string memory) {
        return bytes(_outputOverride).length == 0 ? super._deploymentOutputPath() : _outputOverride;
    }

    function deployerAddr() external view returns (address) {
        return _deployer();
    }

    function accessManagerAddr() external view returns (address) {
        return getAccessManagerAddress(_deployer());
    }

    function adiAdapterAddr() external view returns (address) {
        return getAdiAdapterAddress(_deployer());
    }

    function adiCccAddr() external view returns (address) {
        return _adiCrossChainController();
    }

    function gatewayAddr() external view returns (address) {
        return getGatewayAddress(_deployer());
    }

    function iouTokenAddr() external view returns (address) {
        return getIouTokenAddress(_deployer());
    }

    function iouTokenManagerAddr() external view returns (address) {
        return getIouTokenManagerAddress(_deployer());
    }

    function stableVaultAddr() external view returns (address) {
        return getStableVaultAddress(_deployer());
    }

    function chainBalanceOracleAddr() external view returns (address) {
        return getChainBalanceOracleAddress(_deployer());
    }
}

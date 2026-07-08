// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {AccountingChainDeployment} from "script/base/AccountingChainDeployment.sol";
import {EarningChainDeployment} from "script/base/EarningChainDeployment.sol";

/// @dev Earning-chain deploy wrapped for fork tests: selects the deployment config by `ADI_DEPLOYMENT_ENV` (default
/// `preprod`, aligned with the a.DI side the wrapper points at), exposes deterministic CREATE3 + config-derived asset
/// addresses, and redirects the deployment output JSON to a throwaway path so a run never mutates the tracked files.
contract EarningChainForkHarness is EarningChainDeployment {
    string private _outputOverride;

    function _configPath() internal view override returns (string memory) {
        return string.concat("config/deployment-config.", vm.envOr("ADI_DEPLOYMENT_ENV", string("preprod")), ".jsonc");
    }

    /// @notice Seed `throwawayPath` from the tracked deployment JSON (so mid-run aTokenVault reads resolve) and route
    /// every subsequent deployment write there. Call before `run()`.
    function redirectOutputTo(string memory throwawayPath) external {
        // Seed from the tracked deployment JSON when it exists (so any mid-run aTokenVault read resolves); otherwise
        // start from an empty skeleton, since a fresh fork deploy writes its records before reading them back. The
        // tracked JSON only exists for environments already deployed from this repo (e.g. preprod), not staging.
        string memory committed = super._deploymentOutputPath();
        vm.writeFile(throwawayPath, vm.exists(committed) ? vm.readFile(committed) : "{ \"aTokenVaults\": [] }");
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

    function usdc() external view returns (address) {
        return _usdc();
    }

    function usdt() external view returns (address) {
        return _usdt();
    }
}

/// @dev Accounting-chain counterpart of {EarningChainForkHarness}.
contract AccountingChainForkHarness is AccountingChainDeployment {
    string private _outputOverride;

    function _configPath() internal view override returns (string memory) {
        return string.concat("config/deployment-config.", vm.envOr("ADI_DEPLOYMENT_ENV", string("preprod")), ".jsonc");
    }

    function redirectOutputTo(string memory throwawayPath) external {
        // Seed from the tracked deployment JSON when it exists (so any mid-run aTokenVault read resolves); otherwise
        // start from an empty skeleton, since a fresh fork deploy writes its records before reading them back. The
        // tracked JSON only exists for environments already deployed from this repo (e.g. preprod), not staging.
        string memory committed = super._deploymentOutputPath();
        vm.writeFile(throwawayPath, vm.exists(committed) ? vm.readFile(committed) : "{ \"aTokenVaults\": [] }");
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

    function mainAdminAddr() external view returns (address) {
        return _getProfile__MainAdmin();
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

    function gho() external view returns (address) {
        return _gho();
    }

    function usdc() external view returns (address) {
        return _usdc();
    }

    function usdt() external view returns (address) {
        return _usdt();
    }
}

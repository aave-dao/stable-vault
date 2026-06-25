// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {console} from "forge-std/console.sol";
import {BaseChainDeployment} from "script/base/BaseChainDeployment.sol";
import {RolesConfig} from "script/base/RolesConfig.sol";
import {Create3AddressLib} from "script/libraries/Create3AddressLib.sol";

/// @title  Staging — set the new AdiAdapter's function->role bindings on the AccessManager.
/// @notice Follow-up to the AdiAdapter swap (MigrateAdiAdapterSwap): AccessManager `setTargetFunctionRole`
///         bindings are keyed by CONTRACT ADDRESS, so deploying the new AdiAdapter at a fresh Create3 address
///         did NOT carry over the 3 target bindings the old adapter (and prod/genesis) have. The swap re-wired
///         the CCC/gateway references but left these 3 unset (= ADMIN_ROLE), so only ADMIN_ROLE — not the
///         dedicated role holders — can call them. This replicates genesis `_setupTarget__AdiAdapter` for the
///         new adapter, reusing the exact RolesConfig getters so it is 1:1 with genesis/prod:
///           - setDestinationChainAdapter  (HIGH)
///           - rescueTokens                (NO_DELAY)
///           - rescueNative                (NO_DELAY)
///         Each `setTargetFunctionRole` is AccessManager-gated by MainAdmin's CRITICAL (2h) execution delay,
///         so: stepSchedule() -> wait 2h -> stepExecute() -> verify().
abstract contract AdiAdapterBindingsBase is BaseChainDeployment {
    /// @dev Must match MigrateAdiAdapterSwap.NEW_ADI_ADAPTER_SALT.
    string internal constant NEW_ADI_ADAPTER_SALT = "aave.stable-vault.AdiAdapter.pr349";

    // --- deploy-genesis hooks the migration never invokes (BaseChainDeployment requires them) ----------
    function _isAccountingChain() internal pure override returns (bool) {
        return keccak256(bytes(_chainConfigPrefix())) == keccak256(bytes(".accountingChain"));
    }

    function _chainName() internal pure override returns (string memory) {
        return _isAccountingChain() ? "accounting" : "earning";
    }

    function _deployContracts() internal override {}
    function _setupContracts() internal override {}

    function _allocatorDepositor() internal pure override returns (address) {
        return address(0);
    }

    function _allocatorWithdrawer() internal pure override returns (address) {
        return address(0);
    }

    function _iouTokenManagerVault() internal pure override returns (address) {
        return address(0);
    }

    function _aTokenVaultUnderlyings() internal pure override returns (address[] memory) {
        return new address[](0);
    }

    function _bridgePolicyId() internal pure override returns (bytes32) {
        return bytes32(0);
    }

    function _withdrawalExecutionPolicyId() internal pure override returns (bytes32) {
        return bytes32(0);
    }

    function _withdrawalExecutionPolicyTarget() internal pure override returns (address) {
        return address(0);
    }

    function _fundsBridgingPolicyHolder() internal pure override returns (address) {
        return address(0);
    }

    // --- helpers --------------------------------------------------------------------------------------
    function _mainAdmin() internal view returns (address) {
        return _configAddress(".profiles.mainAdmin");
    }

    function _am() internal view returns (IAccessManager) {
        return IAccessManager(getAccessManagerAddress(_deployer()));
    }

    function _newAdiAdapter() internal view returns (address) {
        return Create3AddressLib.computeCreate3Address(NEW_ADI_ADAPTER_SALT, _deployer());
    }

    /// @dev The exact 3 roles genesis `_setupTarget__AdiAdapter` binds, in the same order.
    function _roles() internal view returns (RolesConfig.Role[] memory roles) {
        roles = new RolesConfig.Role[](3);
        roles[0] = RolesConfig.getRole__setDestinationChainAdapter();
        roles[1] = RolesConfig.getRole__rescueTokens();
        roles[2] = RolesConfig.getRole__rescueNative();
    }

    function stepSchedule() external {
        vm.startBroadcast(_mainAdmin());
        _ops(true);
        vm.stopBroadcast();
    }

    function stepExecute() external {
        vm.startBroadcast(_mainAdmin());
        _ops(false);
        vm.stopBroadcast();
    }

    function verify() external view {
        IAccessManager am = _am();
        address adapter = _newAdiAdapter();
        RolesConfig.Role[] memory roles = _roles();
        for (uint256 i = 0; i < roles.length; i++) {
            require(am.getTargetFunctionRole(adapter, roles[i].selector) == roles[i].roleId, "AdiAdapter binding unset");
        }
        console.log("verify: new AdiAdapter 3 function-role bindings set OK");
    }

    /// @dev schedule()/execute() each setTargetFunctionRole op (target = AccessManager). Idempotent on schedule
    ///      (skip if already pending) and resumable on execute (skip if no longer pending). Same op list/order
    ///      both passes so operationIds match.
    function _ops(bool doSchedule) internal {
        IAccessManager am = _am();
        address adapter = _newAdiAdapter();
        RolesConfig.Role[] memory roles = _roles();
        for (uint256 i = 0; i < roles.length; i++) {
            bytes4[] memory sel = new bytes4[](1);
            sel[0] = roles[i].selector;
            bytes memory data = abi.encodeCall(IAccessManager.setTargetFunctionRole, (adapter, sel, roles[i].roleId));
            bytes32 id = am.hashOperation(_mainAdmin(), address(am), data);
            if (doSchedule) {
                if (am.getSchedule(id) != 0) {
                    continue;
                }
                am.schedule(address(am), data, 0);
            } else {
                if (am.getSchedule(id) == 0) {
                    continue;
                }
                am.execute(address(am), data);
            }
        }
    }
}

/// @title Staging new-AdiAdapter bindings — ACCOUNTING chain (Arbitrum).
contract MigrateAccountingAdiAdapterBindings is AdiAdapterBindingsBase {
    function _configPath() internal pure override returns (string memory) {
        return "config/deployment-config.staging.jsonc";
    }

    function _chainConfigPrefix() internal pure override returns (string memory) {
        return ".accountingChain";
    }

    function _remoteChainConfigPrefix() internal pure override returns (string memory) {
        return ".earningChain";
    }
}

/// @title Staging new-AdiAdapter bindings — EARNING chain (Ethereum).
contract MigrateEarningAdiAdapterBindings is AdiAdapterBindingsBase {
    function _configPath() internal pure override returns (string memory) {
        return "config/deployment-config.staging.jsonc";
    }

    function _chainConfigPrefix() internal pure override returns (string memory) {
        return ".earningChain";
    }

    function _remoteChainConfigPrefix() internal pure override returns (string memory) {
        return ".accountingChain";
    }
}

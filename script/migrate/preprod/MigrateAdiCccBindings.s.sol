// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {console} from "forge-std/console.sol";
import {BaseChainDeployment} from "script/base/BaseChainDeployment.sol";
import {RolesConfig} from "script/base/RolesConfig.sol";

/// @title  Preprod AdiCrossChainController function→role bindings (VA-398) — chain-agnostic logic.
/// @notice Wires the 15 a.DI CrossChainController admin selectors to their roles in the SV AccessManager,
///         on an ALREADY-LIVE env (preprod) where the genesis AccessManager setup ran BEFORE these CCC
///         targets were added to RolesConfig — so the roles exist & are granted, but the target bindings
///         were never set (`getTargetFunctionRole(CCC, selector) == 0/ADMIN_ROLE`). Prod has them wired
///         (it ran the full setup); this brings preprod to the SAME on-chain state, 1:1.
///
/// This is the EXACT binding set applied at genesis by
/// `AccessManagerBaseSetup._setupTarget__AdiCrossChainController()` — the same 15 `RolesConfig.getRole__adi*`
/// definitions, in the same order — only it routes through schedule()/execute() because on a live env every
/// `setTargetFunctionRole` is AccessManager-gated by MainAdmin's CRITICAL (2h) execution delay.
///
/// The role IDs are `_selectorToRoleId(selector)` (selector ++ 0x00000000) — derived purely from the
/// function selector, hence ENV-AGNOSTIC: identical on prod and preprod. So this copies prod deterministically;
/// there is nothing env-specific to reconcile. The CCC address itself is the only per-env value (from config).
///
/// CCC ownership is independent of these bindings: `setTargetFunctionRole` only configures the AccessManager's
/// permission map, so it works whether or not the AccessManager already owns the CCC (preprod: it does).
///
/// Step sequence:
///   stepSchedule()  [MAIN ADMIN]  schedule() the 15 setTargetFunctionRole ops (CRITICAL = 2h)
///   --- wait 2h ---
///   stepExecute()   [MAIN ADMIN]  execute() the 15 ops
///   verify()                      (read-only) every CCC selector bound to its expected roleId
///
///   forge script MigrateAccountingAdiBindings --sig "stepSchedule()" --sender <MAIN_ADMIN>
///   (wait 2h) --sig "stepExecute()" --sender <MAIN_ADMIN>   --sig "verify()"
abstract contract AdiCccBindingsBase is BaseChainDeployment {
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

    // Policy hooks are unused by this (CCC-only) migration; stub them (pure → no forge-build notes).
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

    /// @dev The CrossChainController target (per-env, from config). Inherited resolver:
    ///      `_configAddress(_chainConfigPrefix() + ".adi.crossChainController")`.
    function _ccc() internal view returns (address) {
        address ccc = _adiCrossChainController();
        require(ccc != address(0), "CCC address not set");
        return ccc;
    }

    /// @dev IDENTICAL list (and order) to AccessManagerBaseSetup._setupTarget__AdiCrossChainController().
    function _adiRoles() internal view returns (RolesConfig.Role[] memory r) {
        r = new RolesConfig.Role[](15);
        // Forwarder
        r[0] = RolesConfig.getRole__adiApproveSenders();
        r[1] = RolesConfig.getRole__adiRemoveSenders();
        r[2] = RolesConfig.getRole__adiEnableBridgeAdapters();
        r[3] = RolesConfig.getRole__adiDisableBridgeAdapters();
        r[4] = RolesConfig.getRole__adiUpdateOptimalBandwidthByChain();
        r[5] = RolesConfig.getRole__adiConfigAdapter();
        r[6] = RolesConfig.getRole__adiUpdateRequiredForwardingSuccessesByChain();
        // Receiver
        r[7] = RolesConfig.getRole__adiUpdateConfirmations();
        r[8] = RolesConfig.getRole__adiUpdateMessagesValidityTimestamp();
        r[9] = RolesConfig.getRole__adiAllowReceiverBridgeAdapters();
        r[10] = RolesConfig.getRole__adiDisallowReceiverBridgeAdapters();
        // Rescue / ownership
        r[11] = RolesConfig.getRole__adiEmergencyTokenTransfer();
        r[12] = RolesConfig.getRole__adiEmergencyEtherTransfer();
        r[13] = RolesConfig.getRole__adiTransferOwnership();
        r[14] = RolesConfig.getRole__adiUpdateGuardian();
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////
    // STEP 1 — schedule the 15 bindings (MAIN ADMIN). Gated at CRITICAL_DELAY (2h preprod).
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function stepSchedule() external {
        vm.startBroadcast(_mainAdmin());
        _bindOps(true);
        vm.stopBroadcast();
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////
    // STEP 2 — execute the 15 bindings (MAIN ADMIN), after the 2h wait.
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function stepExecute() external {
        vm.startBroadcast(_mainAdmin());
        _bindOps(false);
        vm.stopBroadcast();
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////
    // VERIFY — read-only. Reverts on any inconsistency. Safe to run after any step.
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function verify() external view {
        IAccessManager am = _am();
        address ccc = _ccc();
        RolesConfig.Role[] memory roles = _adiRoles();
        for (uint256 i = 0; i < roles.length; i++) {
            require(
                am.getTargetFunctionRole(ccc, roles[i].selector) == roles[i].roleId,
                "AdiCrossChainController binding != expected roleId"
            );
        }
        console.log("verify: 15 AdiCrossChainController function-role bindings set OK");
    }

    /// @notice Audit aid: log each CCC selector + its expected roleId (read straight from RolesConfig).
    ///         Reads no chain state — the source of truth for what stepSchedule/stepExecute will bind.
    function dumpRoles() external view {
        RolesConfig.Role[] memory roles = _adiRoles();
        for (uint256 i = 0; i < roles.length; i++) {
            console.log("ADI_ROLE", i, uint256(uint32(roles[i].selector)), uint256(roles[i].roleId));
        }
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////
    // Op builder. `doSchedule == true` → schedule(); else execute(). Each op is a setTargetFunctionRole
    // on the AccessManager binding ONE CCC selector to its roleId. Identical op list both passes so the
    // operationId (hashOperation(mainAdmin, accessManager, data)) matches between schedule and execute.
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _bindOps(bool doSchedule) internal {
        IAccessManager am = _am();
        address amAddr = address(am);
        address ccc = _ccc();
        RolesConfig.Role[] memory roles = _adiRoles();
        for (uint256 i = 0; i < roles.length; i++) {
            _op(
                am,
                amAddr,
                abi.encodeCall(IAccessManager.setTargetFunctionRole, (ccc, _one(roles[i].selector), roles[i].roleId)),
                doSchedule
            );
        }
    }

    function _op(IAccessManager am, address target, bytes memory data, bool doSchedule) internal {
        if (doSchedule) {
            // when=0 → earliest allowed (now + setback). Idempotent: skip if already scheduled & pending.
            bytes32 id = am.hashOperation(_mainAdmin(), target, data);
            if (am.getSchedule(id) != 0) {
                return;
            }
            am.schedule(target, data, 0);
        } else {
            am.execute(target, data);
        }
    }

    function _one(bytes4 selector) internal pure returns (bytes4[] memory arr) {
        arr = new bytes4[](1);
        arr[0] = selector;
    }
}

/// @title Preprod AdiCrossChainController bindings — ACCOUNTING chain (Arbitrum).
contract MigrateAccountingAdiBindings is AdiCccBindingsBase {
    function _configPath() internal pure override returns (string memory) {
        return "config/deployment-config.preprod.jsonc";
    }

    function _chainConfigPrefix() internal pure override returns (string memory) {
        return ".accountingChain";
    }

    function _remoteChainConfigPrefix() internal pure override returns (string memory) {
        return ".earningChain";
    }
}

/// @title Preprod AdiCrossChainController bindings — EARNING chain (Ethereum).
contract MigrateEarningAdiBindings is AdiCccBindingsBase {
    function _configPath() internal pure override returns (string memory) {
        return "config/deployment-config.preprod.jsonc";
    }

    function _chainConfigPrefix() internal pure override returns (string memory) {
        return ".earningChain";
    }

    function _remoteChainConfigPrefix() internal pure override returns (string memory) {
        return ".accountingChain";
    }
}

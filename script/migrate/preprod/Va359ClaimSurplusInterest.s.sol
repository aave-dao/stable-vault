// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {console} from "forge-std/console.sol";
import {AccountingChainDeployment} from "script/base/AccountingChainDeployment.sol";
import {RolesConfig} from "script/base/RolesConfig.sol";

/// @title  VA-359 — align preprod `StableVault.claimSurplusInterest` to prod (immediate, operational guardian).
/// @notice Runs on BOTH chains: the role config (guardian/admin/grantDelay) is set on each AccessManager in
///         genesis, and MainAdmin+SecondaryAdmin are granted every function-based role per chain — so the
///         drift exists on both. StableVaultManager is an accounting-only grantee (branched on chainid).
///         preprod was deployed BEFORE the
///         last-minute decision that prod ships: NO execution delay + OPERATIONAL_ROLE guardian. The current
///         RolesConfig already encodes the target (`getRole__claimSurplusInterest` → NO_DELAY, guardian=2), so
///         this script just re-applies that role config on the live AccessManager. No code/config change, no
///         redeploy — pure AccessManager re-config.
///
/// On-chain delta (vs preprod's current guardian=1 / 1h):
///   setRoleGuardian, setRoleAdmin → OPERATIONAL_ROLE_GUARDIAN_ROLE (2)   [ADMIN_ROLE op, CRITICAL=2h → scheduled]
///   setGrantDelay → 0                                                    [ADMIN_ROLE op, CRITICAL=2h → scheduled]
///   re-grantRole(MainAdmin / SecondaryAdmin / StableVaultManager), delay 0
///
/// IMPORTANT — `grantRole` is gated by the role's ADMIN (here `getRoleAdmin(claimSurplusInterest)` =
/// ADMIN_ROLE_GUARDIAN_ROLE, which MainAdmin holds at delay 0), so it is IMMEDIATE (setback 0) and
/// *cannot be scheduled* (`schedule()` reverts AccessManagerUnauthorizedCall when setback==0). It is
/// therefore called DIRECTLY in stepExecute, and must run BEFORE `setRoleAdmin` flips the admin to
/// OPERATIONAL_ROLE_GUARDIAN_ROLE (which MainAdmin does not hold) — otherwise the re-grant would be
/// unauthorized. Reducing a grantee's execution delay 1h→0 via grantRole settles after `oldDelay-newDelay`
/// = 1h (OZ uses minSetback=0 for member-delay changes), so verify() runs after the +1h settle. Same
/// schedule→+2h→execute→+1h→verify cadence as the policy migration.
///
///   forge script Va359ClaimSurplusInterest --sig "stepSchedule()" --sender <MAIN_ADMIN>
///   (wait 2h) --sig "stepExecute()" --sender <MAIN_ADMIN>   (wait 1h) --sig "verify()"
contract Va359ClaimSurplusInterest is AccountingChainDeployment {
    function _configPath() internal pure virtual override returns (string memory) {
        return "config/deployment-config.preprod.jsonc";
    }

    function _mainAdmin() internal view returns (address) {
        return _configAddress(".profiles.mainAdmin");
    }

    function _secondaryAdmin() internal view returns (address) {
        return _configAddress(".profiles.secondaryAdmin");
    }

    function _am() internal view returns (IAccessManager) {
        return IAccessManager(getAccessManagerAddress(_deployer()));
    }

    /// @dev MainAdmin + SecondaryAdmin on both chains; StableVaultManager is accounting-only. Runs on the
    ///      chain it's pointed at, so branch on chainid (Arbitrum = accounting).
    function _grantees() internal view returns (address[] memory g) {
        bool accounting = block.chainid == 42161;
        g = new address[](accounting ? 3 : 2);
        g[0] = _mainAdmin();
        g[1] = _secondaryAdmin();
        if (accounting) {
            g[2] = _getProfile__StableVaultManager();
        }
    }

    function stepSchedule() external {
        vm.startBroadcast(_mainAdmin());
        _roleConfigOps(true); // schedule the 3 ADMIN_ROLE ops (CRITICAL-delayed)
        vm.stopBroadcast();
    }

    function stepExecute() external {
        vm.startBroadcast(_mainAdmin());
        // grantRole is immediate and must precede setRoleAdmin (which flips the admin to a role MainAdmin
        // doesn't hold). Do the direct grants first, then execute the scheduled role-config ops.
        _directGrants();
        _roleConfigOps(false);
        vm.stopBroadcast();
    }

    function verify() external view {
        RolesConfig.Role memory r = RolesConfig.getRole__claimSurplusInterest();
        IAccessManager am = _am();
        require(am.getRoleGuardian(r.roleId) == r.guardianRoleId, "claimSurplusInterest guardian != operational(2)");
        require(am.getRoleAdmin(r.roleId) == r.guardianRoleId, "claimSurplusInterest admin != operational(2)");
        address[] memory g = _grantees();
        for (uint256 i = 0; i < g.length; i++) {
            (bool member, uint32 delay) = am.hasRole(r.roleId, g[i]);
            require(member, "grantee lost claimSurplusInterest role");
            require(delay == r.delay, "grantee execution delay != 0 (not settled? wait the 1h setback)");
        }
        console.log("verify: claimSurplusInterest is immediate + operational guardian for all 3 grantees OK");
    }

    /// @dev The three ADMIN_ROLE ops, gated by the AccessManager target-admin delay (CRITICAL) → scheduled.
    function _roleConfigOps(bool doSchedule) internal {
        IAccessManager am = _am();
        address amAddr = address(am);
        RolesConfig.Role memory r = RolesConfig.getRole__claimSurplusInterest(); // delay=0, guardian=OPERATIONAL(2)
        _op(am, amAddr, abi.encodeCall(IAccessManager.setRoleGuardian, (r.roleId, r.guardianRoleId)), doSchedule);
        _op(am, amAddr, abi.encodeCall(IAccessManager.setRoleAdmin, (r.roleId, r.guardianRoleId)), doSchedule);
        _op(am, amAddr, abi.encodeCall(IAccessManager.setGrantDelay, (r.roleId, r.delay)), doSchedule);
    }

    /// @dev Immediate re-grants (setback 0 — admin role held at delay 0). Must run before setRoleAdmin executes.
    function _directGrants() internal {
        IAccessManager am = _am();
        RolesConfig.Role memory r = RolesConfig.getRole__claimSurplusInterest();
        address[] memory g = _grantees();
        for (uint256 i = 0; i < g.length; i++) {
            am.grantRole(r.roleId, g[i], r.delay);
        }
    }

    /// @dev schedule() (idempotent via getSchedule) or execute(), caller = MainAdmin.
    function _op(IAccessManager am, address target, bytes memory data, bool doSchedule) internal {
        if (doSchedule) {
            bytes32 id = am.hashOperation(_mainAdmin(), target, data);
            if (am.getSchedule(id) != 0) {
                return;
            }
            am.schedule(target, data, 0);
        } else {
            am.execute(target, data);
        }
    }
}

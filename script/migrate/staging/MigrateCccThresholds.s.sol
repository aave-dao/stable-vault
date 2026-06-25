// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {ICrossChainForwarder} from "aave-delivery-infrastructure/contracts/interfaces/ICrossChainForwarder.sol";
import {ICrossChainReceiver} from "aave-delivery-infrastructure/contracts/interfaces/ICrossChainReceiver.sol";
import {console} from "forge-std/console.sol";
import {BaseChainDeployment} from "script/base/BaseChainDeployment.sol";

/// @title  Staging a.DI CrossChainController bridge-quorum alignment to prod.
/// @notice Staging runs looser bridge quorums than prod (verified on-chain):
///           - EARNING (ETH) CCC: requiredConfirmation for messages FROM accounting = 2, prod = 3.
///           - ACCOUNTING (ARB) CCC: requiredForwardingSuccesses for messages TO earning = 2, prod = 3.
///         Both other directions already match prod (1/1), and both chains already have >=3 bridge adapters,
///         so raising the quorum to 3 is feasible without any new/rebuilt adapter — a pure config change.
///
///         Driven through the SV AccessManager: `updateConfirmations` / `updateRequiredForwardingSuccessesByChain`
///         are bound to MainAdmin's roles by VA-398, both gated at CRITICAL (2h) execution delay. So this is the
///         same schedule -> +2h -> execute -> verify cadence as the policy migration. The CCC's config owner is
///         already the AccessManager, so no ownership step is needed.
///
///         forge script MigrateAccountingCccThresholds --sig "stepSchedule()" --sender <MAIN_ADMIN>
///         (wait 2h) --sig "stepExecute()" --sender <MAIN_ADMIN>   --sig "verify()"
abstract contract CccThresholdsBase is BaseChainDeployment {
    /// @dev prod bridge quorum (number of bridge adapters that must confirm / forward).
    uint256 internal constant TARGET_QUORUM = 3;

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

    function _ccc() internal view returns (address) {
        address ccc = _adiCrossChainController();
        require(ccc != address(0), "CCC address not set");
        return ccc;
    }

    /// @dev The remote chain id this CCC bridges with (accounting<->earning), from config.
    function _remoteChainId() internal view returns (uint256) {
        return _configUint(string.concat(_remoteChainConfigPrefix(), ".chainId"));
    }

    /// @dev The one quorum op for this chain:
    ///      - accounting (forwarder): updateRequiredForwardingSuccessesByChain(remote -> TARGET_QUORUM)
    ///      - earning    (receiver) : updateConfirmations(remote -> TARGET_QUORUM)
    function _quorumCall() internal view returns (bytes memory) {
        if (_isAccountingChain()) {
            ICrossChainForwarder.RequiredForwardingSuccessesByChain[] memory s =
                new ICrossChainForwarder.RequiredForwardingSuccessesByChain[](1);
            s[0] = ICrossChainForwarder.RequiredForwardingSuccessesByChain({
                chainId: _remoteChainId(), requiredSuccesses: TARGET_QUORUM
            });
            return abi.encodeCall(ICrossChainForwarder.updateRequiredForwardingSuccessesByChain, (s));
        } else {
            ICrossChainReceiver.ConfirmationInput[] memory c = new ICrossChainReceiver.ConfirmationInput[](1);
            c[0] = ICrossChainReceiver.ConfirmationInput({
                chainId: _remoteChainId(), requiredConfirmations: uint8(TARGET_QUORUM)
            });
            return abi.encodeCall(ICrossChainReceiver.updateConfirmations, (c));
        }
    }

    function stepSchedule() external {
        vm.startBroadcast(_mainAdmin());
        _op(true);
        vm.stopBroadcast();
    }

    function stepExecute() external {
        vm.startBroadcast(_mainAdmin());
        _op(false);
        vm.stopBroadcast();
    }

    function verify() external view {
        uint256 got = _isAccountingChain()
            ? ICrossChainForwarder(_ccc()).getRequiredForwardingSuccessesByChain(_remoteChainId())
            : uint256(ICrossChainReceiver(_ccc()).getConfigurationByChain(_remoteChainId()).requiredConfirmation);
        require(got == TARGET_QUORUM, "CCC quorum != target (3)");
        console.log("verify: CCC bridge quorum = 3 (matches prod) OK");
    }

    /// @dev schedule()/execute() the single quorum op via the AccessManager (target = CCC). Resumable: on
    ///      execute, skip if no longer pending (already executed), mirroring the schedule-side idempotency.
    function _op(bool doSchedule) internal {
        IAccessManager am = _am();
        bytes memory data = _quorumCall();
        bytes32 id = am.hashOperation(_mainAdmin(), _ccc(), data);
        if (doSchedule) {
            if (am.getSchedule(id) != 0) {
                return;
            }
            am.schedule(_ccc(), data, 0);
        } else {
            if (am.getSchedule(id) == 0) {
                return;
            }
            am.execute(_ccc(), data);
        }
    }
}

/// @title Staging CCC quorum alignment — ACCOUNTING chain (Arbitrum): forwarding successes to earning -> 3.
contract MigrateAccountingCccThresholds is CccThresholdsBase {
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

/// @title Staging CCC quorum alignment — EARNING chain (Ethereum): confirmations from accounting -> 3.
contract MigrateEarningCccThresholds is CccThresholdsBase {
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

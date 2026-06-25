// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {ICrossChainForwarder} from "aave-delivery-infrastructure/contracts/interfaces/ICrossChainForwarder.sol";
import {IWithGuardian} from "aave-delivery-infrastructure/contracts/old-oz/interfaces/IWithGuardian.sol";
import {console} from "forge-std/console.sol";
import {BaseChainDeployment} from "script/base/BaseChainDeployment.sol";
import {Create3AddressLib} from "script/libraries/Create3AddressLib.sol";
import {AdiAdapter} from "src/bridging/adi/AdiAdapter.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";

/// @dev `getDataOnlyBridgeAdapterRemovalId` lives on the concrete gateway, not IChainGateway.
interface IGatewayRemovalId {
    function getDataOnlyBridgeAdapterRemovalId(uint256 chainId, address bridgeAdapter) external view returns (bytes32);
}

/// @title  Staging AdiAdapter upgrade — swap the data-only bridge adapter to the prod (PR #349) version.
/// @notice Staging runs the PRE-#349 AdiAdapter (no "require non-zero forwarding quorum" guard); prod has the
///         fix. The adapter is non-upgradeable (immutables, no proxy) and Create3-deployed, so "upgrade" means
///         deploy-new-at-a-fresh-salt, re-wire every reference, and 2-step remove the old one. The new adapter
///         is deployed at the SAME Create3 address on both chains (deterministic), so its destination is itself.
///
/// References to migrate (all AccessManager-gated; deploy is the only non-gated step):
///   - CCC approved sender   : approveSenders([new]) / removeSenders([old])        [CRITICAL 2h]
///   - CCC guardian          : updateGuardian(new)                                 [CRITICAL 2h]
///   - new adapter dest map  : setDestinationChainAdapter(remote, new)             [HIGH 1h]
///   - gateway data-only set : addDataOnlyBridgeAdapter(remote, new)               [HIGH 1h]
///                             initiate/finalizeDataOnlyBridgeAdapterRemoval(old)  [HIGH 1h, 2-step]
///
/// Step sequence (per chain):
///   stepDeploy()           [DEPLOYER]   Create3-deploy the new AdiAdapter (not gated)
///   stepScheduleWiring()   [MAIN ADMIN] schedule setDestinationChainAdapter + addDataOnlyBridgeAdapter +
///                                       approveSenders(new) + updateGuardian(new) + removeSenders(old)
///   --- wait CRITICAL (2h) ---
///   stepExecuteWiring()    [MAIN ADMIN] execute the above; then schedule initiateDataOnlyBridgeAdapterRemoval(old)
///   --- wait HIGH (1h) ---
///   stepExecuteInitiate()  [MAIN ADMIN] execute initiate (old -> RECEIVE_ONLY); read removalId; schedule finalize
///   --- wait HIGH (1h) ---
///   stepExecuteFinalize()  [MAIN ADMIN] execute finalize (old removed)
///   verify()                            new = approved sender + guardian; old no longer a sender
///
/// NOTE: this swap re-wires the new adapter's CCC/gateway references but does NOT set its AccessManager
/// function->role bindings (setTargetFunctionRole is keyed by contract address, so the old adapter's bindings
/// do not carry over). Run MigrateAdiAdapterBindings AFTER this swap to replicate genesis _setupTarget__AdiAdapter
/// (setDestinationChainAdapter / rescueTokens / rescueNative) for the new adapter.
abstract contract AdiAdapterSwapBase is BaseChainDeployment {
    /// @dev New Create3 salt for the post-#349 adapter (the genesis salt's address is occupied by the old one).
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

    function _ccc() internal view returns (address) {
        address ccc = _adiCrossChainController();
        require(ccc != address(0), "CCC address not set");
        return ccc;
    }

    function _gateway() internal view returns (address) {
        return getGatewayAddress(_deployer());
    }

    function _oldAdiAdapter() internal view returns (address) {
        return getAdiAdapterAddress(_deployer());
    }

    function _newAdiAdapter() internal view returns (address) {
        return Create3AddressLib.computeCreate3Address(NEW_ADI_ADAPTER_SALT, _deployer());
    }

    function _remoteChainId() internal view returns (uint256) {
        return _configUint(string.concat(_remoteChainConfigPrefix(), ".chainId"));
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////
    // STEP 1 — deploy the new AdiAdapter (DEPLOYER). Create3, same address on both chains. Not gated.
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function stepDeploy() external {
        address predicted = _newAdiAdapter();
        bytes memory initCode = abi.encodePacked(
            type(AdiAdapter).creationCode,
            abi.encode(getAccessManagerAddress(_deployer()), _gateway(), _ccc(), getTransferHelperAddress(_deployer()))
        );
        vm.startBroadcast(_deployer());
        if (predicted.code.length == 0) {
            address deployed = _deploy_create3(NEW_ADI_ADAPTER_SALT, _deployer(), initCode);
            require(deployed == predicted, "new AdiAdapter address mismatch");
        }
        vm.stopBroadcast();
        console.log("AdiAdapter (new)", predicted);
        console.log("AdiAdapter (old)", _oldAdiAdapter());
    }

    function verifyDeployed() external view {
        require(_newAdiAdapter().code.length != 0, "new AdiAdapter not deployed");
        console.log("verifyDeployed: new AdiAdapter has code OK");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////
    // STEP 2 — schedule the re-wiring (MAIN ADMIN). Mixed HIGH/CRITICAL; matures by the 2h CRITICAL window.
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function stepScheduleWiring() external {
        vm.startBroadcast(_mainAdmin());
        _wiringOps(true);
        vm.stopBroadcast();
    }

    /// @dev Optimization: schedule the removal-initiate alongside the wiring (T0) rather than at the execute
    ///      window. The gateway's count>1 requirement is checked at EXECUTE, not at schedule(), so it is safe
    ///      to queue early — it lets initiate execute in the SAME window as the wiring (after addDataOnly
    ///      makes count=2), saving one HIGH (1h) delay. Idempotent: skips if already scheduled.
    function stepScheduleInitiate() external {
        vm.startBroadcast(_mainAdmin());
        _initiateOp(true);
        vm.stopBroadcast();
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////
    // STEP 3 — execute the re-wiring; then schedule the old-adapter removal initiation (MAIN ADMIN).
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function stepExecuteWiring() external {
        vm.startBroadcast(_mainAdmin());
        _wiringOps(false);
        _initiateOp(true); // gateway count is 2 now (old+new) -> initiate is valid; HIGH-gated
        vm.stopBroadcast();
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////
    // STEP 4 — execute initiation (old -> RECEIVE_ONLY); read the removalId; schedule finalize (MAIN ADMIN).
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function stepExecuteInitiate() external {
        vm.startBroadcast(_mainAdmin());
        _initiateOp(false);
        _finalizeOp(true); // removalId is now set on-chain by the initiate above
        vm.stopBroadcast();
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////
    // STEP 5 — execute finalize (old removed) (MAIN ADMIN), after the 1h wait.
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function stepExecuteFinalize() external {
        vm.startBroadcast(_mainAdmin());
        _finalizeOp(false);
        vm.stopBroadcast();
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////
    // VERIFY — read-only.
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function verify() external view {
        address newA = _newAdiAdapter();
        address oldA = _oldAdiAdapter();
        ICrossChainForwarder ccc = ICrossChainForwarder(_ccc());
        require(newA.code.length != 0, "new AdiAdapter not deployed");
        require(ccc.isSenderApproved(newA), "new AdiAdapter not approved sender");
        require(IWithGuardian(_ccc()).guardian() == newA, "CCC guardian != new AdiAdapter");
        require(!ccc.isSenderApproved(oldA), "old AdiAdapter still approved sender");
        console.log("verify: AdiAdapter swapped (new sender+guardian, old removed) OK");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////
    // Op builders. doSchedule==true -> schedule(); else execute(). Resumable: execute skips ops no longer
    // pending (getSchedule==0). Same op list/order both passes so operationIds match.
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _wiringOps(bool doSchedule) internal {
        address newA = _newAdiAdapter();
        uint256 remote = _remoteChainId();
        // 1) new adapter's destination on the remote chain = the new adapter (same Create3 address both chains)
        _op(newA, abi.encodeCall(IBridgeAdapter.setDestinationChainAdapter, (remote, newA)), doSchedule);
        // 2) register new on the gateway as a data-only bridge adapter (count -> 2)
        _op(_gateway(), abi.encodeCall(IChainGateway.addDataOnlyBridgeAdapter, (remote, newA)), doSchedule);
        // 3) CCC: approve new as sender, make it guardian, remove old sender
        _op(_ccc(), abi.encodeCall(ICrossChainForwarder.approveSenders, (_one(newA))), doSchedule);
        _op(_ccc(), abi.encodeCall(IWithGuardian.updateGuardian, (newA)), doSchedule);
        _op(_ccc(), abi.encodeCall(ICrossChainForwarder.removeSenders, (_one(_oldAdiAdapter()))), doSchedule);
    }

    function _initiateOp(bool doSchedule) internal {
        _op(
            _gateway(),
            abi.encodeCall(IChainGateway.initiateDataOnlyBridgeAdapterRemoval, (_remoteChainId(), _oldAdiAdapter())),
            doSchedule
        );
    }

    function _finalizeOp(bool doSchedule) internal {
        bytes32 removalId =
            IGatewayRemovalId(_gateway()).getDataOnlyBridgeAdapterRemovalId(_remoteChainId(), _oldAdiAdapter());
        require(removalId != bytes32(0), "removalId not set (run initiate first)");
        _op(
            _gateway(),
            abi.encodeCall(
                IChainGateway.finalizeDataOnlyBridgeAdapterRemoval, (_remoteChainId(), _oldAdiAdapter(), removalId)
            ),
            doSchedule
        );
    }

    function _op(address target, bytes memory data, bool doSchedule) internal {
        IAccessManager am = _am();
        bytes32 id = am.hashOperation(_mainAdmin(), target, data);
        if (doSchedule) {
            if (am.getSchedule(id) != 0) {
                return;
            }
            am.schedule(target, data, 0);
        } else {
            if (am.getSchedule(id) == 0) {
                return;
            }
            am.execute(target, data);
        }
    }

    function _one(address a) internal pure returns (address[] memory arr) {
        arr = new address[](1);
        arr[0] = a;
    }
}

/// @title Staging AdiAdapter swap — ACCOUNTING chain (Arbitrum).
contract MigrateAccountingAdiAdapterSwap is AdiAdapterSwapBase {
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

/// @title Staging AdiAdapter swap — EARNING chain (Ethereum).
contract MigrateEarningAdiAdapterSwap is AdiAdapterSwapBase {
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

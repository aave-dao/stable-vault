// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {ICrossChainForwarder} from "aave-delivery-infrastructure/contracts/interfaces/ICrossChainForwarder.sol";
import {ICrossChainReceiver} from "aave-delivery-infrastructure/contracts/interfaces/ICrossChainReceiver.sol";
import {console} from "forge-std/console.sol";
import {BaseChainDeployment} from "script/base/BaseChainDeployment.sol";

/// @title  Staging a.DI CCIP bridge-adapter swap (LINK-fee -> native-fee), to match prod.
/// @notice The a.DI team deployed the new native-fee CCIP adapters (bytecode matches prod); staging was running
///         the older LINK-fee version. This swaps them on the CrossChainController via the SV AccessManager.
///         CCIP carries the ARB->ETH direction only:
///           - ACCOUNTING (ARB, forwarder side): enableBridgeAdapters(new) then disableBridgeAdapters(old)
///           - EARNING    (ETH, receiver side) : allowReceiverBridgeAdapters(new) then disallow(old)
///         Enable/allow NEW before disable/disallow OLD so the ARB->ETH adapter set never drops below quorum;
///         both ops run in ONE schedule + ONE execute batch (atomic per step). All CRITICAL (2h) gated.
///         No CCC pre-funding needed — a.DI pays CCIP fees from the caller's msg.value per bridge tx.
///
///         forge script MigrateAccountingCcipSwap --sig "stepSchedule()" --sender <MAIN_ADMIN>
///         (wait 2h) --sig "stepExecute()" --sig "verify()"
abstract contract CcipSwapBase is BaseChainDeployment {
    // a.DI-deployed CCIP adapters (from the a.DI team's staging run; confirmed on-chain).
    address internal constant NEW_ARB_CCIP = 0x2501f567B2aa3B26FC4B28EaEd2CFe868D3FbE10;
    address internal constant NEW_ETH_CCIP = 0x9e37CF557B8e4A68c99eA4A6Df20D6472FcB9F8d;
    address internal constant OLD_ARB_CCIP = 0xd831F3ff0EFB5b43AB961175EFD49Ea651Be539F;
    address internal constant OLD_ETH_CCIP = 0x227DfA4D92385225abB92587ef7E4408649EA85a;

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

    function _remoteChainId() internal view returns (uint256) {
        return _configUint(string.concat(_remoteChainConfigPrefix(), ".chainId"));
    }

    function _remotes() internal view returns (uint256[] memory r) {
        r = new uint256[](1);
        r[0] = _remoteChainId();
    }

    /// @dev The two swap ops for this chain. ACCOUNTING = forwarder (enable/disable);
    ///      EARNING = receiver (allow/disallow). NEW first, then OLD.
    function _swapOps(bool doSchedule) internal {
        if (_isAccountingChain()) {
            // forwarder: enable NEW (ARB->ETH), then disable OLD
            ICrossChainForwarder.ForwarderBridgeAdapterConfigInput[] memory en =
                new ICrossChainForwarder.ForwarderBridgeAdapterConfigInput[](1);
            en[0] = ICrossChainForwarder.ForwarderBridgeAdapterConfigInput({
                currentChainBridgeAdapter: NEW_ARB_CCIP,
                destinationBridgeAdapter: NEW_ETH_CCIP,
                destinationChainId: _remoteChainId()
            });
            _op(abi.encodeCall(ICrossChainForwarder.enableBridgeAdapters, (en)), doSchedule);

            ICrossChainForwarder.BridgeAdapterToDisable[] memory dis =
                new ICrossChainForwarder.BridgeAdapterToDisable[](1);
            dis[0] = ICrossChainForwarder.BridgeAdapterToDisable({bridgeAdapter: OLD_ARB_CCIP, chainIds: _remotes()});
            _op(abi.encodeCall(ICrossChainForwarder.disableBridgeAdapters, (dis)), doSchedule);
        } else {
            // receiver: allow NEW (origin ARB), then disallow OLD
            ICrossChainReceiver.ReceiverBridgeAdapterConfigInput[] memory al =
                new ICrossChainReceiver.ReceiverBridgeAdapterConfigInput[](1);
            al[0] = ICrossChainReceiver.ReceiverBridgeAdapterConfigInput({
                bridgeAdapter: NEW_ETH_CCIP, chainIds: _remotes()
            });
            _op(abi.encodeCall(ICrossChainReceiver.allowReceiverBridgeAdapters, (al)), doSchedule);

            ICrossChainReceiver.ReceiverBridgeAdapterConfigInput[] memory dis =
                new ICrossChainReceiver.ReceiverBridgeAdapterConfigInput[](1);
            dis[0] = ICrossChainReceiver.ReceiverBridgeAdapterConfigInput({
                bridgeAdapter: OLD_ETH_CCIP, chainIds: _remotes()
            });
            _op(abi.encodeCall(ICrossChainReceiver.disallowReceiverBridgeAdapters, (dis)), doSchedule);
        }
    }

    function stepSchedule() external {
        vm.startBroadcast(_mainAdmin());
        _swapOps(true);
        vm.stopBroadcast();
    }

    function stepExecute() external {
        vm.startBroadcast(_mainAdmin());
        _swapOps(false);
        vm.stopBroadcast();
    }

    function verify() external view {
        uint256 remote = _remoteChainId();
        if (_isAccountingChain()) {
            ICrossChainForwarder.ChainIdBridgeConfig[] memory fwd =
                ICrossChainForwarder(_ccc()).getForwarderBridgeAdaptersByChain(remote);
            bool hasNew;
            bool hasOld;
            for (uint256 i = 0; i < fwd.length; i++) {
                if (fwd[i].currentChainBridgeAdapter == NEW_ARB_CCIP) {
                    hasNew = true;
                }
                if (fwd[i].currentChainBridgeAdapter == OLD_ARB_CCIP) {
                    hasOld = true;
                }
            }
            require(hasNew && !hasOld, "ARB forwarder: new CCIP not enabled / old not disabled");
        } else {
            ICrossChainReceiver ccc = ICrossChainReceiver(_ccc());
            require(ccc.isReceiverBridgeAdapterAllowed(NEW_ETH_CCIP, remote), "ETH receiver: new CCIP not allowed");
            require(!ccc.isReceiverBridgeAdapterAllowed(OLD_ETH_CCIP, remote), "ETH receiver: old CCIP still allowed");
        }
        console.log("verify: CCIP adapter swapped (new native-fee enabled, old removed) OK");
    }

    /// @dev schedule()/execute() via the AccessManager (target = CCC). Resumable on execute.
    function _op(bytes memory data, bool doSchedule) internal {
        IAccessManager am = _am();
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

/// @title Staging CCIP swap — ACCOUNTING chain (Arbitrum, forwarder side).
contract MigrateAccountingCcipSwap is CcipSwapBase {
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

/// @title Staging CCIP swap — EARNING chain (Ethereum, receiver side).
contract MigrateEarningCcipSwap is CcipSwapBase {
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

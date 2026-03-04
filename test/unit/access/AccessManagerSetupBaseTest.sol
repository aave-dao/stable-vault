// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {IAccessManager} from "openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";
import {ProxyAdmin} from "openzeppelin-contracts/contracts/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy
} from "openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {AccessManagerBaseSetup} from "script/base/AccessManagerBaseSetup.sol";
import {RolesLib} from "script/libraries/RolesLib.sol";
import {_toSelectorArray} from "test/helpers/TypeHelpers.sol";

import {Allocator} from "src/core/Allocator.sol";
import {IAllocator} from "src/interfaces/IAllocator.sol";
import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {ICcipBridgeAdapter} from "src/interfaces/ICcipBridgeAdapter.sol";
import {IRescuableNative} from "src/interfaces/IRescuableNative.sol";
import {IRescuableToken} from "src/interfaces/IRescuableToken.sol";
import {PriceOracle} from "src/oracles/price/PriceOracle.sol";
import {TransferHelper} from "src/periphery/TransferHelper.sol";
import {WithdrawalPolicy} from "src/periphery/WithdrawalPolicy.sol";

abstract contract AccessManagerSetupBaseTest is AccessManagerBaseSetup, Test {
    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // HELPERS
    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    function _proxyAdmin() internal view virtual returns (address) {
        // For now we turn the Allocator's Proxy Admin, just because it's shared across all chains
        address allocator = getAllocatorAddress(_deployer());
        bytes32 proxyAdminSlot = 0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103;
        return address(uint160(uint256(vm.load(allocator, proxyAdminSlot))));
    }

    /// Deploys CreateX from its pre-compiled Hardhat artifact to the given address.
    /// Required because CreateX uses `pragma solidity 0.8.23;` (exact) which is incompatible
    /// with the project's fixed `solc_version = "0.8.28"`, so no Foundry artifact exists.
    /// Replicates forge-std's `deployCodeTo` logic: etch creation code, call to run constructor
    /// (correctly setting the `_SELF` immutable), then etch the resulting runtime bytecode.
    function _deployCreateXTo(address where) internal {
        // It's OK to use the readFile cheatcode here for the CreateX artifact.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory artifact = vm.readFile("lib/createx/artifacts/src/CreateX.sol/CreateX.json");
        bytes memory creationCode = vm.parseJsonBytes(artifact, ".bytecode");
        vm.etch(where, creationCode);
        (bool success, bytes memory runtimeBytecode) = where.call("");
        require(success, "CreateX deployment failed");
        vm.etch(where, runtimeBytecode);
    }

    function _getAllRoleIds() internal pure returns (uint64[] memory) {
        RolesLib.Role[] memory functionRoles = RolesLib.getAllFunctionBasedRoles();
        uint64[] memory allIds = new uint64[](3 + functionRoles.length);
        allIds[0] = RolesLib.ADMIN_ROLE;
        allIds[1] = RolesLib.ADMIN_ROLE_GUARDIAN_ROLE;
        allIds[2] = RolesLib.OPERATIONAL_ROLE_GUARDIAN_ROLE;
        for (uint256 i = 0; i < functionRoles.length; i++) {
            allIds[3 + i] = functionRoles[i].roleId;
        }
        return allIds;
    }

    function _allFunctionBasedRoleIds() internal pure returns (uint64[] memory) {
        RolesLib.Role[] memory roles = RolesLib.getAllFunctionBasedRoles();
        uint64[] memory ids = new uint64[](roles.length);
        for (uint256 i = 0; i < roles.length; i++) {
            ids[i] = roles[i].roleId;
        }
        return ids;
    }

    function _contains(uint64[] memory arr, uint64 value) internal pure returns (bool) {
        for (uint256 i = 0; i < arr.length; i++) {
            if (arr[i] == value) {
                return true;
            }
        }
        return false;
    }

    function _assertProfileHasExactlyTheseRoles(address profile, uint64[] memory expectedRoleIds) internal view {
        uint64[] memory allRoleIds = _getAllRoleIds();
        for (uint256 i = 0; i < allRoleIds.length; i++) {
            (bool hasRole,) = IAccessManager(_accessManager()).hasRole(allRoleIds[i], profile);
            if (_contains(expectedRoleIds, allRoleIds[i])) {
                assertTrue(hasRole, string.concat("Should have role ", vm.toString(uint256(allRoleIds[i]))));
            } else {
                assertFalse(hasRole, string.concat("Should NOT have role ", vm.toString(uint256(allRoleIds[i]))));
            }
        }
    }

    function _assertProfileRoleDelay(address profile, uint64 roleId, uint32 expectedDelay) internal view {
        (, uint32 delay) = IAccessManager(_accessManager()).hasRole(roleId, profile);
        assertEq(delay, expectedDelay, string.concat("Wrong delay for role ", vm.toString(uint256(roleId))));
    }

    function _assertTargetFunctionRole(address target, bytes4 selector, uint64 expectedRoleId) internal view {
        uint64 actual = IAccessManager(_accessManager()).getTargetFunctionRole(target, selector);
        assertEq(actual, expectedRoleId, string.concat("Wrong role for selector ", vm.toString(bytes32(selector))));
    }

    function _assertCanCall(
        address caller,
        address target,
        bytes4 selector,
        bool expectedImmediate,
        uint32 expectedDelay
    ) internal view {
        (bool immediate, uint32 delay) = IAccessManager(_accessManager()).canCall(caller, target, selector);
        assertEq(immediate, expectedImmediate, "canCall: wrong immediate value");
        assertEq(delay, expectedDelay, "canCall: wrong delay value");
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // CONFIGURATION TESTS
    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    ////// Profile role membership //////

    function test_mainAdminProfile_hasTheExpectedRoles() public view {
        uint64[] memory fnIds = _allFunctionBasedRoleIds();
        uint64[] memory expected = new uint64[](3 + fnIds.length);
        expected[0] = RolesLib.ADMIN_ROLE;
        expected[1] = RolesLib.ADMIN_ROLE_GUARDIAN_ROLE;
        expected[2] = RolesLib.OPERATIONAL_ROLE_GUARDIAN_ROLE;
        for (uint256 i = 0; i < fnIds.length; i++) {
            expected[3 + i] = fnIds[i];
        }
        _assertProfileHasExactlyTheseRoles(_getProfile__MainAdmin(), expected);

        _assertProfileRoleDelay(_getProfile__MainAdmin(), RolesLib.ADMIN_ROLE, RolesLib.CRITICAL_DELAY);
        _assertProfileRoleDelay(_getProfile__MainAdmin(), RolesLib.ADMIN_ROLE_GUARDIAN_ROLE, RolesLib.NO_DELAY);
        _assertProfileRoleDelay(_getProfile__MainAdmin(), RolesLib.OPERATIONAL_ROLE_GUARDIAN_ROLE, RolesLib.NO_DELAY);

        RolesLib.Role[] memory roles = RolesLib.getAllFunctionBasedRoles();
        for (uint256 i = 0; i < roles.length; i++) {
            _assertProfileRoleDelay(_getProfile__MainAdmin(), roles[i].roleId, roles[i].delay);
        }
    }

    function test_secondaryAdminProfile_hasTheExpectedRoles() public view {
        RolesLib.Role[] memory allRoles = RolesLib.getAllFunctionBasedRoles();

        // Count non-critical roles
        uint256 nonCriticalCount = 0;
        for (uint256 i = 0; i < allRoles.length; i++) {
            if (!allRoles[i].hasCriticalRisk) {
                nonCriticalCount++;
            }
        }

        uint64[] memory expected = new uint64[](1 + nonCriticalCount);
        expected[0] = RolesLib.OPERATIONAL_ROLE_GUARDIAN_ROLE;
        uint256 expectedIdx = 1;
        for (uint256 i = 0; i < allRoles.length; i++) {
            if (!allRoles[i].hasCriticalRisk) {
                expected[expectedIdx] = allRoles[i].roleId;
                expectedIdx++;
            }
        }
        _assertProfileHasExactlyTheseRoles(_getProfile__SecondaryAdmin(), expected);

        _assertProfileRoleDelay(
            _getProfile__SecondaryAdmin(), RolesLib.OPERATIONAL_ROLE_GUARDIAN_ROLE, RolesLib.NO_DELAY
        );

        for (uint256 i = 0; i < allRoles.length; i++) {
            if (!allRoles[i].hasCriticalRisk) {
                _assertProfileRoleDelay(_getProfile__SecondaryAdmin(), allRoles[i].roleId, allRoles[i].delay);
            }
        }
    }

    function test_withdrawalPolicyManagerProfile_hasTheExpectedRoles() public view {
        uint64[] memory expected = new uint64[](2);
        expected[0] = RolesLib.getRole__setDefaultFeeBps().roleId;
        expected[1] = RolesLib.getRole__setAssetFeeBps().roleId;
        _assertProfileHasExactlyTheseRoles(_getProfile__WithdrawalPolicyManager(), expected);

        _assertProfileRoleDelay(
            _getProfile__WithdrawalPolicyManager(), expected[0], RolesLib.getRole__setDefaultFeeBps().delay
        );
        _assertProfileRoleDelay(
            _getProfile__WithdrawalPolicyManager(), expected[1], RolesLib.getRole__setAssetFeeBps().delay
        );
    }

    function test_rebalancerProfile_hasTheExpectedRoles() public view {
        uint64[] memory expected = new uint64[](7);
        expected[0] = RolesLib.getRole__rebalance().roleId;
        expected[1] = RolesLib.getRole__setDefaultStrategy().roleId;
        expected[2] = RolesLib.getRole__disableDepositsToStrategy().roleId;
        expected[3] = RolesLib.getRole__pushFundsToChain().roleId;
        expected[4] = RolesLib.getRole__pushFundsToAccountingChain().roleId;
        expected[5] = RolesLib.getRole__setDefaultBridgeAdapter().roleId;
        expected[6] = RolesLib.getRole__topup().roleId;
        _assertProfileHasExactlyTheseRoles(_getProfile__Rebalancer(), expected);

        for (uint256 i = 0; i < expected.length; i++) {
            _assertProfileRoleDelay(_getProfile__Rebalancer(), expected[i], RolesLib.NO_DELAY);
        }
    }

    function test_disablerProfile_hasTheExpectedRoles() public view {
        uint64[] memory expected = new uint64[](12);
        expected[0] = RolesLib.getRole__rebalance().roleId;
        expected[1] = RolesLib.getRole__removeStrategy().roleId;
        expected[2] = RolesLib.getRole__rescueTokens().roleId;
        expected[3] = RolesLib.getRole__rescueNative().roleId;
        expected[4] = RolesLib.getRole__disableAllocatorDeposits().roleId;
        expected[5] = RolesLib.getRole__disableUserDeposits().roleId;
        expected[6] = RolesLib.getRole__disableSwapInput().roleId;
        expected[7] = RolesLib.getRole__disableSwapOutput().roleId;
        expected[8] = RolesLib.getRole__distrustAsset().roleId;
        expected[9] = RolesLib.getRole__removeBridgeAdapter().roleId;
        expected[10] = RolesLib.getRole__disableDepositsToStrategy().roleId;
        expected[11] = RolesLib.getRole__setDefaultStrategy().roleId;
        _assertProfileHasExactlyTheseRoles(_getProfile__Disabler(), expected);

        for (uint256 i = 0; i < expected.length; i++) {
            _assertProfileRoleDelay(_getProfile__Disabler(), expected[i], RolesLib.NO_DELAY);
        }
    }

    function test_aTokenVaultRewardClaimerProfile_hasTheExpectedRoles() public view {
        uint64[] memory expected = new uint64[](1);
        expected[0] = RolesLib.getRole__claimMerklRewards().roleId;
        _assertProfileHasExactlyTheseRoles(_getProfile__ATokenVaultRewardClaimer(), expected);
        _assertProfileRoleDelay(_getProfile__ATokenVaultRewardClaimer(), expected[0], RolesLib.NO_DELAY);
    }

    ////// Critical roles exclusivity //////

    function test_criticalRoles_areOnlyAssignedToMainAdmin() public view {
        RolesLib.Role[] memory roles = RolesLib.getAllFunctionBasedRoles();

        address[] memory allProfiles = _getAllProfiles();

        for (uint256 i = 0; i < roles.length; i++) {
            if (roles[i].hasCriticalRisk) {
                for (uint256 j = 0; j < allProfiles.length; j++) {
                    (bool has,) = IAccessManager(_accessManager()).hasRole(roles[i].roleId, allProfiles[j]);
                    if (allProfiles[j] == _getProfile__MainAdmin()) {
                        assertTrue(
                            has,
                            string.concat("MainAdmin should have critical role ", vm.toString(uint256(roles[i].roleId)))
                        );
                    } else {
                        assertFalse(
                            has,
                            string.concat(
                                "Profile ",
                                vm.toString(allProfiles[j]),
                                " should NOT have critical role ",
                                vm.toString(uint256(roles[i].roleId))
                            )
                        );
                    }
                }
            }
        }
    }

    function _getAllProfiles() internal view virtual returns (address[] memory) {
        address[] memory profiles = new address[](6);
        profiles[0] = _getProfile__MainAdmin();
        profiles[1] = _getProfile__SecondaryAdmin();
        profiles[2] = _getProfile__WithdrawalPolicyManager();
        profiles[3] = _getProfile__Rebalancer();
        profiles[4] = _getProfile__Disabler();
        profiles[5] = _getProfile__ATokenVaultRewardClaimer();
        return profiles;
    }

    ////// Role ID uniqueness //////

    function test_allFunctionBasedRoles_doesNotHaveCollisions() public pure {
        RolesLib.Role[] memory roles = RolesLib.getAllFunctionBasedRoles();
        for (uint256 i = 0; i < roles.length; i++) {
            for (uint256 j = i + 1; j < roles.length; j++) {
                assertNotEq(
                    roles[i].roleId,
                    roles[j].roleId,
                    string.concat(
                        "Role ID collision between selectors ",
                        vm.toString(bytes32(roles[i].selector)),
                        " and ",
                        vm.toString(bytes32(roles[j].selector))
                    )
                );
            }
        }
    }

    ////// Role configuration //////

    function test_allRoleGuardians_matchRolesLib() public view {
        RolesLib.Role[] memory roles = RolesLib.getAllFunctionBasedRoles();
        for (uint256 i = 0; i < roles.length; i++) {
            uint64 guardian = IAccessManager(_accessManager()).getRoleGuardian(roles[i].roleId);
            assertEq(
                guardian,
                roles[i].guardianRoleId,
                string.concat("Wrong guardian for role ", vm.toString(uint256(roles[i].roleId)))
            );
        }
    }

    function test_allRoleAdmins_matchExpected() public view {
        RolesLib.Role[] memory roles = RolesLib.getAllFunctionBasedRoles();
        for (uint256 i = 0; i < roles.length; i++) {
            uint64 admin = IAccessManager(_accessManager()).getRoleAdmin(roles[i].roleId);
            assertEq(
                admin,
                roles[i].guardianRoleId,
                string.concat("Wrong admin for role ", vm.toString(uint256(roles[i].roleId)))
            );
        }
    }

    function test_allRoleGrantDelays_matchRolesLib() public view {
        RolesLib.Role[] memory roles = RolesLib.getAllFunctionBasedRoles();
        for (uint256 i = 0; i < roles.length; i++) {
            uint32 grantDelay = IAccessManager(_accessManager()).getRoleGrantDelay(roles[i].roleId);
            assertEq(
                grantDelay,
                roles[i].delay,
                string.concat("Wrong grant delay for role ", vm.toString(uint256(roles[i].roleId)))
            );
        }
    }

    function test_accessManagerTargetAdminDelay() public view {
        uint32 delay = IAccessManager(_accessManager()).getTargetAdminDelay(address(IAccessManager(_accessManager())));
        assertEq(delay, RolesLib.CRITICAL_DELAY);
    }

    ////// Deployer revocation //////

    function test_deployer_hasNoRoles() public view {
        uint64[] memory empty = new uint64[](0);
        _assertProfileHasExactlyTheseRoles(_deployer(), empty);
    }

    ////// Target-function-role mappings //////

    function test_targetSetup_ccipAdapter() public view {
        address target = getCcipAdapterAddress(_deployer());
        _assertTargetFunctionRole(
            target,
            IBridgeAdapter.setDestinationChainAdapter.selector,
            RolesLib.getRole__setDestinationChainAdapter().roleId
        );
        _assertTargetFunctionRole(
            target, ICcipBridgeAdapter.setChainSelector.selector, RolesLib.getRole__setChainSelector().roleId
        );
        _assertTargetFunctionRole(
            target, IRescuableNative.rescueNative.selector, RolesLib.getRole__rescueNative().roleId
        );
        _assertTargetFunctionRole(
            target, ICcipBridgeAdapter.replayFundsReceiving.selector, RolesLib.getRole__replayFundsReceiving().roleId
        );
        _assertTargetFunctionRole(
            target, IRescuableToken.rescueTokens.selector, RolesLib.getRole__rescueTokens().roleId
        );
    }

    function test_targetSetup_priceOracle() public view {
        address target = getPriceOracleAddress(_deployer());
        _assertTargetFunctionRole(
            target, PriceOracle.setOracleAdapterForAsset.selector, RolesLib.getRole__setOracleAdapterForAsset().roleId
        );
    }

    function test_targetSetup_allocator() public view {
        address target = getAllocatorAddress(_deployer());
        _assertTargetFunctionRole(target, IAllocator.rebalance.selector, RolesLib.getRole__rebalance().roleId);
        _assertTargetFunctionRole(target, IAllocator.addStrategy.selector, RolesLib.getRole__addStrategy().roleId);
        _assertTargetFunctionRole(target, IAllocator.removeStrategy.selector, RolesLib.getRole__removeStrategy().roleId);
        _assertTargetFunctionRole(
            target, IAllocator.disableDepositsToStrategy.selector, RolesLib.getRole__disableDepositsToStrategy().roleId
        );
        _assertTargetFunctionRole(
            target, IAllocator.setDefaultStrategy.selector, RolesLib.getRole__setDefaultStrategy().roleId
        );
        _assertTargetFunctionRole(
            target, IAllocator.enableDepositsToStrategy.selector, RolesLib.getRole__enableDepositsToStrategy().roleId
        );
        _assertTargetFunctionRole(target, IAllocator.topup.selector, RolesLib.getRole__topup().roleId);
    }

    function test_targetSetup_withdrawalPolicy() public view {
        address target = getWithdrawalPolicyAddress(_deployer());
        _assertTargetFunctionRole(
            target, WithdrawalPolicy.setAssetFeeBps.selector, RolesLib.getRole__setAssetFeeBps().roleId
        );
        _assertTargetFunctionRole(
            target, WithdrawalPolicy.setDefaultFeeBps.selector, RolesLib.getRole__setDefaultFeeBps().roleId
        );
        _assertTargetFunctionRole(target, WithdrawalPolicy.setSigner.selector, RolesLib.getRole__setSigner().roleId);
    }

    function test_targetSetup_assetRegistry() public view {
        address target = getAssetRegistryAddress(_deployer());
        _assertTargetFunctionRole(
            target, IAssetRegistry.setAssetConfig.selector, RolesLib.getRole__setAssetConfig().roleId
        );
        _assertTargetFunctionRole(
            target,
            IAssetRegistry.disableAllocatorDeposits.selector,
            RolesLib.getRole__disableAllocatorDeposits().roleId
        );
        _assertTargetFunctionRole(
            target, IAssetRegistry.disableSwapInput.selector, RolesLib.getRole__disableSwapInput().roleId
        );
        _assertTargetFunctionRole(
            target, IAssetRegistry.disableSwapOutput.selector, RolesLib.getRole__disableSwapOutput().roleId
        );
        _assertTargetFunctionRole(
            target, IAssetRegistry.disableUserDeposits.selector, RolesLib.getRole__disableUserDeposits().roleId
        );
        _assertTargetFunctionRole(
            target, IAssetRegistry.enableAllocatorDeposits.selector, RolesLib.getRole__enableAllocatorDeposits().roleId
        );
        _assertTargetFunctionRole(
            target, IAssetRegistry.enableSwapInput.selector, RolesLib.getRole__enableSwapInput().roleId
        );
        _assertTargetFunctionRole(
            target, IAssetRegistry.enableSwapOutput.selector, RolesLib.getRole__enableSwapOutput().roleId
        );
        _assertTargetFunctionRole(
            target, IAssetRegistry.enableUserDeposits.selector, RolesLib.getRole__enableUserDeposits().roleId
        );
        _assertTargetFunctionRole(target, IAssetRegistry.trustAsset.selector, RolesLib.getRole__trustAsset().roleId);
        _assertTargetFunctionRole(
            target, IAssetRegistry.distrustAsset.selector, RolesLib.getRole__distrustAsset().roleId
        );
    }

    function test_targetSetup_aTokenVaultAddresses() public view {
        RolesLib.Role memory role = RolesLib.getRole__claimMerklRewards();
        address[] memory vaults = _aTokenVaultAddresses();
        for (uint256 i = 0; i < vaults.length; i++) {
            _assertTargetFunctionRole(vaults[i], role.selector, role.roleId);
        }
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // SECURITY PROPERTY TESTS
    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    ////// canCall scope + delay //////

    function test_canCall_mainAdmin() public view {
        address admin = _getProfile__MainAdmin();

        // Admin-tier function (MED_DELAY): has role but delayed
        _assertCanCall(
            admin, getAllocatorAddress(_deployer()), IAllocator.addStrategy.selector, false, RolesLib.MED_DELAY
        );

        // Operational function (NO_DELAY): immediate
        _assertCanCall(admin, getAllocatorAddress(_deployer()), IAllocator.rebalance.selector, true, 0);

        // Unconfigured target (ProxyAdmin): ADMIN_ROLE fallback -> CRITICAL_DELAY
        _assertCanCall(admin, _proxyAdmin(), ProxyAdmin.upgradeAndCall.selector, false, RolesLib.CRITICAL_DELAY);
    }

    function test_canCall_secondaryAdmin() public view {
        address admin = _getProfile__SecondaryAdmin();

        // Non-critical function (NO_DELAY): immediate
        _assertCanCall(admin, getAllocatorAddress(_deployer()), IAllocator.rebalance.selector, true, 0);

        // Critical function: unauthorized (not granted to SecondaryAdmin)
        _assertCanCall(admin, getAllocatorAddress(_deployer()), IAllocator.addStrategy.selector, false, 0);

        // Unconfigured target: no ADMIN_ROLE -> unauthorized
        _assertCanCall(admin, _proxyAdmin(), ProxyAdmin.upgradeAndCall.selector, false, 0);
    }

    function test_canCall_rebalancer() public view {
        address rebalancer = _getProfile__Rebalancer();

        _assertCanCall(rebalancer, getAllocatorAddress(_deployer()), IAllocator.rebalance.selector, true, 0);
        _assertCanCall(rebalancer, getAllocatorAddress(_deployer()), IAllocator.topup.selector, true, 0);
        // Unauthorized functions
        _assertCanCall(rebalancer, getAllocatorAddress(_deployer()), IAllocator.removeStrategy.selector, false, 0);
        _assertCanCall(rebalancer, getAllocatorAddress(_deployer()), IAllocator.addStrategy.selector, false, 0);
    }

    function test_canCall_disabler() public view {
        address disabler = _getProfile__Disabler();

        _assertCanCall(disabler, getAllocatorAddress(_deployer()), IAllocator.rebalance.selector, true, 0);
        _assertCanCall(disabler, getAssetRegistryAddress(_deployer()), IAssetRegistry.distrustAsset.selector, true, 0);
        _assertCanCall(disabler, getAllocatorAddress(_deployer()), IAllocator.setDefaultStrategy.selector, true, 0);
        _assertCanCall(
            disabler, getAllocatorAddress(_deployer()), IAllocator.disableDepositsToStrategy.selector, true, 0
        );
        // Unauthorized
        _assertCanCall(disabler, getAllocatorAddress(_deployer()), IAllocator.addStrategy.selector, false, 0);
        _assertCanCall(disabler, getAllocatorAddress(_deployer()), IAllocator.topup.selector, false, 0);
    }

    function test_canCall_withdrawalPolicyManager() public view {
        address wpm = _getProfile__WithdrawalPolicyManager();

        _assertCanCall(
            wpm, getWithdrawalPolicyAddress(_deployer()), WithdrawalPolicy.setDefaultFeeBps.selector, true, 0
        );
        // Unauthorized
        _assertCanCall(wpm, getAllocatorAddress(_deployer()), IAllocator.rebalance.selector, false, 0);
        _assertCanCall(wpm, getAllocatorAddress(_deployer()), IAllocator.topup.selector, false, 0);
    }

    function test_canCall_aTokenVaultRewardClaimer() public view {
        address claimer = _getProfile__ATokenVaultRewardClaimer();
        RolesLib.Role memory role = RolesLib.getRole__claimMerklRewards();
        address[] memory vaults = _aTokenVaultAddresses();

        for (uint256 i = 0; i < vaults.length; i++) {
            _assertCanCall(claimer, vaults[i], role.selector, true, 0);
        }
        // Unauthorized
        _assertCanCall(claimer, getAllocatorAddress(_deployer()), IAllocator.rebalance.selector, false, 0);
        _assertCanCall(claimer, getAllocatorAddress(_deployer()), IAllocator.topup.selector, false, 0);
    }

    ////// ADMIN_ROLE has critical delay as execution timelock //////

    function test_adminRole_hasCriticalDelay_enforcedOnExecution() public {
        IAccessManager accessManager = IAccessManager(_accessManager());
        address admin = _getProfile__MainAdmin();

        (bool hasRole, uint32 delay) = accessManager.hasRole(RolesLib.ADMIN_ROLE, admin);
        assertTrue(hasRole);
        assertEq(delay, RolesLib.CRITICAL_DELAY);

        // Direct call to setTargetFunctionRole reverts (needs scheduling)
        bytes memory callData = abi.encodeCall(
            IAccessManager.setTargetFunctionRole, (address(0x1234), _toSelectorArray(bytes4(0xdeadbeef)), uint64(99))
        );
        bytes32 operationId = accessManager.hashOperation(admin, address(accessManager), callData);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, operationId));
        accessManager.setTargetFunctionRole(address(0x1234), _toSelectorArray(bytes4(0xdeadbeef)), uint64(99));

        // Schedule the operation
        vm.prank(admin);
        accessManager.schedule(address(accessManager), callData, 0);

        // warp CRITICAL_DELAY
        vm.warp(block.timestamp + RolesLib.CRITICAL_DELAY);

        // Execute the operation to show that it works after the critical delay elapses
        vm.prank(admin);
        accessManager.setTargetFunctionRole(address(0x1234), _toSelectorArray(bytes4(0xdeadbeef)), uint64(99));
    }

    ////// Upgrades to transparent proxies have critical delay as timelock //////

    function test_proxyUpgrades_hasCriticalDelayAsTimelock() public {
        IAccessManager accessManager = IAccessManager(_accessManager());
        address admin = _getProfile__MainAdmin();
        address proxyAdmin = _proxyAdmin();

        _assertCanCall(admin, proxyAdmin, ProxyAdmin.upgradeAndCall.selector, false, RolesLib.CRITICAL_DELAY);

        // Create addresses to avoid zero-address reverts
        address assetRegistry = makeAddr("ASSET_REGISTRY");
        address priceOracle = makeAddr("PRICE_ORACLE");
        address depositor = makeAddr("DEPOSITOR");
        address withdrawer = makeAddr("WITHDRAWER");
        address transferHelper = address(new TransferHelper());

        address newImpl = address(new Allocator(assetRegistry, depositor, withdrawer, priceOracle, transferHelper, 1));
        bytes memory callData = abi.encodeCall(
            ProxyAdmin.upgradeAndCall, (ITransparentUpgradeableProxy(getAllocatorAddress(_deployer())), newImpl, "")
        );
        bytes32 operationId = accessManager.hashOperation(admin, proxyAdmin, callData);

        // Direct call reverts (needs scheduling)
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotScheduled.selector, operationId));
        accessManager.execute(proxyAdmin, callData);

        // Schedule
        vm.prank(admin);
        accessManager.schedule(proxyAdmin, callData, 0);
        assertTrue(accessManager.getSchedule(operationId) > 0, "Operation should be scheduled");

        // Execute before CRITICAL_DELAY -> reverts
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(IAccessManager.AccessManagerNotReady.selector, operationId));
        accessManager.execute(proxyAdmin, callData);

        // Warp CRITICAL_DELAY
        vm.warp(block.timestamp + RolesLib.CRITICAL_DELAY);

        // Execute after delay -> upgrade succeeds
        vm.prank(admin);
        accessManager.execute(proxyAdmin, callData);
    }

    function test_proxyUpgrades_unauthorizedForAllProfilesExceptMainAdmin() public view {
        address proxy = _proxyAdmin();

        // MainAdmin has ADMIN_ROLE, fallback with CRITICAL_DELAY
        _assertCanCall(
            _getProfile__MainAdmin(), proxy, ProxyAdmin.upgradeAndCall.selector, false, RolesLib.CRITICAL_DELAY
        );

        // Rest of profiles do not have ADMIN_ROLE, unauthorized
        _assertCanCall(_getProfile__SecondaryAdmin(), proxy, ProxyAdmin.upgradeAndCall.selector, false, 0);
        _assertCanCall(_getProfile__Rebalancer(), proxy, ProxyAdmin.upgradeAndCall.selector, false, 0);
        _assertCanCall(_getProfile__Disabler(), proxy, ProxyAdmin.upgradeAndCall.selector, false, 0);
        _assertCanCall(_getProfile__WithdrawalPolicyManager(), proxy, ProxyAdmin.upgradeAndCall.selector, false, 0);
        _assertCanCall(_getProfile__ATokenVaultRewardClaimer(), proxy, ProxyAdmin.upgradeAndCall.selector, false, 0);
    }

    ////// Grant delay gives a security time window to prevent bypassing execution delay attack //////

    function test_grantDelay_preventsExecutionDelayBypass() public {
        IAccessManager accessManager = IAccessManager(_accessManager());
        address admin = _getProfile__MainAdmin();
        address newAddr = makeAddr("NEW_ADDRESS_GRANT_DELAY_TEST");

        // Admin-tier role (MED_DELAY grant delay)
        RolesLib.Role memory role = RolesLib.getRole__addStrategy();

        // Calls grantRole (MainAdmin holds ADMIN_ROLE_GUARDIAN_ROLE without execution delay)
        vm.prank(admin);
        accessManager.grantRole(role.roleId, newAddr, uint32(0));

        // Grant delay (MED_DELAY) blocks activation
        (bool hasNow,) = accessManager.hasRole(role.roleId, newAddr);
        assertFalse(hasNow, "Role should not be active yet (grant delay)");

        // Warp 1 second less than MED_DELAY
        vm.warp(block.timestamp + RolesLib.MED_DELAY - 1);

        (hasNow,) = accessManager.hasRole(role.roleId, newAddr);
        assertFalse(hasNow, "Role should not be active yet (grant delay)");

        // Warp one more second to make MED_DELAY fully elapse
        vm.warp(block.timestamp + 1);

        (bool hasAfter,) = accessManager.hasRole(role.roleId, newAddr);
        assertTrue(hasAfter, "Role should be active after grant delay");
    }

    ////// Roles take grant delay to be added //////

    function test_roleGrant_takesGrantDelayToActivate(uint256 timeElapsed) public {
        IAccessManager accessManager = IAccessManager(_accessManager());
        address admin = _getProfile__MainAdmin();
        address newAddr = makeAddr("GRANT_DELAY_FUZZ_TEST");

        // Admin-tier role (MED_DELAY grant delay)
        RolesLib.Role memory role = RolesLib.getRole__addStrategy();
        uint32 grantDelay = accessManager.getRoleGrantDelay(role.roleId);

        // Fuzz time in [0, grantDelay) -> role should NOT be active
        timeElapsed = bound(timeElapsed, 0, uint256(grantDelay) - 1);

        // Direct grantRole
        vm.prank(admin);
        accessManager.grantRole(role.roleId, newAddr, uint32(0));

        // Warp timeElapsed (still within grant delay)
        vm.warp(block.timestamp + timeElapsed);
        (bool hasDuring,) = accessManager.hasRole(role.roleId, newAddr);
        assertFalse(hasDuring, "Role should not be active before grant delay expires");

        // Warp remaining time to pass grant delay
        vm.warp(block.timestamp + uint256(grantDelay) - timeElapsed + 1);
        (bool hasAfter,) = accessManager.hasRole(role.roleId, newAddr);
        assertTrue(hasAfter, "Role should be active after grant delay");
    }

    ////// Role granting can be revoked during grant delay period //////

    function test_roleGrant_canBeRevokedDuringGrantDelay(uint256 secondsToElapseBeforeRevoking) public {
        secondsToElapseBeforeRevoking = bound(secondsToElapseBeforeRevoking, 0, RolesLib.MED_DELAY - 1);

        IAccessManager accessManager = IAccessManager(_accessManager());
        address admin = _getProfile__MainAdmin();
        address newAddr = makeAddr("REVOKE_DURING_GRANT_DELAY_TEST");

        // Admin-tier role (MED_DELAY grant delay)
        RolesLib.Role memory role = RolesLib.getRole__addStrategy();

        // Grant role -> pending (not active yet due to grant delay)
        vm.prank(admin);
        accessManager.grantRole(role.roleId, newAddr, uint32(0));
        uint256 grantTimestamp = block.timestamp;

        (bool hasPending,) = accessManager.hasRole(role.roleId, newAddr);
        assertFalse(hasPending, "Role should not be active yet (grant delay)");

        // Warp some time (less than the grant delay)
        vm.warp(grantTimestamp + secondsToElapseBeforeRevoking);

        // Revoke during grant delay -> cancels the pending grant
        vm.prank(admin);
        accessManager.revokeRole(role.roleId, newAddr);
        (bool hasAfterRevoke,) = accessManager.hasRole(role.roleId, newAddr);
        assertFalse(hasAfterRevoke, "Role should be revoked");

        // Even after grant delay passes, role stays revoked
        vm.warp(grantTimestamp + RolesLib.MED_DELAY + 1);
        (bool hasAfterDelay,) = accessManager.hasRole(role.roleId, newAddr);
        assertFalse(hasAfterDelay, "Role should remain revoked after grant delay period");
    }

    ////// Role revocation is immediate //////

    function test_roleRevocation_effectIsImmediate() public {
        IAccessManager accessManager = IAccessManager(_accessManager());
        address mainAdmin = _getProfile__MainAdmin();
        address secondaryAdmin = _getProfile__SecondaryAdmin();

        RolesLib.Role memory role = RolesLib.getRole__rebalance();

        (bool hasBefore,) = accessManager.hasRole(role.roleId, secondaryAdmin);
        assertTrue(hasBefore, "SecondaryAdmin should have role before revocation");

        // Direct revokeRole -> immediate effect
        vm.prank(mainAdmin);
        accessManager.revokeRole(role.roleId, secondaryAdmin);

        (bool hasAfter,) = accessManager.hasRole(role.roleId, secondaryAdmin);
        assertFalse(hasAfter, "Revocation should take effect immediately");
    }

    ////// Guardian can cancel operations instantly //////

    function test_guardian_canCancelInstantly() public {
        IAccessManager accessManager = IAccessManager(_accessManager());
        address admin = _getProfile__MainAdmin();

        // Schedule admin-tier operation on Allocator
        bytes memory callData = abi.encodeCall(IAllocator.addStrategy, (address(0x1), address(0x2), uint8(0)));
        bytes32 operationId = accessManager.hashOperation(admin, getAllocatorAddress(_deployer()), callData);

        vm.prank(admin);
        accessManager.schedule(getAllocatorAddress(_deployer()), callData, 0);

        assertTrue(accessManager.getSchedule(operationId) > 0, "Operation should be scheduled");

        // MainAdmin (as ADMIN_ROLE_GUARDIAN_ROLE holder) cancels immediately
        vm.prank(admin);
        accessManager.cancel(admin, getAllocatorAddress(_deployer()), callData);

        assertEq(accessManager.getSchedule(operationId), 0, "Operation should be cancelled");
    }

    ////// SecondaryAdmin cannot cancel admin-tier operations //////

    function test_secondaryAdmin_cannotCancelAdminTierOperation() public {
        IAccessManager accessManager = IAccessManager(_accessManager());
        address admin = _getProfile__MainAdmin();
        address secondary = _getProfile__SecondaryAdmin();

        bytes memory callData = abi.encodeCall(IAllocator.addStrategy, (address(0x1), address(0x2), uint8(0)));

        vm.prank(admin);
        accessManager.schedule(getAllocatorAddress(_deployer()), callData, 0);

        vm.prank(secondary);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedCancel.selector,
                secondary,
                admin,
                getAllocatorAddress(_deployer()),
                IAllocator.addStrategy.selector
            )
        );
        accessManager.cancel(admin, getAllocatorAddress(_deployer()), callData);
    }

    ////// Role management capabilities //////

    function test_mainAdmin_canGrantAnyRole() public {
        IAccessManager accessManager = IAccessManager(_accessManager());
        address admin = _getProfile__MainAdmin();
        address newAddr = makeAddr("NEW_ADDRESS_GRANT_ANY_ROLE_TEST");

        // Operational role (role admin = OPERATIONAL_ROLE_GUARDIAN_ROLE)
        RolesLib.Role memory operationalRole = RolesLib.getRole__rebalance();
        vm.prank(admin);
        accessManager.grantRole(operationalRole.roleId, newAddr, operationalRole.delay);

        // Admin-tier role (role admin = ADMIN_ROLE_GUARDIAN_ROLE)
        RolesLib.Role memory adminTierRole = RolesLib.getRole__addStrategy();
        vm.prank(admin);
        accessManager.grantRole(adminTierRole.roleId, newAddr, adminTierRole.delay);

        // Warp past MED_DELAY -> both roles should be active
        vm.warp(block.timestamp + RolesLib.MED_DELAY + 1);
        (bool hasOperational,) = accessManager.hasRole(operationalRole.roleId, newAddr);
        assertTrue(hasOperational, "MainAdmin should be able to grant operational roles");
        (bool hasAdminTier,) = accessManager.hasRole(adminTierRole.roleId, newAddr);
        assertTrue(hasAdminTier, "MainAdmin should be able to grant admin-tier roles");
    }

    function test_operationalProfiles_cannotGrantOrRevokeRoles() public {
        IAccessManager accessManager = IAccessManager(_accessManager());
        RolesLib.Role memory role = RolesLib.getRole__rebalance();
        address newAddr = makeAddr("ATTACKER");

        // Rebalancer tries grantRole -> reverts
        vm.prank(_getProfile__Rebalancer());
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedAccount.selector,
                _getProfile__Rebalancer(),
                RolesLib.OPERATIONAL_ROLE_GUARDIAN_ROLE
            )
        );
        accessManager.grantRole(role.roleId, newAddr, 0);

        // Disabler tries revokeRole -> reverts
        vm.prank(_getProfile__Disabler());
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedAccount.selector,
                _getProfile__Disabler(),
                RolesLib.OPERATIONAL_ROLE_GUARDIAN_ROLE
            )
        );
        accessManager.revokeRole(role.roleId, _getProfile__SecondaryAdmin());

        // Rebalancer tries admin-tier role -> reverts
        RolesLib.Role memory adminTierRole = RolesLib.getRole__addStrategy();
        vm.prank(_getProfile__Rebalancer());
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedAccount.selector,
                _getProfile__Rebalancer(),
                RolesLib.ADMIN_ROLE_GUARDIAN_ROLE
            )
        );
        accessManager.grantRole(adminTierRole.roleId, newAddr, 0);
    }

    function test_secondaryAdmin_canGrantAndRevokeOperationalRoles() public {
        IAccessManager accessManager = IAccessManager(_accessManager());
        address secondary = _getProfile__SecondaryAdmin();
        address newAddr = makeAddr("SECONDARY_ADMIN_GRANT_TEST");

        // Operational role (NO_DELAY grant delay)
        RolesLib.Role memory role = RolesLib.getRole__rebalance();

        vm.prank(secondary);
        accessManager.grantRole(role.roleId, newAddr, role.delay);

        // NO_DELAY -> role active immediately
        (bool hasRole,) = accessManager.hasRole(role.roleId, newAddr);
        assertTrue(hasRole, "SecondaryAdmin should be able to grant operational roles");

        // Revoke
        vm.prank(secondary);
        accessManager.revokeRole(role.roleId, newAddr);

        (bool hasAfterRevoke,) = accessManager.hasRole(role.roleId, newAddr);
        assertFalse(hasAfterRevoke, "SecondaryAdmin should be able to revoke operational roles");
    }

    function test_secondaryAdmin_cannotGrantOrRevokeAdminTierRoles() public {
        IAccessManager accessManager = IAccessManager(_accessManager());
        address secondary = _getProfile__SecondaryAdmin();
        address newAddr = makeAddr("SECONDARY_ADMIN_TIER_TEST");

        // Admin-tier role (role admin = ADMIN_ROLE_GUARDIAN_ROLE)
        RolesLib.Role memory role = RolesLib.getRole__addStrategy();

        // SecondaryAdmin tries grantRole -> reverts (no ADMIN_ROLE_GUARDIAN_ROLE)
        vm.prank(secondary);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedAccount.selector, secondary, RolesLib.ADMIN_ROLE_GUARDIAN_ROLE
            )
        );
        accessManager.grantRole(role.roleId, newAddr, 0);

        // SecondaryAdmin tries revokeRole -> reverts
        vm.prank(secondary);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedAccount.selector, secondary, RolesLib.ADMIN_ROLE_GUARDIAN_ROLE
            )
        );
        accessManager.revokeRole(role.roleId, _getProfile__MainAdmin());
    }
}

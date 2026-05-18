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
import {RolesConfig} from "script/base/RolesConfig.sol";
import {_toSelectorArray} from "test/helpers/TypeHelpers.sol";

import {Allocator} from "src/core/Allocator.sol";
import {IAllocator} from "src/interfaces/IAllocator.sol";
import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {ICcipBridgeAdapter} from "src/interfaces/ICcipBridgeAdapter.sol";
import {IRescuableNative} from "src/interfaces/IRescuableNative.sol";
import {IRescuableToken} from "src/interfaces/IRescuableToken.sol";
import {PriceOracle} from "src/oracles/price/PriceOracle.sol";
import {SlippageCoverageVault} from "src/periphery/SlippageCoverageVault.sol";
import {TransferHelper} from "src/periphery/TransferHelper.sol";
import {WithdrawalExecutionPolicy} from "src/policies/WithdrawalExecutionPolicy.sol";

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

    function _getAllRoleIds() internal view returns (uint64[] memory) {
        RolesConfig.Role[] memory functionRoles = RolesConfig.getAllFunctionBasedRoles();
        uint64[] memory allIds = new uint64[](3 + functionRoles.length);
        allIds[0] = RolesConfig.ADMIN_ROLE;
        allIds[1] = RolesConfig.ADMIN_ROLE_GUARDIAN_ROLE;
        allIds[2] = RolesConfig.OPERATIONAL_ROLE_GUARDIAN_ROLE;
        for (uint256 i = 0; i < functionRoles.length; i++) {
            allIds[3 + i] = functionRoles[i].roleId;
        }
        return allIds;
    }

    function _allFunctionBasedRoleIds() internal view returns (uint64[] memory) {
        RolesConfig.Role[] memory roles = RolesConfig.getAllFunctionBasedRoles();
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
        expected[0] = RolesConfig.ADMIN_ROLE;
        expected[1] = RolesConfig.ADMIN_ROLE_GUARDIAN_ROLE;
        expected[2] = RolesConfig.OPERATIONAL_ROLE_GUARDIAN_ROLE;
        for (uint256 i = 0; i < fnIds.length; i++) {
            expected[3 + i] = fnIds[i];
        }
        _assertProfileHasExactlyTheseRoles(_getProfile__MainAdmin(), expected);

        _assertProfileRoleDelay(_getProfile__MainAdmin(), RolesConfig.ADMIN_ROLE, CRITICAL_DELAY);
        _assertProfileRoleDelay(_getProfile__MainAdmin(), RolesConfig.ADMIN_ROLE_GUARDIAN_ROLE, RolesConfig.NO_DELAY);
        _assertProfileRoleDelay(
            _getProfile__MainAdmin(), RolesConfig.OPERATIONAL_ROLE_GUARDIAN_ROLE, RolesConfig.NO_DELAY
        );

        RolesConfig.Role[] memory roles = RolesConfig.getAllFunctionBasedRoles();
        for (uint256 i = 0; i < roles.length; i++) {
            _assertProfileRoleDelay(_getProfile__MainAdmin(), roles[i].roleId, roles[i].delay);
        }
    }

    function test_secondaryAdminProfile_hasTheExpectedRoles() public view {
        RolesConfig.Role[] memory allRoles = RolesConfig.getAllFunctionBasedRoles();

        // Count non-critical roles
        uint256 nonCriticalCount = 0;
        for (uint256 i = 0; i < allRoles.length; i++) {
            if (!allRoles[i].hasCriticalRisk) {
                nonCriticalCount++;
            }
        }

        uint64[] memory expected = new uint64[](1 + nonCriticalCount);
        expected[0] = RolesConfig.OPERATIONAL_ROLE_GUARDIAN_ROLE;
        uint256 expectedIdx = 1;
        for (uint256 i = 0; i < allRoles.length; i++) {
            if (!allRoles[i].hasCriticalRisk) {
                expected[expectedIdx] = allRoles[i].roleId;
                expectedIdx++;
            }
        }
        _assertProfileHasExactlyTheseRoles(_getProfile__SecondaryAdmin(), expected);

        _assertProfileRoleDelay(
            _getProfile__SecondaryAdmin(), RolesConfig.OPERATIONAL_ROLE_GUARDIAN_ROLE, RolesConfig.NO_DELAY
        );

        for (uint256 i = 0; i < allRoles.length; i++) {
            if (!allRoles[i].hasCriticalRisk) {
                _assertProfileRoleDelay(_getProfile__SecondaryAdmin(), allRoles[i].roleId, allRoles[i].delay);
            }
        }
    }

    function test_withdrawalPolicyManagerProfile_hasTheExpectedRoles() public view {
        uint64[] memory expected = new uint64[](2);
        expected[0] = RolesConfig.getRole__setDefaultFeeBps().roleId;
        expected[1] = RolesConfig.getRole__setAssetFeeBps().roleId;
        _assertProfileHasExactlyTheseRoles(_getProfile__WithdrawalPolicyManager(), expected);

        _assertProfileRoleDelay(
            _getProfile__WithdrawalPolicyManager(), expected[0], RolesConfig.getRole__setDefaultFeeBps().delay
        );
        _assertProfileRoleDelay(
            _getProfile__WithdrawalPolicyManager(), expected[1], RolesConfig.getRole__setAssetFeeBps().delay
        );
    }

    function test_rebalancerProfile_hasTheExpectedRoles() public view {
        uint64[] memory expected = new uint64[](5);
        expected[0] = RolesConfig.getRole__rebalance().roleId;
        expected[1] = RolesConfig.getRole__setWithdrawalQueue().roleId;
        expected[2] = RolesConfig.getRole__disableDepositsToStrategy().roleId;
        expected[3] = RolesConfig.getRole__pushFundsToChain().roleId;
        expected[4] = RolesConfig.getRole__pushFundsToAccountingChain().roleId;
        _assertProfileHasExactlyTheseRoles(_getProfile__Rebalancer(), expected);

        for (uint256 i = 0; i < expected.length; i++) {
            _assertProfileRoleDelay(_getProfile__Rebalancer(), expected[i], RolesConfig.NO_DELAY);
        }
    }

    function test_funderProfile_hasTheExpectedRoles() public view {
        uint64[] memory expected = new uint64[](2);
        expected[0] = RolesConfig.getRole__topUp().roleId;
        expected[1] = RolesConfig.getRole__fundCoverage().roleId;
        _assertProfileHasExactlyTheseRoles(_getProfile__Funder(), expected);

        // Capital-provider roles live on their own profile, not on the operational Rebalancer.
        assertTrue(_getProfile__Funder() != _getProfile__Rebalancer(), "funder == rebalancer");

        _assertProfileRoleDelay(_getProfile__Funder(), expected[0], RolesConfig.NO_DELAY);
        _assertProfileRoleDelay(_getProfile__Funder(), expected[1], RolesConfig.NO_DELAY);
    }

    function test_coverageGuardianProfile_hasTheExpectedRoles() public view {
        uint64[] memory expected = new uint64[](2);
        expected[0] = RolesConfig.getRole__enableOverrideMode().roleId;
        expected[1] = RolesConfig.getRole__disableOverrideMode().roleId;
        _assertProfileHasExactlyTheseRoles(_getProfile__CoverageGuardian(), expected);

        // Trilemma: CoverageGuardian must NOT also be the Rebalancer.
        assertTrue(_getProfile__CoverageGuardian() != _getProfile__Rebalancer(), "guardian == rebalancer");

        // No on-chain delay on either selector; CoverageGuardian compromise resistance is structural (N-of-M
        // multisig signer composition), not temporal. A timelock would slow legitimate depeg response without
        // changing the worst case (CoverageGuardian + Rebalancer both compromised collapses to vault balance
        // regardless).
        _assertProfileRoleDelay(_getProfile__CoverageGuardian(), expected[0], RolesConfig.NO_DELAY);
        _assertProfileRoleDelay(_getProfile__CoverageGuardian(), expected[1], RolesConfig.NO_DELAY);
    }

    function test_disablerProfile_hasTheExpectedRoles() public view {
        uint64[] memory expected = new uint64[](22);
        // Allocator (defensive)
        expected[0] = RolesConfig.getRole__rebalance().roleId;
        expected[1] = RolesConfig.getRole__removeStrategy().roleId;
        expected[2] = RolesConfig.getRole__disableDepositsToStrategy().roleId;
        expected[3] = RolesConfig.getRole__distrustStrategy().roleId;
        // Rescue (cross-target)
        expected[4] = RolesConfig.getRole__rescueTokens().roleId;
        expected[5] = RolesConfig.getRole__rescueNative().roleId;
        // AssetRegistry (defensive)
        expected[6] = RolesConfig.getRole__disableAllocatorDeposits().roleId;
        expected[7] = RolesConfig.getRole__disableUserDeposits().roleId;
        expected[8] = RolesConfig.getRole__disableSwapInput().roleId;
        expected[9] = RolesConfig.getRole__disableSwapOutput().roleId;
        expected[10] = RolesConfig.getRole__distrustAsset().roleId;
        // Gateway
        expected[11] = RolesConfig.getRole__removeBridgeAdapter().roleId;
        // WithdrawalExecutionPolicy
        expected[12] = RolesConfig.getRole__removeSigner().roleId;
        expected[13] = RolesConfig.getRole__lowerRedemptionCapacity().roleId;
        expected[14] = RolesConfig.getRole__lowerRedemptionRefillRate().roleId;
        // SlippageCoverageVault
        // raiseWindowSeconds is tightening (longer window = slower rate), even though the prefix says raise.
        expected[15] = RolesConfig.getRole__lowerPullCapPerTx().roleId;
        expected[16] = RolesConfig.getRole__lowerWindowCap().roleId;
        expected[17] = RolesConfig.getRole__raiseWindowSeconds().roleId;
        // DepositPolicy
        expected[18] = RolesConfig.getRole__lowerDepositCapacity().roleId;
        expected[19] = RolesConfig.getRole__lowerDepositRefillRate().roleId;
        // FundsBridgingPolicy
        expected[20] = RolesConfig.getRole__lowerBridgingCapacity().roleId;
        expected[21] = RolesConfig.getRole__lowerBridgingRefillRate().roleId;
        _assertProfileHasExactlyTheseRoles(_getProfile__Disabler(), expected);

        for (uint256 i = 0; i < expected.length; i++) {
            _assertProfileRoleDelay(_getProfile__Disabler(), expected[i], RolesConfig.NO_DELAY);
        }
    }

    function test_aTokenVaultRewardClaimerProfile_hasTheExpectedRoles() public view {
        uint64[] memory expected = new uint64[](2);
        expected[0] = RolesConfig.getRole__claimMerklRewards().roleId;
        expected[1] = RolesConfig.getRole__emergencyRescue().roleId;
        _assertProfileHasExactlyTheseRoles(_getProfile__ATokenVaultRewardClaimer(), expected);
        _assertProfileRoleDelay(_getProfile__ATokenVaultRewardClaimer(), expected[0], RolesConfig.NO_DELAY);
        _assertProfileRoleDelay(_getProfile__ATokenVaultRewardClaimer(), expected[1], RolesConfig.NO_DELAY);
    }

    ////// Critical roles exclusivity //////

    function test_criticalRoles_areOnlyAssignedToMainAdmin() public view {
        RolesConfig.Role[] memory roles = RolesConfig.getAllFunctionBasedRoles();

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
        address[] memory profiles = new address[](7);
        profiles[0] = _getProfile__MainAdmin();
        profiles[1] = _getProfile__SecondaryAdmin();
        profiles[2] = _getProfile__WithdrawalPolicyManager();
        profiles[3] = _getProfile__Rebalancer();
        profiles[4] = _getProfile__Disabler();
        profiles[5] = _getProfile__ATokenVaultRewardClaimer();
        profiles[6] = _getProfile__Funder();
        return profiles;
    }

    ////// Role ID uniqueness //////

    function test_allFunctionBasedRoles_doesNotHaveCollisions() public view {
        RolesConfig.Role[] memory roles = RolesConfig.getAllFunctionBasedRoles();
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

    function test_allRoleGuardians_matchRolesConfig() public view {
        RolesConfig.Role[] memory roles = RolesConfig.getAllFunctionBasedRoles();
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
        RolesConfig.Role[] memory roles = RolesConfig.getAllFunctionBasedRoles();
        for (uint256 i = 0; i < roles.length; i++) {
            uint64 admin = IAccessManager(_accessManager()).getRoleAdmin(roles[i].roleId);
            assertEq(
                admin,
                roles[i].guardianRoleId,
                string.concat("Wrong admin for role ", vm.toString(uint256(roles[i].roleId)))
            );
        }
    }

    function test_allRoleGrantDelays_matchRolesConfig() public view {
        RolesConfig.Role[] memory roles = RolesConfig.getAllFunctionBasedRoles();
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
        assertEq(delay, CRITICAL_DELAY);
    }

    function test_delayTiers_areStrictlyAscending() public view {
        assertLt(RolesConfig.NO_DELAY, LOW_DELAY, "NO_DELAY must be less than LOW_DELAY");
        assertLt(LOW_DELAY, MEDIUM_DELAY, "LOW_DELAY must be less than MEDIUM_DELAY");
        assertLt(MEDIUM_DELAY, HIGH_DELAY, "MEDIUM_DELAY must be less than HIGH_DELAY");
        assertLt(HIGH_DELAY, CRITICAL_DELAY, "HIGH_DELAY must be less than CRITICAL_DELAY");
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
            RolesConfig.getRole__setDestinationChainAdapter().roleId
        );
        _assertTargetFunctionRole(
            target, ICcipBridgeAdapter.setChainSelector.selector, RolesConfig.getRole__setChainSelector().roleId
        );
        _assertTargetFunctionRole(
            target, IRescuableNative.rescueNative.selector, RolesConfig.getRole__rescueNative().roleId
        );
        _assertTargetFunctionRole(
            target, ICcipBridgeAdapter.replayFundsReceiving.selector, RolesConfig.getRole__replayFundsReceiving().roleId
        );
        _assertTargetFunctionRole(
            target, IRescuableToken.rescueTokens.selector, RolesConfig.getRole__rescueTokens().roleId
        );
    }

    function test_targetSetup_priceOracle() public view {
        address target = getPriceOracleAddress(_deployer());
        _assertTargetFunctionRole(
            target,
            PriceOracle.setOracleAdapterForAsset.selector,
            RolesConfig.getRole__setOracleAdapterForAsset().roleId
        );
    }

    function test_targetSetup_allocator() public view {
        address target = getAllocatorAddress(_deployer());
        _assertTargetFunctionRole(target, IAllocator.rebalance.selector, RolesConfig.getRole__rebalance().roleId);
        _assertTargetFunctionRole(target, IAllocator.addStrategy.selector, RolesConfig.getRole__addStrategy().roleId);
        _assertTargetFunctionRole(
            target, IAllocator.removeStrategy.selector, RolesConfig.getRole__removeStrategy().roleId
        );
        _assertTargetFunctionRole(
            target,
            IAllocator.disableDepositsToStrategy.selector,
            RolesConfig.getRole__disableDepositsToStrategy().roleId
        );
        _assertTargetFunctionRole(
            target, IAllocator.enableDepositsToStrategy.selector, RolesConfig.getRole__enableDepositsToStrategy().roleId
        );
        _assertTargetFunctionRole(target, IAllocator.topUp.selector, RolesConfig.getRole__topUp().roleId);
        _assertTargetFunctionRole(
            target, IAllocator.trustStrategy.selector, RolesConfig.getRole__trustStrategy().roleId
        );
        _assertTargetFunctionRole(
            target, IAllocator.distrustStrategy.selector, RolesConfig.getRole__distrustStrategy().roleId
        );
        _assertTargetFunctionRole(
            target, IAllocator.setWithdrawalQueue.selector, RolesConfig.getRole__setWithdrawalQueue().roleId
        );
        _assertTargetFunctionRole(
            target, IRescuableToken.rescueTokens.selector, RolesConfig.getRole__rescueTokens().roleId
        );
    }

    function test_targetSetup_withdrawalExecutionPolicy() public view {
        address target = getWithdrawalExecutionPolicyAddress(_deployer());
        _assertTargetFunctionRole(
            target, WithdrawalExecutionPolicy.setAssetFeeBps.selector, RolesConfig.getRole__setAssetFeeBps().roleId
        );
        _assertTargetFunctionRole(
            target, WithdrawalExecutionPolicy.setDefaultFeeBps.selector, RolesConfig.getRole__setDefaultFeeBps().roleId
        );
        _assertTargetFunctionRole(
            target, WithdrawalExecutionPolicy.addSigner.selector, RolesConfig.getRole__addSigner().roleId
        );
        _assertTargetFunctionRole(
            target, WithdrawalExecutionPolicy.removeSigner.selector, RolesConfig.getRole__removeSigner().roleId
        );
    }

    function test_targetSetup_assetRegistry() public view {
        address target = getAssetRegistryAddress(_deployer());
        _assertTargetFunctionRole(
            target, IAssetRegistry.setAssetConfig.selector, RolesConfig.getRole__setAssetConfig().roleId
        );
        _assertTargetFunctionRole(
            target,
            IAssetRegistry.disableAllocatorDeposits.selector,
            RolesConfig.getRole__disableAllocatorDeposits().roleId
        );
        _assertTargetFunctionRole(
            target, IAssetRegistry.disableSwapInput.selector, RolesConfig.getRole__disableSwapInput().roleId
        );
        _assertTargetFunctionRole(
            target, IAssetRegistry.disableSwapOutput.selector, RolesConfig.getRole__disableSwapOutput().roleId
        );
        _assertTargetFunctionRole(
            target, IAssetRegistry.disableUserDeposits.selector, RolesConfig.getRole__disableUserDeposits().roleId
        );
        _assertTargetFunctionRole(
            target,
            IAssetRegistry.enableAllocatorDeposits.selector,
            RolesConfig.getRole__enableAllocatorDeposits().roleId
        );
        _assertTargetFunctionRole(
            target, IAssetRegistry.enableSwapInput.selector, RolesConfig.getRole__enableSwapInput().roleId
        );
        _assertTargetFunctionRole(
            target, IAssetRegistry.enableSwapOutput.selector, RolesConfig.getRole__enableSwapOutput().roleId
        );
        _assertTargetFunctionRole(
            target, IAssetRegistry.enableUserDeposits.selector, RolesConfig.getRole__enableUserDeposits().roleId
        );
        _assertTargetFunctionRole(target, IAssetRegistry.trustAsset.selector, RolesConfig.getRole__trustAsset().roleId);
        _assertTargetFunctionRole(
            target, IAssetRegistry.distrustAsset.selector, RolesConfig.getRole__distrustAsset().roleId
        );
    }

    function test_targetSetup_slippageCoverageVault() public view {
        address target = getSlippageCoverageVaultAddress(_deployer());
        _assertTargetFunctionRole(
            target, SlippageCoverageVault.enableOverrideMode.selector, RolesConfig.getRole__enableOverrideMode().roleId
        );
        _assertTargetFunctionRole(
            target,
            SlippageCoverageVault.disableOverrideMode.selector,
            RolesConfig.getRole__disableOverrideMode().roleId
        );
        _assertTargetFunctionRole(
            target, SlippageCoverageVault.raisePullCapPerTx.selector, RolesConfig.getRole__raisePullCapPerTx().roleId
        );
        _assertTargetFunctionRole(
            target, SlippageCoverageVault.lowerPullCapPerTx.selector, RolesConfig.getRole__lowerPullCapPerTx().roleId
        );
        _assertTargetFunctionRole(
            target, SlippageCoverageVault.raiseWindowCap.selector, RolesConfig.getRole__raiseWindowCap().roleId
        );
        _assertTargetFunctionRole(
            target, SlippageCoverageVault.lowerWindowCap.selector, RolesConfig.getRole__lowerWindowCap().roleId
        );
        _assertTargetFunctionRole(
            target, SlippageCoverageVault.raiseWindowSeconds.selector, RolesConfig.getRole__raiseWindowSeconds().roleId
        );
        _assertTargetFunctionRole(
            target, SlippageCoverageVault.lowerWindowSeconds.selector, RolesConfig.getRole__lowerWindowSeconds().roleId
        );
        _assertTargetFunctionRole(
            target, SlippageCoverageVault.setMaxSlippageBps.selector, RolesConfig.getRole__setMaxSlippageBps().roleId
        );
        _assertTargetFunctionRole(
            target,
            SlippageCoverageVault.setOverrideMaxSlippageBps.selector,
            RolesConfig.getRole__setOverrideMaxSlippageBps().roleId
        );
        _assertTargetFunctionRole(
            target, SlippageCoverageVault.fundCoverage.selector, RolesConfig.getRole__fundCoverage().roleId
        );
        _assertTargetFunctionRole(
            target, SlippageCoverageVault.sweep.selector, RolesConfig.getRole__sweepSlippageCoverageVault().roleId
        );
    }

    function test_targetSetup_aTokenVaultAddresses() public view {
        RolesConfig.Role memory claimRole = RolesConfig.getRole__claimMerklRewards();
        RolesConfig.Role memory rescueRole = RolesConfig.getRole__emergencyRescue();
        address[] memory vaults = _deployedATokenVaultAddresses();
        for (uint256 i = 0; i < vaults.length; i++) {
            _assertTargetFunctionRole(vaults[i], claimRole.selector, claimRole.roleId);
            _assertTargetFunctionRole(vaults[i], rescueRole.selector, rescueRole.roleId);
        }
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // SECURITY PROPERTY TESTS
    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    ////// canCall scope + delay //////

    function test_canCall_mainAdmin() public view {
        address admin = _getProfile__MainAdmin();

        // Admin-tier function (HIGH_DELAY): has role but delayed
        _assertCanCall(admin, getAllocatorAddress(_deployer()), IAllocator.addStrategy.selector, false, HIGH_DELAY);

        // Operational function (NO_DELAY): immediate
        _assertCanCall(admin, getAllocatorAddress(_deployer()), IAllocator.rebalance.selector, true, 0);

        // Unconfigured target (ProxyAdmin): ADMIN_ROLE fallback -> CRITICAL_DELAY
        _assertCanCall(admin, _proxyAdmin(), ProxyAdmin.upgradeAndCall.selector, false, CRITICAL_DELAY);
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
        _assertCanCall(rebalancer, getAllocatorAddress(_deployer()), IAllocator.setWithdrawalQueue.selector, true, 0);
        // Unauthorized functions
        _assertCanCall(rebalancer, getAllocatorAddress(_deployer()), IAllocator.topUp.selector, false, 0);
        _assertCanCall(rebalancer, getAllocatorAddress(_deployer()), IAllocator.removeStrategy.selector, false, 0);
        _assertCanCall(rebalancer, getAllocatorAddress(_deployer()), IAllocator.addStrategy.selector, false, 0);
    }

    function test_canCall_funder() public view {
        address funder = _getProfile__Funder();

        _assertCanCall(funder, getAllocatorAddress(_deployer()), IAllocator.topUp.selector, true, 0);
        _assertCanCall(
            funder, getSlippageCoverageVaultAddress(_deployer()), SlippageCoverageVault.fundCoverage.selector, true, 0
        );
        // Unauthorized functions
        _assertCanCall(funder, getAllocatorAddress(_deployer()), IAllocator.rebalance.selector, false, 0);
        _assertCanCall(funder, getAllocatorAddress(_deployer()), IAllocator.addStrategy.selector, false, 0);
    }

    function test_canCall_disabler() public view {
        address disabler = _getProfile__Disabler();

        _assertCanCall(disabler, getAllocatorAddress(_deployer()), IAllocator.rebalance.selector, true, 0);
        _assertCanCall(disabler, getAssetRegistryAddress(_deployer()), IAssetRegistry.distrustAsset.selector, true, 0);
        _assertCanCall(
            disabler, getAllocatorAddress(_deployer()), IAllocator.disableDepositsToStrategy.selector, true, 0
        );
        _assertCanCall(disabler, getAllocatorAddress(_deployer()), IAllocator.distrustStrategy.selector, true, 0);
        // Unauthorized
        _assertCanCall(disabler, getAllocatorAddress(_deployer()), IAllocator.addStrategy.selector, false, 0);
        _assertCanCall(disabler, getAllocatorAddress(_deployer()), IAllocator.topUp.selector, false, 0);
        _assertCanCall(disabler, getAllocatorAddress(_deployer()), IAllocator.trustStrategy.selector, false, 0);
    }

    function test_canCall_withdrawalPolicyManager() public view {
        address wpm = _getProfile__WithdrawalPolicyManager();

        _assertCanCall(
            wpm,
            getWithdrawalExecutionPolicyAddress(_deployer()),
            WithdrawalExecutionPolicy.setDefaultFeeBps.selector,
            true,
            0
        );
        // Unauthorized
        _assertCanCall(wpm, getAllocatorAddress(_deployer()), IAllocator.rebalance.selector, false, 0);
        _assertCanCall(wpm, getAllocatorAddress(_deployer()), IAllocator.topUp.selector, false, 0);
    }

    function test_canCall_aTokenVaultRewardClaimer() public view {
        address claimer = _getProfile__ATokenVaultRewardClaimer();
        RolesConfig.Role memory claimRole = RolesConfig.getRole__claimMerklRewards();
        RolesConfig.Role memory rescueRole = RolesConfig.getRole__emergencyRescue();
        address[] memory vaults = _deployedATokenVaultAddresses();

        for (uint256 i = 0; i < vaults.length; i++) {
            _assertCanCall(claimer, vaults[i], claimRole.selector, true, 0);
            _assertCanCall(claimer, vaults[i], rescueRole.selector, true, 0);
        }
        // Unauthorized
        _assertCanCall(claimer, getAllocatorAddress(_deployer()), IAllocator.rebalance.selector, false, 0);
        _assertCanCall(claimer, getAllocatorAddress(_deployer()), IAllocator.topUp.selector, false, 0);
    }

    ////// ADMIN_ROLE has critical delay as execution timelock //////

    function test_adminRole_hasCriticalDelay_enforcedOnExecution() public {
        IAccessManager accessManager = IAccessManager(_accessManager());
        address admin = _getProfile__MainAdmin();

        (bool hasRole, uint32 delay) = accessManager.hasRole(RolesConfig.ADMIN_ROLE, admin);
        assertTrue(hasRole);
        assertEq(delay, CRITICAL_DELAY);

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
        vm.warp(block.timestamp + CRITICAL_DELAY);

        // Execute the operation to show that it works after the critical delay elapses
        vm.prank(admin);
        accessManager.setTargetFunctionRole(address(0x1234), _toSelectorArray(bytes4(0xdeadbeef)), uint64(99));
    }

    ////// Upgrades to transparent proxies have critical delay as timelock //////

    function test_proxyUpgrades_hasCriticalDelayAsTimelock() public {
        IAccessManager accessManager = IAccessManager(_accessManager());
        address admin = _getProfile__MainAdmin();
        address proxyAdmin = _proxyAdmin();

        _assertCanCall(admin, proxyAdmin, ProxyAdmin.upgradeAndCall.selector, false, CRITICAL_DELAY);

        // Create addresses to avoid zero-address reverts
        address assetRegistry = makeAddr("ASSET_REGISTRY");
        address priceOracle = makeAddr("PRICE_ORACLE");
        address depositor = makeAddr("DEPOSITOR");
        address withdrawer = makeAddr("WITHDRAWER");
        address transferHelper = address(new TransferHelper());

        address newImpl = address(
            new Allocator(
                assetRegistry,
                depositor,
                withdrawer,
                priceOracle,
                transferHelper,
                1,
                getPolicyRegistryAddress(_deployer())
            )
        );
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
        vm.warp(block.timestamp + CRITICAL_DELAY);

        // Execute after delay -> upgrade succeeds
        vm.prank(admin);
        accessManager.execute(proxyAdmin, callData);
    }

    function test_proxyUpgrades_unauthorizedForAllProfilesExceptMainAdmin() public view {
        address proxy = _proxyAdmin();

        // MainAdmin has ADMIN_ROLE, fallback with CRITICAL_DELAY
        _assertCanCall(_getProfile__MainAdmin(), proxy, ProxyAdmin.upgradeAndCall.selector, false, CRITICAL_DELAY);

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

        // Admin-tier role (HIGH_DELAY grant delay)
        RolesConfig.Role memory role = RolesConfig.getRole__addStrategy();

        // Calls grantRole (MainAdmin holds ADMIN_ROLE_GUARDIAN_ROLE without execution delay)
        vm.prank(admin);
        accessManager.grantRole(role.roleId, newAddr, uint32(0));

        // Grant delay (HIGH_DELAY) blocks activation
        (bool hasNow,) = accessManager.hasRole(role.roleId, newAddr);
        assertFalse(hasNow, "Role should not be active yet (grant delay)");

        // Warp 1 second less than HIGH_DELAY
        vm.warp(block.timestamp + HIGH_DELAY - 1);

        (hasNow,) = accessManager.hasRole(role.roleId, newAddr);
        assertFalse(hasNow, "Role should not be active yet (grant delay)");

        // Warp one more second to make HIGH_DELAY fully elapse
        vm.warp(block.timestamp + 1);

        (bool hasAfter,) = accessManager.hasRole(role.roleId, newAddr);
        assertTrue(hasAfter, "Role should be active after grant delay");
    }

    ////// Roles take grant delay to be added //////

    function test_roleGrant_takesGrantDelayToActivate(uint256 timeElapsed) public {
        IAccessManager accessManager = IAccessManager(_accessManager());
        address admin = _getProfile__MainAdmin();
        address newAddr = makeAddr("GRANT_DELAY_FUZZ_TEST");

        // Admin-tier role (HIGH_DELAY grant delay)
        RolesConfig.Role memory role = RolesConfig.getRole__addStrategy();
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
        secondsToElapseBeforeRevoking = bound(secondsToElapseBeforeRevoking, 0, HIGH_DELAY - 1);

        IAccessManager accessManager = IAccessManager(_accessManager());
        address admin = _getProfile__MainAdmin();
        address newAddr = makeAddr("REVOKE_DURING_GRANT_DELAY_TEST");

        // Admin-tier role (HIGH_DELAY grant delay)
        RolesConfig.Role memory role = RolesConfig.getRole__addStrategy();

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
        vm.warp(grantTimestamp + HIGH_DELAY + 1);
        (bool hasAfterDelay,) = accessManager.hasRole(role.roleId, newAddr);
        assertFalse(hasAfterDelay, "Role should remain revoked after grant delay period");
    }

    ////// Role revocation is immediate //////

    function test_roleRevocation_effectIsImmediate() public {
        IAccessManager accessManager = IAccessManager(_accessManager());
        address mainAdmin = _getProfile__MainAdmin();
        address secondaryAdmin = _getProfile__SecondaryAdmin();

        RolesConfig.Role memory role = RolesConfig.getRole__rebalance();

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
        bytes memory callData = abi.encodeCall(IAllocator.addStrategy, (address(0x1), address(0x2)));
        bytes32 operationId = accessManager.hashOperation(admin, getAllocatorAddress(_deployer()), callData);

        vm.prank(admin);
        accessManager.schedule(getAllocatorAddress(_deployer()), callData, 0);

        assertTrue(accessManager.getSchedule(operationId) > 0, "Operation should be scheduled");

        // MainAdmin (as ADMIN_ROLE_GUARDIAN_ROLE holder) cancels immediately
        vm.prank(admin);
        accessManager.cancel(admin, getAllocatorAddress(_deployer()), callData);

        assertEq(accessManager.getSchedule(operationId), 0, "Operation should be canceled");
    }

    ////// SecondaryAdmin cannot cancel admin-tier operations //////

    function test_secondaryAdmin_cannotCancelAdminTierOperation() public {
        IAccessManager accessManager = IAccessManager(_accessManager());
        address admin = _getProfile__MainAdmin();
        address secondary = _getProfile__SecondaryAdmin();

        bytes memory callData = abi.encodeCall(IAllocator.addStrategy, (address(0x1), address(0x2)));

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
        RolesConfig.Role memory operationalRole = RolesConfig.getRole__rebalance();
        vm.prank(admin);
        accessManager.grantRole(operationalRole.roleId, newAddr, operationalRole.delay);

        // Admin-tier role (role admin = ADMIN_ROLE_GUARDIAN_ROLE)
        RolesConfig.Role memory adminTierRole = RolesConfig.getRole__addStrategy();
        vm.prank(admin);
        accessManager.grantRole(adminTierRole.roleId, newAddr, adminTierRole.delay);

        // Warp past HIGH_DELAY -> both roles should be active
        vm.warp(block.timestamp + HIGH_DELAY + 1);
        (bool hasOperational,) = accessManager.hasRole(operationalRole.roleId, newAddr);
        assertTrue(hasOperational, "MainAdmin should be able to grant operational roles");
        (bool hasAdminTier,) = accessManager.hasRole(adminTierRole.roleId, newAddr);
        assertTrue(hasAdminTier, "MainAdmin should be able to grant admin-tier roles");
    }

    function test_operationalProfiles_cannotGrantOrRevokeRoles() public {
        IAccessManager accessManager = IAccessManager(_accessManager());
        RolesConfig.Role memory role = RolesConfig.getRole__rebalance();
        address newAddr = makeAddr("ATTACKER");

        // Rebalancer tries grantRole -> reverts
        vm.prank(_getProfile__Rebalancer());
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedAccount.selector,
                _getProfile__Rebalancer(),
                RolesConfig.OPERATIONAL_ROLE_GUARDIAN_ROLE
            )
        );
        accessManager.grantRole(role.roleId, newAddr, 0);

        // Disabler tries revokeRole -> reverts
        vm.prank(_getProfile__Disabler());
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedAccount.selector,
                _getProfile__Disabler(),
                RolesConfig.OPERATIONAL_ROLE_GUARDIAN_ROLE
            )
        );
        accessManager.revokeRole(role.roleId, _getProfile__SecondaryAdmin());

        // Rebalancer tries admin-tier role -> reverts
        RolesConfig.Role memory adminTierRole = RolesConfig.getRole__addStrategy();
        vm.prank(_getProfile__Rebalancer());
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedAccount.selector,
                _getProfile__Rebalancer(),
                RolesConfig.ADMIN_ROLE_GUARDIAN_ROLE
            )
        );
        accessManager.grantRole(adminTierRole.roleId, newAddr, 0);
    }

    function test_secondaryAdmin_canGrantAndRevokeOperationalRoles() public {
        IAccessManager accessManager = IAccessManager(_accessManager());
        address secondary = _getProfile__SecondaryAdmin();
        address newAddr = makeAddr("SECONDARY_ADMIN_GRANT_TEST");

        // Operational role (NO_DELAY grant delay)
        RolesConfig.Role memory role = RolesConfig.getRole__rebalance();

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
        RolesConfig.Role memory role = RolesConfig.getRole__addStrategy();

        // SecondaryAdmin tries grantRole -> reverts (no ADMIN_ROLE_GUARDIAN_ROLE)
        vm.prank(secondary);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedAccount.selector,
                secondary,
                RolesConfig.ADMIN_ROLE_GUARDIAN_ROLE
            )
        );
        accessManager.grantRole(role.roleId, newAddr, 0);

        // SecondaryAdmin tries revokeRole -> reverts
        vm.prank(secondary);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessManager.AccessManagerUnauthorizedAccount.selector,
                secondary,
                RolesConfig.ADMIN_ROLE_GUARDIAN_ROLE
            )
        );
        accessManager.revokeRole(role.roleId, _getProfile__MainAdmin());
    }
}

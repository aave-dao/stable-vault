// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {IAccessManager} from "lib/openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";

import {Create3AddressBook} from "script/base/Create3AddressBook.sol";
import {Create3Deployment} from "script/base/Create3Deployment.sol";
import {RolesConfig} from "script/base/RolesConfig.sol";
import {Create3AddressLib} from "script/libraries/Create3AddressLib.sol";
import {IMulticall} from "src/interfaces/IMulticall.sol";
import {OwnedMulticall} from "src/periphery/OwnedMulticall.sol";
import {_toSelectorArray} from "test/helpers/TypeHelpers.sol";

abstract contract AccessManagerBaseSetup is Create3AddressBook, Create3Deployment, RolesConfig {
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    //////////////// Operational Profiles Shared between Accounting and Earning Chains ////////////////

    string constant REBALANCER_MULTICALL_SALT_SEED = "aave.stable-vault.OwnedMulticall.RebalancerProfile";
    string constant DISABLER_MULTICALL_SALT_SEED = "aave.stable-vault.OwnedMulticall.DisablerProfile";

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _setupAccessManager(address deployer) internal {
        IAccessManager accessManager = IAccessManager(_accessManager());

        // Setup all profiles by granting roles to them, with their respective execution delays
        _setup_Profiles();

        // Setup role hierarchy by configuring role guardians
        _setupRoleGuardians();

        // Setup role granting delays
        _setupRoleGrantingDelays();

        // Setup role admins (guardian role becomes admin for each role)
        _setupRoleAdmins();

        // Setup the ADMIN_ROLE delay
        accessManager.setTargetAdminDelay(address(accessManager), CRITICAL_DELAY);

        // Setup the link between target and its allowed role, with
        _setup_Targets(deployer);

        // Revoke deployer's access to ADMIN_ROLE
        accessManager.revokeRole(RolesConfig.ADMIN_ROLE, deployer);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _accessManager() internal view virtual returns (address);

    function _deployer() internal view virtual returns (address) {
        return _configAddress(".deployer");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _getProfile__MainAdmin() internal view virtual returns (address) {
        return _configAddress(".profiles.mainAdmin");
    }

    function _getProfile__SecondaryAdmin() internal view virtual returns (address) {
        return _configAddress(".profiles.secondaryAdmin");
    }

    function _getProfile__WithdrawalPolicyManager() internal view virtual returns (address) {
        return _configAddress(".profiles.withdrawalPolicyManager");
    }

    function _getProfile__Rebalancer() internal view virtual returns (address) {
        return Create3AddressLib.computeCreate3Address(REBALANCER_MULTICALL_SALT_SEED, _deployer());
    }

    function _getProfile__Disabler() internal view virtual returns (address) {
        return Create3AddressLib.computeCreate3Address(DISABLER_MULTICALL_SALT_SEED, _deployer());
    }

    function _getProfile__ATokenVaultRewardClaimer() internal view virtual returns (address) {
        return _configAddress(".profiles.aTokenVaultRewardClaimer");
    }

    function _getProfile__CoverageGuardian() internal view virtual returns (address) {
        return _configAddress(".profiles.coverageGuardian");
    }

    function _getProfile__Funder() internal view virtual returns (address) {
        return _configAddress(".profiles.funder");
    }

    function _getRebalancerMulticallOwner() internal view returns (address) {
        return _configAddress(".profiles.rebalancerMulticallOwner");
    }

    function _getDisablerMulticallOwner() internal view returns (address) {
        return _configAddress(".profiles.disablerMulticallOwner");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _deployOwnedMulticallForRebalancerProfile() internal virtual returns (address) {
        address rebalancerMulticallOwner = _getRebalancerMulticallOwner();
        require(rebalancerMulticallOwner != address(0), "Rebalancer Profile OwnedMulticall owner is not set");
        address rebalancerMulticall = _deploy_create3({
            namespacedSaltSeed: REBALANCER_MULTICALL_SALT_SEED,
            deployer: _deployer(),
            initCode: abi.encodePacked(type(OwnedMulticall).creationCode, abi.encode(rebalancerMulticallOwner))
        });
        require(rebalancerMulticall == _getProfile__Rebalancer(), "RebalancerMulticall does not match expected address");
        _logDeployment("RebalancerMulticall", REBALANCER_MULTICALL_SALT_SEED, rebalancerMulticall);
        return rebalancerMulticall;
    }

    function _deployOwnedMulticallForDisablerProfile() internal virtual returns (address) {
        address disablerMulticallOwner = _getDisablerMulticallOwner();
        require(disablerMulticallOwner != address(0), "Disabler Profile OwnedMulticall owner is not set");
        address disablerMulticall = _deploy_create3({
            namespacedSaltSeed: DISABLER_MULTICALL_SALT_SEED,
            deployer: _deployer(),
            initCode: abi.encodePacked(type(OwnedMulticall).creationCode, abi.encode(disablerMulticallOwner))
        });
        require(disablerMulticall == _getProfile__Disabler(), "DisablerMulticall does not match expected address");
        _logDeployment("DisablerMulticall", DISABLER_MULTICALL_SALT_SEED, disablerMulticall);
        return disablerMulticall;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _setup_Profiles() internal virtual {
        _setupProfile__MainAdmin();
        _setupProfile__SecondaryAdmin();
        _setupProfile__WithdrawalPolicyManager();
        _setupProfile__Rebalancer();
        _setupProfile__Disabler();
        _setupProfile__ATokenVaultRewardClaimer();
        _setupProfile__CoverageGuardian();
        _setupProfile__Funder();
    }

    function _logDeployment(string memory, string memory, address) internal virtual {}

    function _deployedATokenVaultAddresses() internal view virtual returns (address[] memory);

    function _setup_Targets(address deployer) internal virtual {
        _setupTarget__CcipAdapter(deployer);
        _setupTarget__Allocator(deployer);
        _setupTarget__WithdrawalExecutionPolicy(deployer);
        _setupTarget__AssetRegistry(deployer);
        _setupTarget__PriceOracle(deployer);
        _setupTarget__SlippageCoverageVault(deployer);
        _setupTarget__PolicyRegistry(deployer);
        _setupTarget__FundsBridgingPolicy(deployer);
        _setupTarget__ATokenVaults();
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _setupRoleGuardians() internal {
        RolesConfig.Role[] memory roles = RolesConfig.getAllFunctionBasedRoles();
        bytes[] memory multicallCalldata = new bytes[](roles.length);
        for (uint256 i = 0; i < roles.length; i++) {
            multicallCalldata[i] =
                abi.encodeCall(IAccessManager.setRoleGuardian, (roles[i].roleId, roles[i].guardianRoleId));
        }
        IMulticall(_accessManager()).multicall(multicallCalldata);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _setupRoleAdmins() internal {
        RolesConfig.Role[] memory roles = RolesConfig.getAllFunctionBasedRoles();
        bytes[] memory multicallCalldata = new bytes[](roles.length);
        for (uint256 i = 0; i < roles.length; i++) {
            multicallCalldata[i] =
                abi.encodeCall(IAccessManager.setRoleAdmin, (roles[i].roleId, roles[i].guardianRoleId));
        }
        IMulticall(_accessManager()).multicall(multicallCalldata);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _setupRoleGrantingDelays() internal {
        RolesConfig.Role[] memory roles = RolesConfig.getAllFunctionBasedRoles();
        bytes[] memory multicallCalldata = new bytes[](roles.length);
        for (uint256 i = 0; i < roles.length; i++) {
            multicallCalldata[i] = abi.encodeCall(IAccessManager.setGrantDelay, (roles[i].roleId, roles[i].delay));
        }
        IMulticall(_accessManager()).multicall(multicallCalldata);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _setupProfile__MainAdmin() internal {
        address mainAdminProfile = _getProfile__MainAdmin();
        require(mainAdminProfile != address(0), "MainAdmin profile address not set");

        RolesConfig.Role[] memory functionBasedRoles = RolesConfig.getAllFunctionBasedRoles();
        bytes[] memory multicallCalldata = new bytes[](functionBasedRoles.length + 3);

        // Grant ADMIN_ROLE
        multicallCalldata[0] =
            abi.encodeCall(IAccessManager.grantRole, (RolesConfig.ADMIN_ROLE, mainAdminProfile, CRITICAL_DELAY));

        // Grant All Role-Guardian roles
        multicallCalldata[1] = abi.encodeCall(
            IAccessManager.grantRole, (RolesConfig.ADMIN_ROLE_GUARDIAN_ROLE, mainAdminProfile, RolesConfig.NO_DELAY)
        );
        multicallCalldata[2] = abi.encodeCall(
            IAccessManager.grantRole,
            (RolesConfig.OPERATIONAL_ROLE_GUARDIAN_ROLE, mainAdminProfile, RolesConfig.NO_DELAY)
        );

        // Grant All Function-Based roles
        for (uint256 i = 0; i < functionBasedRoles.length; i++) {
            multicallCalldata[i + 3] = abi.encodeCall(
                IAccessManager.grantRole, (functionBasedRoles[i].roleId, mainAdminProfile, functionBasedRoles[i].delay)
            );
        }

        IMulticall(_accessManager()).multicall(multicallCalldata);
    }

    function _setupProfile__SecondaryAdmin() internal {
        address secondaryAdminProfile = _getProfile__SecondaryAdmin();
        require(secondaryAdminProfile != address(0), "SecondaryAdmin profile address not set");

        RolesConfig.Role[] memory functionBasedRoles = RolesConfig.getAllFunctionBasedRoles();

        // Count non-critical roles
        uint256 nonCriticalCount = 0;
        for (uint256 i = 0; i < functionBasedRoles.length; i++) {
            if (!functionBasedRoles[i].hasCriticalRisk) {
                nonCriticalCount++;
            }
        }

        bytes[] memory multicallCalldata = new bytes[](nonCriticalCount + 1);

        // Grant Operation-Role Guardian role
        multicallCalldata[0] = abi.encodeCall(
            IAccessManager.grantRole,
            (RolesConfig.OPERATIONAL_ROLE_GUARDIAN_ROLE, secondaryAdminProfile, RolesConfig.NO_DELAY)
        );

        // Grant all non-critical function-based roles
        uint256 multicallIdx = 1;
        for (uint256 i = 0; i < functionBasedRoles.length; i++) {
            if (!functionBasedRoles[i].hasCriticalRisk) {
                multicallCalldata[multicallIdx] = abi.encodeCall(
                    IAccessManager.grantRole,
                    (functionBasedRoles[i].roleId, secondaryAdminProfile, functionBasedRoles[i].delay)
                );
                multicallIdx++;
            }
        }

        IMulticall(_accessManager()).multicall(multicallCalldata);
    }

    function _setupProfile__WithdrawalPolicyManager() internal {
        address withdrawalPolicyManagerProfile = _getProfile__WithdrawalPolicyManager();
        require(withdrawalPolicyManagerProfile != address(0), "WithdrawalPolicyManager profile address not set");

        RolesConfig.Role[] memory roles = new RolesConfig.Role[](2);

        roles[0] = RolesConfig.getRole__setDefaultFeeBps();
        roles[1] = RolesConfig.getRole__setAssetFeeBps();

        _grantRolesToProfile(withdrawalPolicyManagerProfile, roles);
    }

    function _setupProfile__Rebalancer() internal {
        _deployOwnedMulticallForRebalancerProfile();

        address rebalancerProfile = _getProfile__Rebalancer();
        require(rebalancerProfile != address(0), "Rebalancer profile address not set");

        RolesConfig.Role[] memory roles = new RolesConfig.Role[](5);

        roles[0] = RolesConfig.getRole__rebalance();
        roles[1] = RolesConfig.getRole__disableDepositsToStrategy();
        // Only used on the Accounting Chain (FundsHandler), but granted in both Accounting and Earning Chain setups
        roles[2] = RolesConfig.getRole__pushFundsToChain();
        // Only used on the Earning Chain (EarningChainGateway), but granted in both Accounting and Earning Chain setups
        roles[3] = RolesConfig.getRole__pushFundsToAccountingChain();
        roles[4] = RolesConfig.getRole__setWithdrawalQueue();

        _grantRolesToProfile(rebalancerProfile, roles);
    }

    function _setupProfile__Disabler() internal {
        _deployOwnedMulticallForDisablerProfile();

        address disablerProfile = _getProfile__Disabler();
        require(disablerProfile != address(0), "Disabler profile address not set");

        RolesConfig.Role[] memory roles = new RolesConfig.Role[](22);

        roles[0] = RolesConfig.getRole__rebalance();
        roles[1] = RolesConfig.getRole__removeStrategy();
        roles[2] = RolesConfig.getRole__rescueTokens();
        roles[3] = RolesConfig.getRole__rescueNative();
        roles[4] = RolesConfig.getRole__disableAllocatorDeposits();
        roles[5] = RolesConfig.getRole__disableUserDeposits();
        roles[6] = RolesConfig.getRole__disableSwapInput();
        roles[7] = RolesConfig.getRole__disableSwapOutput();
        roles[8] = RolesConfig.getRole__distrustAsset();
        roles[9] = RolesConfig.getRole__removeBridgeAdapter();
        roles[10] = RolesConfig.getRole__disableDepositsToStrategy();
        roles[11] = RolesConfig.getRole__distrustStrategy();
        roles[12] = RolesConfig.getRole__removeSigner();
        roles[13] = RolesConfig.getRole__lowerPullCapPerTx();
        roles[14] = RolesConfig.getRole__lowerWindowCap();
        roles[15] = RolesConfig.getRole__raiseWindowSeconds();
        // Only used on the Accounting Chain (DepositPolicy is Accounting-only), but granted in both chain setups.
        roles[16] = RolesConfig.getRole__lowerDepositCapacity();
        roles[17] = RolesConfig.getRole__lowerDepositRefillRate();
        roles[18] = RolesConfig.getRole__lowerBridgingCapacity();
        roles[19] = RolesConfig.getRole__lowerBridgingRefillRate();
        roles[20] = RolesConfig.getRole__lowerRedemptionCapacity();
        roles[21] = RolesConfig.getRole__lowerRedemptionRefillRate();

        _grantRolesToProfile(disablerProfile, roles);
    }

    function _setupProfile__ATokenVaultRewardClaimer() internal {
        address aTokenVaultRewardClaimer = _getProfile__ATokenVaultRewardClaimer();
        require(aTokenVaultRewardClaimer != address(0), "ATokenVaultRewardClaimer profile address not set");

        RolesConfig.Role[] memory roles = new RolesConfig.Role[](2);

        roles[0] = RolesConfig.getRole__claimMerklRewards();
        roles[1] = RolesConfig.getRole__emergencyRescue();

        _grantRolesToProfile(aTokenVaultRewardClaimer, roles);
    }

    function _setupProfile__CoverageGuardian() internal {
        address coverageGuardian = _getProfile__CoverageGuardian();
        require(coverageGuardian != address(0), "CoverageGuardian profile address not set");

        RolesConfig.Role[] memory roles = new RolesConfig.Role[](2);

        roles[0] = RolesConfig.getRole__enableOverrideMode();
        roles[1] = RolesConfig.getRole__disableOverrideMode();

        _grantRolesToProfile(coverageGuardian, roles);
    }

    function _setupProfile__Funder() internal {
        address funder = _getProfile__Funder();
        require(funder != address(0), "Funder profile address not set");

        RolesConfig.Role[] memory roles = new RolesConfig.Role[](2);

        roles[0] = RolesConfig.getRole__topUp();
        roles[1] = RolesConfig.getRole__fundCoverage();

        _grantRolesToProfile(funder, roles);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _setupTarget__CcipAdapter(address deployer) internal {
        address ccipAdapter = getCcipAdapterAddress(deployer);

        RolesConfig.Role[] memory roles = new RolesConfig.Role[](5);

        roles[0] = RolesConfig.getRole__setDestinationChainAdapter();
        roles[1] = RolesConfig.getRole__setChainSelector();
        roles[2] = RolesConfig.getRole__rescueNative();
        roles[3] = RolesConfig.getRole__replayFundsReceiving();
        roles[4] = RolesConfig.getRole__rescueTokens();

        _setTargetFunctionRoles(ccipAdapter, roles);
    }

    function _setupTarget__Allocator(address deployer) internal {
        address allocator = getAllocatorAddress(deployer);

        RolesConfig.Role[] memory roles = new RolesConfig.Role[](9);

        roles[0] = RolesConfig.getRole__rebalance();
        roles[1] = RolesConfig.getRole__addStrategy();
        roles[2] = RolesConfig.getRole__removeStrategy();
        roles[3] = RolesConfig.getRole__disableDepositsToStrategy();
        roles[4] = RolesConfig.getRole__enableDepositsToStrategy();
        roles[5] = RolesConfig.getRole__topUp();
        roles[6] = RolesConfig.getRole__trustStrategy();
        roles[7] = RolesConfig.getRole__distrustStrategy();
        roles[8] = RolesConfig.getRole__setWithdrawalQueue();

        _setTargetFunctionRoles(allocator, roles);
    }

    function _setupTarget__WithdrawalExecutionPolicy(address deployer) internal {
        address withdrawalExecutionPolicy = getWithdrawalExecutionPolicyAddress(deployer);

        RolesConfig.Role[] memory roles = new RolesConfig.Role[](8);

        roles[0] = RolesConfig.getRole__setAssetFeeBps();
        roles[1] = RolesConfig.getRole__setDefaultFeeBps();
        roles[2] = RolesConfig.getRole__addSigner();
        roles[3] = RolesConfig.getRole__removeSigner();
        roles[4] = RolesConfig.getRole__raiseRedemptionCapacity();
        roles[5] = RolesConfig.getRole__raiseRedemptionRefillRate();
        roles[6] = RolesConfig.getRole__lowerRedemptionCapacity();
        roles[7] = RolesConfig.getRole__lowerRedemptionRefillRate();

        _setTargetFunctionRoles(withdrawalExecutionPolicy, roles);
    }

    function _setupTarget__AssetRegistry(address deployer) internal {
        address assetRegistry = getAssetRegistryAddress(deployer);

        RolesConfig.Role[] memory roles = new RolesConfig.Role[](11);

        roles[0] = RolesConfig.getRole__setAssetConfig();
        roles[1] = RolesConfig.getRole__disableAllocatorDeposits();
        roles[2] = RolesConfig.getRole__disableSwapInput();
        roles[3] = RolesConfig.getRole__disableSwapOutput();
        roles[4] = RolesConfig.getRole__disableUserDeposits();
        roles[5] = RolesConfig.getRole__enableAllocatorDeposits();
        roles[6] = RolesConfig.getRole__enableSwapInput();
        roles[7] = RolesConfig.getRole__enableSwapOutput();
        roles[8] = RolesConfig.getRole__enableUserDeposits();
        roles[9] = RolesConfig.getRole__trustAsset();
        roles[10] = RolesConfig.getRole__distrustAsset();

        _setTargetFunctionRoles(assetRegistry, roles);
    }

    function _setupTarget__PriceOracle(address deployer) internal {
        address priceOracle = getPriceOracleAddress(deployer);

        RolesConfig.Role[] memory roles = new RolesConfig.Role[](1);

        roles[0] = RolesConfig.getRole__setOracleAdapterForAsset();

        _setTargetFunctionRoles(priceOracle, roles);
    }

    function _setupTarget__SlippageCoverageVault(address deployer) internal {
        address slippageCoverageVault = getSlippageCoverageVaultAddress(deployer);

        RolesConfig.Role[] memory roles = new RolesConfig.Role[](12);

        roles[0] = RolesConfig.getRole__enableOverrideMode();
        roles[1] = RolesConfig.getRole__disableOverrideMode();
        roles[2] = RolesConfig.getRole__raisePullCapPerTx();
        roles[3] = RolesConfig.getRole__lowerPullCapPerTx();
        roles[4] = RolesConfig.getRole__raiseWindowCap();
        roles[5] = RolesConfig.getRole__lowerWindowCap();
        roles[6] = RolesConfig.getRole__raiseWindowSeconds();
        roles[7] = RolesConfig.getRole__lowerWindowSeconds();
        roles[8] = RolesConfig.getRole__setMaxSlippageBps();
        roles[9] = RolesConfig.getRole__setOverrideMaxSlippageBps();
        roles[10] = RolesConfig.getRole__fundCoverage();
        roles[11] = RolesConfig.getRole__sweepSlippageCoverageVault();

        _setTargetFunctionRoles(slippageCoverageVault, roles);
    }

    function _setupTarget__PolicyRegistry(address deployer) internal {
        address policyRegistry = getPolicyRegistryAddress(deployer);

        RolesConfig.Role[] memory roles = new RolesConfig.Role[](1);

        roles[0] = RolesConfig.getRole__setPolicy();

        _setTargetFunctionRoles(policyRegistry, roles);
    }

    function _setupTarget__FundsBridgingPolicy(address deployer) internal {
        address fundsBridgingPolicy = getFundsBridgingPolicyAddress(deployer);

        RolesConfig.Role[] memory roles = new RolesConfig.Role[](4);

        roles[0] = RolesConfig.getRole__raiseBridgingCapacity();
        roles[1] = RolesConfig.getRole__raiseBridgingRefillRate();
        roles[2] = RolesConfig.getRole__lowerBridgingCapacity();
        roles[3] = RolesConfig.getRole__lowerBridgingRefillRate();

        _setTargetFunctionRoles(fundsBridgingPolicy, roles);
    }

    function _setupTarget__ATokenVaults() internal {
        address[] memory vaults = _deployedATokenVaultAddresses();
        for (uint256 i = 0; i < vaults.length; i++) {
            _setupTarget__ATokenVault(vaults[i]);
        }
    }

    function _setupTarget__ATokenVault(address vault) internal {
        RolesConfig.Role[] memory roles = new RolesConfig.Role[](2);

        roles[0] = RolesConfig.getRole__claimMerklRewards();
        roles[1] = RolesConfig.getRole__emergencyRescue();

        _setTargetFunctionRoles(vault, roles);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _grantRolesToProfile(address profileAddress, RolesConfig.Role[] memory roles) internal {
        bytes[] memory multicallCalldata = new bytes[](roles.length);
        for (uint256 i = 0; i < roles.length; i++) {
            multicallCalldata[i] =
                abi.encodeCall(IAccessManager.grantRole, (roles[i].roleId, profileAddress, roles[i].delay));
        }
        IMulticall(_accessManager()).multicall(multicallCalldata);
    }

    function _setTargetFunctionRoles(address target, RolesConfig.Role[] memory roles) internal {
        bytes[] memory multicallCalldata = new bytes[](roles.length);
        for (uint256 i = 0; i < roles.length; i++) {
            multicallCalldata[i] = abi.encodeCall(
                IAccessManager.setTargetFunctionRole, (target, _toSelectorArray(roles[i].selector), roles[i].roleId)
            );
        }
        IMulticall(_accessManager()).multicall(multicallCalldata);
    }
}

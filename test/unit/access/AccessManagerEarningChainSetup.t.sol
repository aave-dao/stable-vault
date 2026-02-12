// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {IAccessManager} from "openzeppelin-contracts/contracts/access/manager/IAccessManager.sol";

import {EarningChainDeployment} from "script/EarningChainDeployment.s.sol";
import {Create3AddressLib} from "script/libraries/Create3AddressLib.sol";
import {RolesLib} from "script/libraries/RolesLib.sol";

import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {IEarningChainGateway} from "src/interfaces/IEarningChainGateway.sol";
import {IRescuableNative} from "src/interfaces/IRescuableNative.sol";
import {IRescuableToken} from "src/interfaces/IRescuableToken.sol";

import {AccessManagerSetupBaseTest} from "test/unit/access/AccessManagerSetupBaseTest.sol";

contract AccessManagerEarningChainSetupTest is AccessManagerSetupBaseTest, EarningChainDeployment {
    function setUp() public virtual {
        _deployCreateXTo(Create3AddressLib.CREATEX_ADDRESS);
        vm.startPrank(DEPLOYER);
        _deployContracts();
        _setupAccessManager(DEPLOYER);
        vm.stopPrank();
        vm.warp(block.timestamp + 21 days + 1);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // DEPLOYMENT SCRIPT OVERRIDES
    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    function _logDeployment(string memory, string memory, address) internal virtual override {}

    function _aTokenVaultAddresses()
        internal
        view
        virtual
        override(EarningChainDeployment, AccessManagerSetupBaseTest)
        returns (address[] memory)
    {
        address[] memory vaults = new address[](1);
        vaults[0] = address(uint160(uint256(keccak256("test.aTokenVault"))));
        return vaults;
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // SETUP SCRIPT OVERRIDES — profile getters
    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    function _getProfile__MainAdmin() internal pure virtual override returns (address) {
        return address(uint160(uint256(keccak256("test.mainAdmin"))));
    }

    function _getProfile__SecondaryAdmin() internal pure virtual override returns (address) {
        return address(uint160(uint256(keccak256("test.secondaryAdmin"))));
    }

    function _getProfile__WithdrawalPolicyManager() internal pure virtual override returns (address) {
        return address(uint160(uint256(keccak256("test.withdrawalPolicyManager"))));
    }

    function _getProfile__Rebalancer() internal pure virtual override returns (address) {
        return address(uint160(uint256(keccak256("test.rebalancer"))));
    }

    function _getProfile__Disabler() internal pure virtual override returns (address) {
        return address(uint160(uint256(keccak256("test.disabler"))));
    }

    function _getProfile__ATokenVaultRewardClaimer() internal pure virtual override returns (address) {
        return address(uint160(uint256(keccak256("test.aTokenVaultRewardClaimer"))));
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // BASE TEST OVERRIDES — abstract getters
    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    function _getAccessManager() internal view virtual override returns (IAccessManager) {
        return IAccessManager(_accessManager());
    }

    function _getDeployer() internal pure virtual override returns (address) {
        return DEPLOYER;
    }

    function _mainAdmin() internal pure virtual override returns (address) {
        return _getProfile__MainAdmin();
    }

    function _secondaryAdmin() internal pure virtual override returns (address) {
        return _getProfile__SecondaryAdmin();
    }

    function _withdrawalPolicyManager() internal pure virtual override returns (address) {
        return _getProfile__WithdrawalPolicyManager();
    }

    function _rebalancer() internal pure virtual override returns (address) {
        return _getProfile__Rebalancer();
    }

    function _disabler() internal pure virtual override returns (address) {
        return _getProfile__Disabler();
    }

    function _aTokenVaultRewardClaimer() internal pure virtual override returns (address) {
        return _getProfile__ATokenVaultRewardClaimer();
    }

    function _ccipAdapter() internal view virtual override returns (address) {
        return getCcipAdapterAddress(_getDeployer());
    }

    function _allocator() internal view virtual override returns (address) {
        return getAllocatorAddress(_getDeployer());
    }

    function _withdrawalPolicyTarget() internal view virtual override returns (address) {
        return getWithdrawalPolicyAddress(_getDeployer());
    }

    function _assetRegistry() internal view virtual override returns (address) {
        return getAssetRegistryAddress(_getDeployer());
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // CHAIN-SPECIFIC TESTS
    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    function test_targetSetup_earningChainGateway() public view {
        address gateway = getGatewayAddress(_getDeployer());

        _assertTargetFunctionRole(
            gateway, IChainGateway.addBridgeAdapter.selector, RolesLib.getRole__addBridgeAdapter().roleId
        );
        _assertTargetFunctionRole(
            gateway, IChainGateway.removeBridgeAdapter.selector, RolesLib.getRole__removeBridgeAdapter().roleId
        );
        _assertTargetFunctionRole(
            gateway, IChainGateway.setDefaultBridgeAdapter.selector, RolesLib.getRole__setDefaultBridgeAdapter().roleId
        );
        _assertTargetFunctionRole(
            gateway, IRescuableToken.rescueTokens.selector, RolesLib.getRole__rescueTokens().roleId
        );
        _assertTargetFunctionRole(
            gateway, IRescuableNative.rescueNative.selector, RolesLib.getRole__rescueNative().roleId
        );
        _assertTargetFunctionRole(
            gateway,
            IEarningChainGateway.pushFundsToAccountingChain.selector,
            RolesLib.getRole__pushFundsToAccountingChain().roleId
        );
    }
}

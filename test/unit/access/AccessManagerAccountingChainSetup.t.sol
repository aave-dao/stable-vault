// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {AccountingChainDeployment} from "script/AccountingChainDeployment.s.sol";
import {AccessManagerAccountingChainSetup} from "script/base/AccessManagerAccountingChainSetup.sol";
import {AccessManagerBaseSetup} from "script/base/AccessManagerBaseSetup.sol";
import {RolesConfig} from "script/base/RolesConfig.sol";
import {Create3AddressLib} from "script/libraries/Create3AddressLib.sol";

import {IAllocator} from "src/interfaces/IAllocator.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {IFundsHandler} from "src/interfaces/IFundsHandler.sol";
import {IRescuableNative} from "src/interfaces/IRescuableNative.sol";
import {IRescuableToken} from "src/interfaces/IRescuableToken.sol";
import {IStableVault} from "src/interfaces/IStableVault.sol";
import {ChainBalanceOracle} from "src/oracles/balance/ChainBalanceOracle.sol";

import {AccessManagerSetupBaseTest} from "test/unit/access/AccessManagerSetupBaseTest.sol";

contract AccessManagerAccountingChainSetupTest is AccessManagerSetupBaseTest, AccountingChainDeployment {
    function setUp() public virtual {
        _deployCreateXTo(Create3AddressLib.CREATEX_ADDRESS);
        vm.startPrank(_deployer());
        _deployContracts();
        _setupAccessManager(_deployer());
        vm.stopPrank();
        vm.warp(block.timestamp + CRITICAL_DELAY + 1);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // OVERRIDES
    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    function _logDeployment(string memory, string memory, address)
        internal
        virtual
        override(AccessManagerBaseSetup, AccountingChainDeployment)
    {}

    function _aTokenVaultAddresses()
        internal
        view
        virtual
        override(AccessManagerBaseSetup, AccountingChainDeployment)
        returns (address[] memory)
    {
        address[] memory vaults = new address[](1);
        vaults[0] = address(uint160(uint256(keccak256("test.aTokenVault"))));
        return vaults;
    }

    function _setup_Profiles() internal virtual override(AccessManagerBaseSetup, AccessManagerAccountingChainSetup) {
        super._setup_Profiles();
    }

    function _setup_Targets(address deployer)
        internal
        virtual
        override(AccessManagerBaseSetup, AccessManagerAccountingChainSetup)
    {
        super._setup_Targets(deployer);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // ACCOUNTING-CHAIN-SPECIFIC HELPERS
    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    function _chainBalanceOracle() internal view virtual returns (address) {
        return getChainBalanceOracleAddress(_deployer());
    }

    function _getAllProfiles() internal view virtual override returns (address[] memory) {
        address[] memory baseProfiles = super._getAllProfiles();
        address[] memory profiles = new address[](baseProfiles.length + 1);
        for (uint256 i = 0; i < baseProfiles.length; i++) {
            profiles[i] = baseProfiles[i];
        }
        profiles[baseProfiles.length] = _getProfile__StableVaultManager();
        return profiles;
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // CHAIN-SPECIFIC TESTS
    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    function test_canCall_stableVaultManager() public view {
        address stableVaultManager = _getProfile__StableVaultManager();
        address stableVault = getStableVaultAddress(_deployer());

        // Operational (NO_DELAY): immediate
        _assertCanCall(stableVaultManager, stableVault, IStableVault.setUserRate.selector, true, 0);
        _assertCanCall(stableVaultManager, stableVault, IStableVault.setSubVaultRate.selector, true, 0);
        _assertCanCall(stableVaultManager, stableVault, IStableVault.setDefaultSubVault.selector, true, 0);
        // Admin-tier (MED_DELAY): has role but delayed
        _assertCanCall(stableVaultManager, stableVault, IStableVault.claimSurplusInterest.selector, false, MED_DELAY);
        // Unauthorized
        _assertCanCall(stableVaultManager, stableVault, IStableVault.setTreasury.selector, false, 0);
        _assertCanCall(stableVaultManager, getAllocatorAddress(_deployer()), IAllocator.rebalance.selector, false, 0);
    }

    function test_stableVaultManagerProfile_hasTheExpectedRoles() public view {
        uint64[] memory expected = new uint64[](4);
        expected[0] = RolesConfig.getRole__setUserRate().roleId;
        expected[1] = RolesConfig.getRole__setSubVaultRate().roleId;
        expected[2] = RolesConfig.getRole__claimSurplusInterest().roleId;
        expected[3] = RolesConfig.getRole__setDefaultSubVault().roleId;
        _assertProfileHasExactlyTheseRoles(_getProfile__StableVaultManager(), expected);

        // NO_DELAY roles
        _assertProfileRoleDelay(_getProfile__StableVaultManager(), expected[0], RolesConfig.NO_DELAY);
        _assertProfileRoleDelay(_getProfile__StableVaultManager(), expected[1], RolesConfig.NO_DELAY);
        _assertProfileRoleDelay(_getProfile__StableVaultManager(), expected[3], RolesConfig.NO_DELAY);
        // MED_DELAY roles
        _assertProfileRoleDelay(_getProfile__StableVaultManager(), expected[2], MED_DELAY);
    }

    function test_targetSetup_stableVault() public view {
        address stableVault = getStableVaultAddress(_deployer());

        _assertTargetFunctionRole(
            stableVault, IStableVault.setUserRate.selector, RolesConfig.getRole__setUserRate().roleId
        );
        _assertTargetFunctionRole(
            stableVault, IStableVault.setSubVaultRate.selector, RolesConfig.getRole__setSubVaultRate().roleId
        );
        _assertTargetFunctionRole(
            stableVault, IStableVault.setDefaultSubVault.selector, RolesConfig.getRole__setDefaultSubVault().roleId
        );
        _assertTargetFunctionRole(
            stableVault, IStableVault.claimSurplusInterest.selector, RolesConfig.getRole__claimSurplusInterest().roleId
        );
        _assertTargetFunctionRole(
            stableVault, IStableVault.setTreasury.selector, RolesConfig.getRole__setTreasury().roleId
        );
        _assertTargetFunctionRole(
            stableVault, IRescuableNative.rescueNative.selector, RolesConfig.getRole__rescueNative().roleId
        );
        _assertTargetFunctionRole(
            stableVault, IRescuableToken.rescueTokens.selector, RolesConfig.getRole__rescueTokens().roleId
        );
    }

    function test_targetSetup_fundsHandler() public view {
        address fundsHandler = getFundsHandlerAddress(_deployer());

        _assertTargetFunctionRole(
            fundsHandler, IFundsHandler.pushFundsToChain.selector, RolesConfig.getRole__pushFundsToChain().roleId
        );
        _assertTargetFunctionRole(
            fundsHandler, IRescuableToken.rescueTokens.selector, RolesConfig.getRole__rescueTokens().roleId
        );
        _assertTargetFunctionRole(
            fundsHandler, IRescuableNative.rescueNative.selector, RolesConfig.getRole__rescueNative().roleId
        );
        _assertTargetFunctionRole(
            fundsHandler, IFundsHandler.addEarningChain.selector, RolesConfig.getRole__addEarningChain().roleId
        );
        _assertTargetFunctionRole(
            fundsHandler, IFundsHandler.removeEarningChain.selector, RolesConfig.getRole__removeEarningChain().roleId
        );
    }

    function test_targetSetup_accountingChainGateway() public view {
        address gateway = getGatewayAddress(_deployer());

        _assertTargetFunctionRole(
            gateway, IChainGateway.addBridgeAdapter.selector, RolesConfig.getRole__addBridgeAdapter().roleId
        );
        _assertTargetFunctionRole(
            gateway, IChainGateway.removeBridgeAdapter.selector, RolesConfig.getRole__removeBridgeAdapter().roleId
        );
        _assertTargetFunctionRole(
            gateway,
            IChainGateway.setDefaultBridgeAdapter.selector,
            RolesConfig.getRole__setDefaultBridgeAdapter().roleId
        );
        _assertTargetFunctionRole(
            gateway, IRescuableToken.rescueTokens.selector, RolesConfig.getRole__rescueTokens().roleId
        );
        _assertTargetFunctionRole(
            gateway, IRescuableNative.rescueNative.selector, RolesConfig.getRole__rescueNative().roleId
        );
    }

    function test_targetSetup_chainBalanceOracle() public view {
        address target = _chainBalanceOracle();
        _assertTargetFunctionRole(
            target,
            ChainBalanceOracle.setChainBalanceOracleAdapter.selector,
            RolesConfig.getRole__setChainBalanceOracleAdapter().roleId
        );
    }
}

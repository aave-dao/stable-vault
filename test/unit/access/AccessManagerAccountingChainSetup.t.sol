// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {AccessManagerBaseSetup} from "script/base/AccessManagerBaseSetup.sol";
import {AccountingChainDeployment} from "script/base/AccountingChainDeployment.sol";
import {RolesConfig} from "script/base/RolesConfig.sol";
import {Create3AddressLib} from "script/libraries/Create3AddressLib.sol";

import {IAllocator} from "src/interfaces/IAllocator.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {IFundsHandler} from "src/interfaces/IFundsHandler.sol";
import {IRescuableNative} from "src/interfaces/IRescuableNative.sol";
import {IRescuableToken} from "src/interfaces/IRescuableToken.sol";
import {IStableVault} from "src/interfaces/IStableVault.sol";
import {ChainBalanceOracle} from "src/oracles/balance/ChainBalanceOracle.sol";
import {DepositPolicy} from "src/policies/DepositPolicy.sol";

import {AccessManagerSetupBaseTest} from "test/unit/access/AccessManagerSetupBaseTest.sol";

contract AccessManagerAccountingChainSetupTest is AccessManagerSetupBaseTest, AccountingChainDeployment {
    function setUp() public virtual {
        _deployCreateXTo(Create3AddressLib.CREATEX_ADDRESS);
        vm.etch(_testATokenVault(), hex"00");
        vm.startPrank(_deployer());
        _deployContracts();
        _setupAccessManager(_deployer());
        vm.stopPrank();
        vm.warp(block.timestamp + CRITICAL_DELAY + 1);
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // OVERRIDES
    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    function _configPath() internal pure override returns (string memory) {
        return "test/resources/config/deployment-config.test.json";
    }

    function _logDeployment(string memory, string memory, address)
        internal
        virtual
        override(AccessManagerBaseSetup, AccountingChainDeployment)
    {}

    function _deployedATokenVaultAddresses()
        internal
        view
        virtual
        override(AccessManagerBaseSetup, AccountingChainDeployment)
        returns (address[] memory)
    {
        address[] memory vaults = new address[](1);
        vaults[0] = _testATokenVault();
        return vaults;
    }

    function _testATokenVault() private pure returns (address) {
        return address(uint160(uint256(keccak256("test.aTokenVault"))));
    }

    function _setup_Profiles() internal virtual override(AccessManagerBaseSetup, AccountingChainDeployment) {
        super._setup_Profiles();
    }

    function _validateProfileAddresses()
        internal
        view
        virtual
        override(AccessManagerBaseSetup, AccountingChainDeployment)
    {
        super._validateProfileAddresses();
    }

    function _setup_Targets(address deployer)
        internal
        virtual
        override(AccessManagerBaseSetup, AccountingChainDeployment)
    {
        super._setup_Targets(deployer);
    }

    function _shouldRegisterAdiOnGateway()
        internal
        view
        virtual
        override(AccessManagerBaseSetup, AccountingChainDeployment)
        returns (bool)
    {
        return AccountingChainDeployment._shouldRegisterAdiOnGateway();
    }

    function _adiCrossChainController()
        internal
        view
        virtual
        override(AccessManagerBaseSetup, AccountingChainDeployment)
        returns (address)
    {
        return AccountingChainDeployment._adiCrossChainController();
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
        // Admin-tier (LOW_DELAY): has role but delayed
        _assertCanCall(stableVaultManager, stableVault, IStableVault.setSubVaultRate.selector, false, LOW_DELAY);
        // Admin-tier (MEDIUM_DELAY): has role but delayed
        _assertCanCall(stableVaultManager, stableVault, IStableVault.setDefaultSubVault.selector, false, MEDIUM_DELAY);
        // Admin-tier (HIGH_DELAY): has role but delayed
        _assertCanCall(stableVaultManager, stableVault, IStableVault.claimSurplusInterest.selector, false, HIGH_DELAY);
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
        // LOW_DELAY roles
        _assertProfileRoleDelay(_getProfile__StableVaultManager(), expected[1], LOW_DELAY);
        // MEDIUM_DELAY roles
        _assertProfileRoleDelay(_getProfile__StableVaultManager(), expected[3], MEDIUM_DELAY);
        // HIGH_DELAY roles
        _assertProfileRoleDelay(_getProfile__StableVaultManager(), expected[2], HIGH_DELAY);
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
            gateway, IChainGateway.addFundsBridgeAdapter.selector, RolesConfig.getRole__addFundsBridgeAdapter().roleId
        );
        _assertTargetFunctionRole(
            gateway,
            IChainGateway.removeFundsBridgeAdapter.selector,
            RolesConfig.getRole__removeFundsBridgeAdapter().roleId
        );
        _assertTargetFunctionRole(
            gateway,
            IChainGateway.addDataOnlyBridgeAdapter.selector,
            RolesConfig.getRole__addDataOnlyBridgeAdapter().roleId
        );
        _assertTargetFunctionRole(
            gateway,
            IChainGateway.initiateDataOnlyBridgeAdapterRemoval.selector,
            RolesConfig.getRole__initiateDataOnlyBridgeAdapterRemoval().roleId
        );
        _assertTargetFunctionRole(
            gateway,
            IChainGateway.finalizeDataOnlyBridgeAdapterRemoval.selector,
            RolesConfig.getRole__finalizeDataOnlyBridgeAdapterRemoval().roleId
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

    function test_targetSetup_depositPolicy() public view {
        address target = getDepositPolicyAddress(_deployer());
        _assertTargetFunctionRole(
            target, DepositPolicy.raiseDepositCapacity.selector, RolesConfig.getRole__raiseDepositCapacity().roleId
        );
        _assertTargetFunctionRole(
            target, DepositPolicy.lowerDepositCapacity.selector, RolesConfig.getRole__lowerDepositCapacity().roleId
        );
        _assertTargetFunctionRole(
            target, DepositPolicy.raiseDepositRefillRate.selector, RolesConfig.getRole__raiseDepositRefillRate().roleId
        );
        _assertTargetFunctionRole(
            target, DepositPolicy.lowerDepositRefillRate.selector, RolesConfig.getRole__lowerDepositRefillRate().roleId
        );
    }
}

// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {AccessManagerBaseSetup} from "script/base/AccessManagerBaseSetup.sol";
import {EarningChainDeployment} from "script/base/EarningChainDeployment.sol";
import {RolesConfig} from "script/base/RolesConfig.sol";
import {Create3AddressLib} from "script/libraries/Create3AddressLib.sol";

import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {IEarningChainGateway} from "src/interfaces/IEarningChainGateway.sol";
import {IRescuableNative} from "src/interfaces/IRescuableNative.sol";
import {IRescuableToken} from "src/interfaces/IRescuableToken.sol";

import {AccessManagerSetupBaseTest} from "test/unit/access/AccessManagerSetupBaseTest.sol";

contract AccessManagerEarningChainSetupTest is AccessManagerSetupBaseTest, EarningChainDeployment {
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
        override(AccessManagerBaseSetup, EarningChainDeployment)
    {}

    function _deployedATokenVaultAddresses()
        internal
        view
        virtual
        override(AccessManagerBaseSetup, EarningChainDeployment)
        returns (address[] memory)
    {
        address[] memory vaults = new address[](1);
        vaults[0] = _testATokenVault();
        return vaults;
    }

    function _testATokenVault() private pure returns (address) {
        return address(uint160(uint256(keccak256("test.aTokenVault"))));
    }

    function _setup_Targets(address deployer)
        internal
        virtual
        override(AccessManagerBaseSetup, EarningChainDeployment)
    {
        super._setup_Targets(deployer);
    }

    function _shouldRegisterAdiOnGateway()
        internal
        view
        virtual
        override(AccessManagerBaseSetup, EarningChainDeployment)
        returns (bool)
    {
        return EarningChainDeployment._shouldRegisterAdiOnGateway();
    }

    function _adiCrossChainController()
        internal
        view
        virtual
        override(AccessManagerBaseSetup, EarningChainDeployment)
        returns (address)
    {
        return EarningChainDeployment._adiCrossChainController();
    }

    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
    // CHAIN-SPECIFIC TESTS
    ////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

    function test_targetSetup_earningChainGateway() public view {
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
        _assertTargetFunctionRole(
            gateway,
            IEarningChainGateway.pushFundsToAccountingChain.selector,
            RolesConfig.getRole__pushFundsToAccountingChain().roleId
        );
    }
}

contract AccessManagerEarningChainWithAdiSetupTest is AccessManagerEarningChainSetupTest {
    function _shouldRegisterAdiOnGateway() internal view virtual override returns (bool) {
        return true;
    }

    function _adiCrossChainController() internal view virtual override returns (address) {
        return _testAdiCrossChainController();
    }

    function test_targetSetup_adiCrossChainController() public view {
        address target = _testAdiCrossChainController();

        _assertTargetFunctionRole(
            target, RolesConfig.getRole__adiApproveSenders().selector, RolesConfig.getRole__adiApproveSenders().roleId
        );
        _assertTargetFunctionRole(
            target, RolesConfig.getRole__adiRemoveSenders().selector, RolesConfig.getRole__adiRemoveSenders().roleId
        );
        _assertTargetFunctionRole(
            target,
            RolesConfig.getRole__adiEnableBridgeAdapters().selector,
            RolesConfig.getRole__adiEnableBridgeAdapters().roleId
        );
        _assertTargetFunctionRole(
            target,
            RolesConfig.getRole__adiDisableBridgeAdapters().selector,
            RolesConfig.getRole__adiDisableBridgeAdapters().roleId
        );
        _assertTargetFunctionRole(
            target,
            RolesConfig.getRole__adiUpdateOptimalBandwidthByChain().selector,
            RolesConfig.getRole__adiUpdateOptimalBandwidthByChain().roleId
        );
        _assertTargetFunctionRole(
            target, RolesConfig.getRole__adiConfigAdapter().selector, RolesConfig.getRole__adiConfigAdapter().roleId
        );
        _assertTargetFunctionRole(
            target,
            RolesConfig.getRole__adiUpdateRequiredForwardingSuccessesByChain().selector,
            RolesConfig.getRole__adiUpdateRequiredForwardingSuccessesByChain().roleId
        );
        _assertTargetFunctionRole(
            target,
            RolesConfig.getRole__adiUpdateConfirmations().selector,
            RolesConfig.getRole__adiUpdateConfirmations().roleId
        );
        _assertTargetFunctionRole(
            target,
            RolesConfig.getRole__adiUpdateMessagesValidityTimestamp().selector,
            RolesConfig.getRole__adiUpdateMessagesValidityTimestamp().roleId
        );
        _assertTargetFunctionRole(
            target,
            RolesConfig.getRole__adiAllowReceiverBridgeAdapters().selector,
            RolesConfig.getRole__adiAllowReceiverBridgeAdapters().roleId
        );
        _assertTargetFunctionRole(
            target,
            RolesConfig.getRole__adiDisallowReceiverBridgeAdapters().selector,
            RolesConfig.getRole__adiDisallowReceiverBridgeAdapters().roleId
        );
        _assertTargetFunctionRole(
            target,
            RolesConfig.getRole__adiEmergencyTokenTransfer().selector,
            RolesConfig.getRole__adiEmergencyTokenTransfer().roleId
        );
        _assertTargetFunctionRole(
            target,
            RolesConfig.getRole__adiEmergencyEtherTransfer().selector,
            RolesConfig.getRole__adiEmergencyEtherTransfer().roleId
        );
        _assertTargetFunctionRole(
            target,
            RolesConfig.getRole__adiTransferOwnership().selector,
            RolesConfig.getRole__adiTransferOwnership().roleId
        );
        _assertTargetFunctionRole(
            target, RolesConfig.getRole__adiUpdateGuardian().selector, RolesConfig.getRole__adiUpdateGuardian().roleId
        );
    }

    function _testAdiCrossChainController() internal pure returns (address) {
        return address(uint160(uint256(keccak256("test.adiCrossChainController"))));
    }
}

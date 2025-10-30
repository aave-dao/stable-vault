// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {AccessManager} from "@openzeppelin/contracts/access/manager/AccessManager.sol";

import {IAllocator} from "../../src/interfaces/IAllocator.sol";
import {IAssetRegistry} from "../../src/interfaces/IAssetRegistry.sol";
import {IBasedBoostedVault} from "../../src/interfaces/IBasedBoostedVault.sol";
import {IChainGateway} from "../../src/interfaces/IChainGateway.sol";
import {IEarningChainGateway} from "../../src/interfaces/IEarningChainGateway.sol";
import {IFundsHandler} from "../../src/interfaces/IFundsHandler.sol";
import {IRescuableAssets} from "../../src/interfaces/IRescuableAssets.sol";

contract MockAccessManager is AccessManager {
    /// @param admin The MasterAdmin which has the ADMIN_ROLE
    constructor(address admin) AccessManager(admin) {}

    // ADMIN_ROLE = 0
    uint64 public constant GUARDIAN_ROLE = 1;
    uint64 public constant UPGRADE_PROXY_ADMIN_ROLE = 2;
    uint64 public constant APPENDER_ROLE = 3;
    uint64 public constant REMOVER_ROLE = 4;
    uint64 public constant RESCUER_ROLE = 5;
    uint64 public constant PROFIT_TAKER_ROLE = 6;
    uint64 public constant OPERATOR_ROLE = 7;

    modifier onlyMasterAdmin() {
        (bool isMember, uint32 executionDelay) = hasRole(ADMIN_ROLE, _msgSender());
        require(isMember && executionDelay == 0, "MockAccessManager: caller is not the master admin");
        _;
    }

    /// @inheritdoc AccessManager
    function expiration() public pure override returns (uint32) {
        return 1 days * 21;
    }

    function setUpGuardian(address guardian) public onlyMasterAdmin {
        this.grantRole(GUARDIAN_ROLE, guardian, 0);
    }

    function setUpUpgradeProxyRole(address upgradeProxyAdmin, address[] calldata targets) public onlyMasterAdmin {
        // Keep the role's admin as the master admin (set by default to ADMIN_ROLE id 0 unless set otherwise)
        uint32 executionDelay = 1 days * 15;
        this.grantRole(UPGRADE_PROXY_ADMIN_ROLE, upgradeProxyAdmin, executionDelay);
        this.setRoleGuardian(UPGRADE_PROXY_ADMIN_ROLE, GUARDIAN_ROLE);

        // TODO: set upgrade selector for all relavent contracts
        bytes4 selector = 0x00000000;
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        for (uint256 i = 0; i < targets.length; i++) {
            this.setTargetFunctionRole(targets[i], selectors, UPGRADE_PROXY_ADMIN_ROLE);
        }
    }

    function setUpAppenderRole(address appender, address allocator, address assetRegistry, address gateway)
        public
        onlyMasterAdmin
    {
        uint32 executionDelay = 1 days * 7;
        this.grantRole(APPENDER_ROLE, appender, executionDelay);
        this.setRoleGuardian(APPENDER_ROLE, GUARDIAN_ROLE);

        bytes4 selector = IAllocator.addVault.selector;
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        this.setTargetFunctionRole(address(allocator), selectors, APPENDER_ROLE);

        selector = IAssetRegistry.setAssetConfig.selector;
        selectors = new bytes4[](1);
        selectors[0] = selector;
        this.setTargetFunctionRole(address(assetRegistry), selectors, APPENDER_ROLE);

        selector = IChainGateway.addBridgeAdapter.selector;
        selectors = new bytes4[](1);
        selectors[0] = selector;
        this.setTargetFunctionRole(address(gateway), selectors, APPENDER_ROLE);
    }

    function setUpRemoverRole(address remover, address allocator, address gateway) public onlyMasterAdmin {
        this.grantRole(REMOVER_ROLE, remover, 0);
        this.setRoleGuardian(REMOVER_ROLE, GUARDIAN_ROLE);

        bytes4 selector = IAllocator.removeVault.selector;
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        this.setTargetFunctionRole(address(allocator), selectors, REMOVER_ROLE);

        selector = IChainGateway.removeBridgeAdapter.selector;
        selectors = new bytes4[](1);
        selectors[0] = selector;
        this.setTargetFunctionRole(address(gateway), selectors, REMOVER_ROLE);
    }

    function setUpRescuerRole(address rescuer, address bbv, address fundsHandler, address gateway)
        public
        onlyMasterAdmin
    {
        this.grantRole(RESCUER_ROLE, rescuer, 0);
        this.setRoleGuardian(RESCUER_ROLE, GUARDIAN_ROLE);

        bytes4 selector = IRescuableAssets.rescueTokens.selector;
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        this.setTargetFunctionRole(address(bbv), selectors, RESCUER_ROLE);
        this.setTargetFunctionRole(address(fundsHandler), selectors, RESCUER_ROLE);
        this.setTargetFunctionRole(address(gateway), selectors, RESCUER_ROLE);
    }

    function setUpProfitTakerRole(address profitTaker, address bbv) public onlyMasterAdmin {
        this.grantRole(PROFIT_TAKER_ROLE, profitTaker, 0);
        this.setRoleGuardian(PROFIT_TAKER_ROLE, GUARDIAN_ROLE);

        bytes4 selector = IBasedBoostedVault.claimFees.selector;
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        this.setTargetFunctionRole(address(bbv), selectors, PROFIT_TAKER_ROLE);
    }

    function setUpAccountingChainOperatorRole(
        address operator,
        address bbv,
        address fundsHandler,
        address gateway,
        address allocator
    ) public onlyMasterAdmin {
        this.grantRole(OPERATOR_ROLE, operator, 0);
        this.setRoleGuardian(OPERATOR_ROLE, GUARDIAN_ROLE);

        _setUpOperatorRoleFunctions(allocator, gateway);

        bytes4 selector = IBasedBoostedVault.setUserRate.selector;
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        this.setTargetFunctionRole(address(bbv), selectors, OPERATOR_ROLE);

        selector = IBasedBoostedVault.setSubVaultRate.selector;
        selectors = new bytes4[](1);
        selectors[0] = selector;
        this.setTargetFunctionRole(address(bbv), selectors, OPERATOR_ROLE);

        selector = IBasedBoostedVault.setDefaultSubVault.selector;
        selectors = new bytes4[](1);
        selectors[0] = selector;
        this.setTargetFunctionRole(address(bbv), selectors, OPERATOR_ROLE);

        selector = IFundsHandler.pushFundsToChain.selector;
        selectors = new bytes4[](1);
        selectors[0] = selector;
        this.setTargetFunctionRole(address(fundsHandler), selectors, OPERATOR_ROLE);
    }

    function setUpEarningChainOperatorRole(address operator, address gateway, address allocator)
        public
        onlyMasterAdmin
    {
        this.grantRole(OPERATOR_ROLE, operator, 0);
        this.setRoleGuardian(OPERATOR_ROLE, GUARDIAN_ROLE);

        _setUpOperatorRoleFunctions(allocator, gateway);

        bytes4 selector = IEarningChainGateway.sendBalanceUpdate.selector;
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        this.setTargetFunctionRole(address(gateway), selectors, OPERATOR_ROLE);

        selector = IEarningChainGateway.exit.selector;
        selectors = new bytes4[](1);
        selectors[0] = selector;
        this.setTargetFunctionRole(address(gateway), selectors, OPERATOR_ROLE);
    }

    function _setUpOperatorRoleFunctions(address allocator, address gateway) internal {
        bytes4 selector = IAllocator.deallocate.selector;
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = selector;
        this.setTargetFunctionRole(address(allocator), selectors, OPERATOR_ROLE);

        selector = IAllocator.depositIdleFunds.selector;
        selectors = new bytes4[](1);
        selectors[0] = selector;
        this.setTargetFunctionRole(address(allocator), selectors, OPERATOR_ROLE);

        selector = IAllocator.rebalance.selector;
        selectors = new bytes4[](1);
        selectors[0] = selector;
        this.setTargetFunctionRole(address(allocator), selectors, OPERATOR_ROLE);

        selector = IAllocator.reallocate.selector;
        selectors = new bytes4[](1);
        selectors[0] = selector;
        this.setTargetFunctionRole(address(allocator), selectors, OPERATOR_ROLE);

        selector = IAllocator.setDefaultVault.selector;
        selectors = new bytes4[](1);
        selectors[0] = selector;
        this.setTargetFunctionRole(address(allocator), selectors, OPERATOR_ROLE);

        selector = IChainGateway.setDefaultBridgeAdapter.selector;
        selectors = new bytes4[](1);
        selectors[0] = selector;
        this.setTargetFunctionRole(address(gateway), selectors, OPERATOR_ROLE);
    }
}

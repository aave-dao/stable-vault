// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {IChainBalanceOracle} from "src/interfaces/IChainBalanceOracle.sol";
import {IChainBalanceOracleAdapter} from "src/interfaces/IChainBalanceOracleAdapter.sol";
import {IPriceOracleAdapter} from "src/interfaces/IPriceOracleAdapter.sol";
import {IStableVault} from "src/interfaces/IStableVault.sol";
import {MathLib} from "src/libraries/MathLib.sol";

import {Swapper} from "src/periphery/Swapper.sol";

import {BaseTest} from "test/BaseTest.t.sol";
import {MockErc20} from "test/mocks/MockErc20.sol";

contract CSGasTest is BaseTest {
    uint256 amount = 100e6;
    uint256 userSeed = 0;

    function setUp() public override {
        super.setUp();

        address firstUser = _generateNewUser();
        _mintAndApproveUsdc(firstUser);
        vm.prank(firstUser);
        vault.deposit(firstUser, address(USDC), amount);
    }

    // ==================== SLOAD #1: PriceOracle.validatePrice ====================
    function test_gas_validatePrice() public {
        address mockAdapter = makeAddr("mockAdapter");
        IPriceOracleAdapter.OracleResponse memory resp =
            IPriceOracleAdapter.OracleResponse({priceRay: MathLib.RAY, isStale: false});
        vm.mockCall(mockAdapter, abi.encodeWithSelector(IPriceOracleAdapter.getPrice.selector), abi.encode(resp));
        vm.prank(admin);
        priceOracle_accountingChain.setOracleAdapterForAsset(address(USDC), mockAdapter);

        uint256 gasBefore = gasleft();
        priceOracle_accountingChain.validatePrice(address(USDC));
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("GAS_validatePrice", gasUsed);
    }

    // ==================== SLOAD #2: ChainBalanceOracle.getChainBalance ====================
    function test_gas_getChainBalance() public {
        uint256 chainId = 100;

        // Set up a mock adapter at a real address
        address mockAdapter = makeAddr("mockChainBalanceAdapter");
        // supportsInterface(bytes4) selector = 0x01ffc9a7
        vm.mockCall(mockAdapter, abi.encodeWithSelector(bytes4(0x01ffc9a7)), abi.encode(true));
        vm.mockCall(
            mockAdapter,
            abi.encodeWithSelector(IChainBalanceOracleAdapter.getChainBalance.selector, chainId),
            abi.encode(
                IChainBalanceOracle.ChainBalance({
                        balanceRay: 1000e27,
                        lastUpdateTimestamp: block.timestamp,
                        sourceChainTimestamp: block.timestamp,
                        sourceChainBlockNumber: block.number,
                        isStale: false
                    })
            )
        );
        vm.prank(everyRoleAccount);
        chainBalanceOracle.setChainBalanceOracleAdapter(chainId, mockAdapter);

        uint256 gasBefore = gasleft();
        chainBalanceOracle.getChainBalance(chainId);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("GAS_getChainBalance", gasUsed);
    }

    // ==================== SLOAD #6: _getActiveSubVaultsObligations via getVaultObligations ===========
    // Already tested in G01 file — reused here for completeness of CS report
    function test_gas_getVaultObligations() public {
        _createSubVaults(5);
        uint256 gasBefore = gasleft();
        vault.getVaultObligations();
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("GAS_getVaultObligations", gasUsed);
    }

    // ==================== SLOAD #7: _burnShares via requestWithdrawal ====================
    function test_gas_requestWithdrawal() public {
        address user = _generateNewUser();
        _mintAndApproveUsdc(user);
        vm.prank(user);
        vault.deposit(user, address(USDC), amount);

        uint256 withdrawRay = 50e6 * 1e21; // 50 USDC in RAY
        vm.prank(user);
        uint256 gasBefore = gasleft();
        vault.requestWithdrawal(user, withdrawRay);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("GAS_requestWithdrawal", gasUsed);
    }

    // ==================== Other #6: _validateAmountOfActiveSubVaults via setUserRate (migration) =====
    function test_gas_setUserRate_migration() public {
        _createSubVaults(3);
        address user = _generateNewUser();
        _mintAndApproveUsdc(user);
        vm.prank(user);
        vault.deposit(user, address(USDC), amount);

        // Migrate user to a different sub-vault (triggers _moveShares -> _validateAmountOfActiveSubVaults)
        uint256 newRate = 1_000000001547125957863212449 + 10;
        IStableVault.UserRateData[] memory rateData = new IStableVault.UserRateData[](1);
        rateData[0] = IStableVault.UserRateData(user, newRate);
        vm.prank(everyRoleAccount);
        uint256 gasBefore = gasleft();
        vault.setUserRate(rateData);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("GAS_setUserRate_migration", gasUsed);
    }

    // ==================== Other #1: LocalBalanceAggregator — batch getPrices ===============
    // Tests with varying numbers of trusted assets (0, 1, 2, 3)

    function _setupRealOracleAdapters() internal {
        address mockAdapter = makeAddr("mockPriceAdapter");
        IPriceOracleAdapter.OracleResponse memory resp =
            IPriceOracleAdapter.OracleResponse({priceRay: MathLib.RAY, isStale: false});
        vm.mockCall(mockAdapter, abi.encodeWithSelector(IPriceOracleAdapter.getPrice.selector), abi.encode(resp));

        vm.startPrank(admin);
        priceOracle_accountingChain.setOracleAdapterForAsset(address(USDC), mockAdapter);
        priceOracle_accountingChain.setOracleAdapterForAsset(address(GHO), mockAdapter);
        vm.stopPrank();

        vm.clearMockedCalls();
        vm.mockCall(mockAdapter, abi.encodeWithSelector(IPriceOracleAdapter.getPrice.selector), abi.encode(resp));
    }

    function test_gas_getAggregatedBalance_0assets() public {
        _setupRealOracleAdapters();
        // Distrust both assets so 0 trusted assets remain
        vm.startPrank(everyRoleAccount);
        assetRegistry_accountingChain.distrustAsset(address(USDC));
        assetRegistry_accountingChain.distrustAsset(address(GHO));
        vm.stopPrank();

        uint256 gasBefore = gasleft();
        fundsHandler.getAggregatedBalance();
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("GAS_getAggregatedBalance_0assets", gasUsed);
    }

    function test_gas_getAggregatedBalance_1asset() public {
        _setupRealOracleAdapters();
        // Distrust one asset so 1 trusted asset remains
        vm.prank(everyRoleAccount);
        assetRegistry_accountingChain.distrustAsset(address(GHO));

        uint256 gasBefore = gasleft();
        fundsHandler.getAggregatedBalance();
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("GAS_getAggregatedBalance_1asset", gasUsed);
    }

    function test_gas_getAggregatedBalance_2assets() public {
        _setupRealOracleAdapters();
        // Default: 2 trusted assets (USDC + GHO)
        uint256 gasBefore = gasleft();
        fundsHandler.getAggregatedBalance();
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("GAS_getAggregatedBalance_2assets", gasUsed);
    }

    function test_gas_getAggregatedBalance_3assets() public {
        _setupRealOracleAdapters();
        // Add a third trusted asset
        MockErc20 token3 = new MockErc20("Token3", "T3", 6);
        vm.prank(everyRoleAccount);
        assetRegistry_accountingChain.setAssetConfig(
            address(token3),
            IAssetRegistry.AssetConfig({
                depositFromUserAllowed: true,
                depositIntoAllocatorAllowed: true,
                swapInputTokenAllowed: true,
                swapOutputTokenAllowed: true
            })
        );
        // Set up oracle adapter for the new token
        address mockAdapter = makeAddr("mockPriceAdapter");
        IPriceOracleAdapter.OracleResponse memory resp =
            IPriceOracleAdapter.OracleResponse({priceRay: MathLib.RAY, isStale: false});
        vm.mockCall(mockAdapter, abi.encodeWithSelector(IPriceOracleAdapter.getPrice.selector), abi.encode(resp));
        vm.prank(admin);
        priceOracle_accountingChain.setOracleAdapterForAsset(address(token3), mockAdapter);

        uint256 gasBefore = gasleft();
        fundsHandler.getAggregatedBalance();
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("GAS_getAggregatedBalance_3assets", gasUsed);
    }

    // ==================== Other #2: AssetRegistry.setAssetConfig — memory to calldata ======
    function test_gas_setAssetConfig_allTrue() public {
        MockErc20 newToken = new MockErc20("TestToken", "TT", 6);
        IAssetRegistry.AssetConfig memory config = IAssetRegistry.AssetConfig({
            depositFromUserAllowed: true,
            depositIntoAllocatorAllowed: true,
            swapInputTokenAllowed: true,
            swapOutputTokenAllowed: true
        });
        vm.prank(everyRoleAccount);
        uint256 gasBefore = gasleft();
        assetRegistry_accountingChain.setAssetConfig(address(newToken), config);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("GAS_setAssetConfig_allTrue", gasUsed);
    }

    function test_gas_setAssetConfig_allFalse() public {
        MockErc20 newToken = new MockErc20("TestToken2", "TT2", 6);
        IAssetRegistry.AssetConfig memory config = IAssetRegistry.AssetConfig({
            depositFromUserAllowed: false,
            depositIntoAllocatorAllowed: false,
            swapInputTokenAllowed: false,
            swapOutputTokenAllowed: false
        });
        vm.prank(everyRoleAccount);
        uint256 gasBefore = gasleft();
        assetRegistry_accountingChain.setAssetConfig(address(newToken), config);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("GAS_setAssetConfig_allFalse", gasUsed);
    }

    function test_gas_setAssetConfig_mixed() public {
        MockErc20 newToken = new MockErc20("TestToken3", "TT3", 18);
        IAssetRegistry.AssetConfig memory config = IAssetRegistry.AssetConfig({
            depositFromUserAllowed: true,
            depositIntoAllocatorAllowed: false,
            swapInputTokenAllowed: true,
            swapOutputTokenAllowed: false
        });
        vm.prank(everyRoleAccount);
        uint256 gasBefore = gasleft();
        assetRegistry_accountingChain.setAssetConfig(address(newToken), config);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("GAS_setAssetConfig_mixed", gasUsed);
    }

    // ==================== Other #4: Swapper constructor — redundant address(0) check =====
    function test_gas_deploySwapper() public {
        uint256 gasBefore = gasleft();
        new Swapper(address(allocator_accountingChain));
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("GAS_deploySwapper", gasUsed);
    }

    // ==================== Other #6: _moveShares — conditional _validateAmountOfActiveSubVaults
    // Test the same-subvault transfer path (where validation is unnecessary)
    function test_gas_transfer_sameSubVault() public {
        address sender = _generateNewUser();
        address receiver = _generateNewUser();
        _mintAndApproveUsdc(sender);
        vm.prank(sender);
        vault.deposit(sender, address(USDC), amount);

        uint256 transferRay = 30e6 * 1e21; // 30 USDC in RAY
        vm.prank(sender);
        uint256 gasBefore = gasleft();
        require(vault.transfer(receiver, transferRay));
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("GAS_transfer_sameSubVault", gasUsed);
    }

    // ==================== SLOAD #3: Allocator.withdraw — cache defaultStrategyByAsset =====
    function test_gas_allocator_withdraw() public {
        // Deposit first to have funds to withdraw
        address user = _generateNewUser();
        uint256 depositAmount = 1000e6;
        USDC.mint(user, depositAmount);
        vm.prank(user);
        USDC.approve(address(vault), depositAmount);
        vm.prank(user);
        vault.deposit(user, address(USDC), depositAmount);

        // Now withdraw via vault (which calls allocator.withdraw internally)
        uint256 withdrawAmountRay = 500e6 * 1e21;
        vm.prank(user);
        uint256 iouAmount = vault.requestWithdrawal(user, withdrawAmountRay);
        uint256 gasBefore = gasleft();
        vm.prank(user);
        vault.executeWithdrawal(user, address(USDC), 0, iouAmount, "");
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("GAS_executeWithdrawal", gasUsed);
    }

    // ==================== Helpers ====================

    function _generateNewUser() internal returns (address) {
        return makeAddr(string.concat("CS_USER[", Strings.toString(userSeed++), "]"));
    }

    function _mintAndApproveUsdc(address user) internal {
        USDC.mint(user, amount);
        vm.prank(user);
        USDC.approve(address(vault), amount);
    }

    function _createSubVaults(uint256 count) internal {
        uint256 rate = 1_000000001547125957863212449;
        for (uint256 i = 0; i < count; i++) {
            address user = _generateNewUser();
            _mintAndApproveUsdc(user);
            vm.prank(user);
            vault.deposit(user, address(USDC), amount);
            IStableVault.UserRateData[] memory rateData = new IStableVault.UserRateData[](1);
            rateData[0] = IStableVault.UserRateData(user, rate + i);
            vm.prank(everyRoleAccount);
            vault.setUserRate(rateData);
        }
    }
}

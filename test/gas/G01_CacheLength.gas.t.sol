// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {Client} from "@chainlink-ccip/contracts/libraries/Client.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {IChainBalanceOracle} from "src/interfaces/IChainBalanceOracle.sol";
import {IPriceOracleAdapter} from "src/interfaces/IPriceOracleAdapter.sol";
import {IStableVault} from "src/interfaces/IStableVault.sol";
import {ITransferHelper} from "src/interfaces/ITransferHelper.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {MathLib} from "src/libraries/MathLib.sol";

import {BaseTest} from "test/BaseTest.t.sol";
import {_toAddressArray, _toUint256Array} from "test/helpers/TypeHelpers.sol";
import {IMockErc20} from "test/mocks/MockErc20.sol";
import {MockErc20} from "test/mocks/MockErc20.sol";

contract G01CacheLengthGasTest is BaseTest {
    using AssetLib for uint256;
    using SafeERC20 for IMockErc20;

    uint256 amount = 100e6;
    uint256 userSeed = 0;

    MockErc20 extraToken1;
    MockErc20 extraToken2;
    MockErc20 extraToken3;

    function setUp() public override {
        super.setUp();

        extraToken1 = new MockErc20("Extra1", "EX1", 18);
        extraToken2 = new MockErc20("Extra2", "EX2", 18);
        extraToken3 = new MockErc20("Extra3", "EX3", 18);

        // Seed initial deposit so default sub-vault stays active
        address firstUser = _generateNewUser();
        _mintAndApproveUsdc(firstUser);
        vm.prank(firstUser);
        vault.deposit(firstUser, address(USDC), amount);
    }

    // ==================== StableVault.sol:486 — getActiveSubVaults (STORAGE) ====================
    function test_gas_getActiveSubVaults() public {
        _createSubVaults(5);
        uint256 gasBefore = gasleft();
        vault.getActiveSubVaults();
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("GAS_getActiveSubVaults", gasUsed);
    }

    // ==================== StableVault.sol:827 — _getActiveSubVaultsObligations via getVaultObligations (STORAGE)
    // ======
    function test_gas_getVaultObligations() public {
        _createSubVaults(5);
        uint256 gasBefore = gasleft();
        vault.getVaultObligations();
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("GAS_getVaultObligations", gasUsed);
    }

    // ==================== FundsHandler.sol:113 — getAggregatedBalance (STORAGE EnumerableSet) ====================
    function test_gas_getAggregatedBalance() public {
        _addEarningChains(5);
        uint256 gasBefore = gasleft();
        fundsHandler.getAggregatedBalance();
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("GAS_getAggregatedBalance", gasUsed);
    }

    // ==================== StableVault.sol:456 — claimSurplusInterest body (CALLDATA) ==========
    // Also covers TransferHelperClient.sol:51,56,59 — modifier (MEMORY)
    function test_gas_claimSurplusInterest() public {
        _createSubVaults(5);

        uint256 usdcProfit = 100e6;
        uint256 ghoProfit = 100e18;
        USDC.mint(address(allocator_accountingChain), usdcProfit);
        GHO.mint(address(allocator_accountingChain), ghoProfit);

        address[] memory assets = _toAddressArray(address(USDC), address(GHO));
        uint256[] memory amounts = _toUint256Array(usdcProfit / 10, ghoProfit / 10);

        vm.prank(everyRoleAccount);
        uint256 gasBefore = gasleft();
        vault.claimSurplusInterest(assets, amounts);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("GAS_claimSurplusInterest", gasUsed);
    }

    // ==================== TransferHelper.sol:21 — pull (MEMORY) ====================
    function test_gas_transferHelper_pull() public {
        address th = transferHelper_accountingChainAddress;
        (address[] memory assets, uint256[] memory amounts) = _setupTransferHelperTokens(th, 5);

        vm.prank(address(this));
        uint256 gasBefore = gasleft();
        ITransferHelper(th).pull(assets, amounts);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("GAS_TH_pull", gasUsed);
    }

    // ==================== TransferHelper.sol:33 — transfer (MEMORY) ====================
    function test_gas_transferHelper_transfer() public {
        address th = transferHelper_accountingChainAddress;
        (address[] memory assets, uint256[] memory amounts) = _setupTransferHelperTokens(th, 5);
        address dest = makeAddr("destination");

        uint256 gasBefore = gasleft();
        ITransferHelper(th).transfer(assets, amounts, dest);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("GAS_TH_transfer", gasUsed);
    }

    // ==================== TransferHelper.sol:43 — transferToMultiple (MEMORY) ====================
    function test_gas_transferHelper_transferToMultiple() public {
        address th = transferHelper_accountingChainAddress;
        (address[] memory assets, uint256[] memory amounts) = _setupTransferHelperTokens(th, 5);
        address[] memory dests = new address[](5);
        for (uint256 i = 0; i < 5; i++) {
            dests[i] = makeAddr(string.concat("dest", Strings.toString(i)));
        }

        uint256 gasBefore = gasleft();
        ITransferHelper(th).transfer(assets, amounts, dests);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("GAS_TH_transferMultiple", gasUsed);
    }

    // ==================== Allocator.sol:514 — _getTrustedAssetBalances (MEMORY) ====================
    function test_gas_getTrustedAssetBalances() public {
        uint256 gasBefore = gasleft();
        allocator_accountingChain.getTrustedAssetBalances();
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("GAS_getTrustedAssetBalances", gasUsed);
    }

    // ==================== CcipAdapter.sol:178 — _processMessage (MEMORY struct) ====================
    function test_gas_ccipReceive_withTokens() public {
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](3);
        tokenAmounts[0] = Client.EVMTokenAmount({token: address(GHO), amount: 1e18});
        tokenAmounts[1] = Client.EVMTokenAmount({token: address(USDC), amount: 1e6});
        tokenAmounts[2] = Client.EVMTokenAmount({token: address(GHO), amount: 2e18});

        // Fund the adapter with tokens so _processReceivedFunds doesn't revert
        GHO.mint(address(ccipAdapter_accountingChain), 10e18);
        USDC.mint(address(ccipAdapter_accountingChain), 10e6);

        Client.Any2EVMMessage memory ccipMessage = Client.Any2EVMMessage({
            messageId: keccak256("g01-gas-test"),
            sourceChainSelector: EARNING_CHAIN_CCIP_SELECTOR,
            sender: abi.encode(address(ccipAdapter_earningChain)),
            data: "",
            destTokenAmounts: tokenAmounts
        });

        vm.prank(address(mockCcipRouter));
        uint256 gasBefore = gasleft();
        ccipAdapter_accountingChain.ccipReceive(ccipMessage);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("GAS_ccipReceive_withTokens", gasUsed);
    }

    function test_gas_ccipReceive_with1Token() public {
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount({token: address(GHO), amount: 1e18});

        GHO.mint(address(ccipAdapter_accountingChain), 10e18);

        Client.Any2EVMMessage memory ccipMessage = Client.Any2EVMMessage({
            messageId: keccak256("g01-gas-test-1token"),
            sourceChainSelector: EARNING_CHAIN_CCIP_SELECTOR,
            sender: abi.encode(address(ccipAdapter_earningChain)),
            data: "",
            destTokenAmounts: tokenAmounts
        });

        vm.prank(address(mockCcipRouter));
        uint256 gasBefore = gasleft();
        ccipAdapter_accountingChain.ccipReceive(ccipMessage);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("GAS_ccipReceive_1token", gasUsed);
    }

    function test_gas_ccipReceive_with2Tokens() public {
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](2);
        tokenAmounts[0] = Client.EVMTokenAmount({token: address(GHO), amount: 1e18});
        tokenAmounts[1] = Client.EVMTokenAmount({token: address(USDC), amount: 1e6});

        GHO.mint(address(ccipAdapter_accountingChain), 10e18);
        USDC.mint(address(ccipAdapter_accountingChain), 10e6);

        Client.Any2EVMMessage memory ccipMessage = Client.Any2EVMMessage({
            messageId: keccak256("g01-gas-test-2tokens"),
            sourceChainSelector: EARNING_CHAIN_CCIP_SELECTOR,
            sender: abi.encode(address(ccipAdapter_earningChain)),
            data: "",
            destTokenAmounts: tokenAmounts
        });

        vm.prank(address(mockCcipRouter));
        uint256 gasBefore = gasleft();
        ccipAdapter_accountingChain.ccipReceive(ccipMessage);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("GAS_ccipReceive_2tokens", gasUsed);
    }

    // ==================== CcipAdapter.sol:178 — _processMessage with 0 tokens ====================
    function test_gas_ccipReceive_noTokens() public {
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](0);

        Client.Any2EVMMessage memory ccipMessage = Client.Any2EVMMessage({
            messageId: keccak256("g01-gas-test-no-tokens"),
            sourceChainSelector: EARNING_CHAIN_CCIP_SELECTOR,
            sender: abi.encode(address(ccipAdapter_earningChain)),
            data: "",
            destTokenAmounts: tokenAmounts
        });

        vm.prank(address(mockCcipRouter));
        uint256 gasBefore = gasleft();
        ccipAdapter_accountingChain.ccipReceive(ccipMessage);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("GAS_ccipReceive_noTokens", gasUsed);
    }

    // ==================== StableVault.sol:331 — setUserRate (CALLDATA) ====================
    function test_gas_setUserRate() public {
        IStableVault.UserRateData[] memory rateData = new IStableVault.UserRateData[](5);
        uint256 rate = 1_000000001547125957863212449;
        for (uint256 i = 0; i < 5; i++) {
            address user = _generateNewUser();
            _mintAndApproveUsdc(user);
            vm.prank(user);
            vault.deposit(user, address(USDC), amount);
            rateData[i] = IStableVault.UserRateData(user, rate + i);
        }
        vm.prank(everyRoleAccount);
        uint256 gasBefore = gasleft();
        vault.setUserRate(rateData);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("GAS_setUserRate", gasUsed);
    }

    // ==================== PriceOracle.sol:68 — getPrices (CALLDATA) ====================
    function test_gas_getPrices() public {
        address mockAdapter = makeAddr("mockAdapter");
        IPriceOracleAdapter.OracleResponse memory resp =
            IPriceOracleAdapter.OracleResponse({priceRay: MathLib.RAY, isStale: false});
        vm.mockCall(mockAdapter, abi.encodeWithSelector(IPriceOracleAdapter.getPrice.selector), abi.encode(resp));
        vm.startPrank(admin);
        priceOracle_accountingChain.setOracleAdapterForAsset(address(USDC), mockAdapter);
        priceOracle_accountingChain.setOracleAdapterForAsset(address(GHO), mockAdapter);
        vm.stopPrank();

        address[] memory assets = new address[](2);
        assets[0] = address(USDC);
        assets[1] = address(GHO);
        uint256 gasBefore = gasleft();
        priceOracle_accountingChain.getPrices(assets);
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("GAS_getPrices", gasUsed);
    }

    // ==================== LocalBalanceAggregator.sol:31 — _getLocalAggregatedBalance (MEMORY, via
    // getAggregatedBalance) ==
    function test_gas_localAggregatedBalance() public {
        uint256 gasBefore = gasleft();
        fundsHandler.getAggregatedBalance();
        uint256 gasUsed = gasBefore - gasleft();
        emit log_named_uint("GAS_localAggregatedBalance", gasUsed);
    }

    // ==================== Helpers ====================

    function _generateNewUser() internal returns (address) {
        return makeAddr(string.concat("G01_USER[", Strings.toString(userSeed++), "]"));
    }

    function _mintAndApproveUsdc(address user) internal {
        USDC.mint(user, amount);
        vm.prank(user);
        USDC.approve(address(vault), amount);
    }

    function _createSubVaults(uint256 count) internal {
        uint256 rate = 1_000000001547125957863212449; // 5% APY
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

    function _addEarningChains(uint256 count) internal {
        for (uint256 i = 0; i < count; i++) {
            uint256 chainId = 100 + i;
            vm.prank(everyRoleAccount);
            fundsHandler.addEarningChain(chainId);

            vm.mockCall(
                address(chainBalanceOracle),
                abi.encodeWithSelector(IChainBalanceOracle.getChainBalance.selector, chainId),
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
        }
    }

    function _setupTransferHelperTokens(address th, uint256 count)
        internal
        returns (address[] memory assets, uint256[] memory amounts)
    {
        assets = new address[](count);
        amounts = new uint256[](count);
        for (uint256 i = 0; i < count; i++) {
            MockErc20 token = new MockErc20(
                string.concat("TH_Token", Strings.toString(i)), string.concat("TH", Strings.toString(i)), 18
            );
            token.mint(th, 100e18);
            assets[i] = address(token);
            amounts[i] = 1e18;
        }
    }
}

// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {Logger} from "test/helpers/Logger.sol";

import {StableVault} from "src/core/accounting/StableVault.sol";
import {IAccountingChainGateway} from "src/interfaces/IAccountingChainGateway.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {ICcipBridgeAdapter} from "src/interfaces/ICcipBridgeAdapter.sol";
import {IChainBalanceOracle} from "src/interfaces/IChainBalanceOracle.sol";
import {IChainBalanceOracleAdapter} from "src/interfaces/IChainBalanceOracleAdapter.sol";
import {IEarningChainStateProvider} from "src/interfaces/IEarningChainStateProvider.sol";
import {IPriceOracle} from "src/interfaces/IPriceOracle.sol";
import {IStableVault} from "src/interfaces/IStableVault.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {ChainlinkL2PriceOracleAdapter} from "src/oracles/price/ChainlinkL2PriceOracleAdapter.sol";
import {ChainlinkPriceOracleAdapter} from "src/oracles/price/ChainlinkPriceOracleAdapter.sol";
import {EarningChainStateSchemaV1} from "src/periphery/EarningChainStateSchemaV1.sol";
import {Constants} from "src/types/Constants.sol";

import {BaseTest} from "test/BaseTest.t.sol";
import {MockCCIPRouter} from "test/mocks/MockCcipRouter.sol";
import {MockChainlinkAggregator} from "test/mocks/MockChainlinkAggregator.sol";

/// @title OracleFeedE2ETest
/// @notice End-to-end tests validating the full oracle pipeline:
/// - Chain Balance publish path: EarningChainStateProvider -> MockBundleFeed
/// - Chain Balance read path: FundsHandler -> ChainBalanceOracle -> ChainlinkChainBalanceOracleAdapter ->
///   MockBundleFeed
/// - Price Oracle: MockChainlinkAggregator -> ChainlinkPriceOracleAdapter -> PriceOracle ->
///   LocalBalanceAggregator (inside FundsHandler & EarningChainGateway)
contract OracleFeedE2ETest is BaseTest {
    using AssetLib for uint256;
    using MathLib for uint256;

    address user1 = makeAddr("USER1");
    address user2 = makeAddr("USER2");

    uint256 constant HEARTBEAT = 3600; // 1 hour
    uint256 constant PUBLISH_BUFFER_SECONDS = 90;
    uint8 constant PRICE_FEED_DECIMALS = 8;
    int256 constant PRICE_ONE = 1e8;

    MockChainlinkAggregator usdcPriceFeed_accountingChain;
    MockChainlinkAggregator ghoPriceFeed_accountingChain;
    MockChainlinkAggregator usdcPriceFeed_earningChain;
    MockChainlinkAggregator ghoPriceFeed_earningChain;

    /// @dev Disable mocked price oracles for E2E tests to test full flow through to the external oracle contract.
    function _useMockedPriceOracleAccountingChain() internal view virtual override returns (bool) {
        return false;
    }

    /// @dev Disable mocked price oracles for E2E tests to test full flow through to the external oracle contract.
    function _useMockedPriceOracleEarningChain() internal view virtual override returns (bool) {
        return false;
    }

    function setUp() public override {
        super.setUp();

        // Deploy mocked aggregator feeds for price adapters
        usdcPriceFeed_accountingChain = new MockChainlinkAggregator(PRICE_FEED_DECIMALS);
        ghoPriceFeed_accountingChain = new MockChainlinkAggregator(PRICE_FEED_DECIMALS);
        usdcPriceFeed_earningChain = new MockChainlinkAggregator(PRICE_FEED_DECIMALS);
        ghoPriceFeed_earningChain = new MockChainlinkAggregator(PRICE_FEED_DECIMALS);

        mockSequencerUptimeFeed.setAnswer(0, 0);

        // Set all feeds to 1:1 and fresh
        usdcPriceFeed_accountingChain.setAnswer(PRICE_ONE, block.timestamp);
        ghoPriceFeed_accountingChain.setAnswer(PRICE_ONE, block.timestamp);
        usdcPriceFeed_earningChain.setAnswer(PRICE_ONE, block.timestamp);
        ghoPriceFeed_earningChain.setAnswer(PRICE_ONE, block.timestamp);

        vm.startPrank(admin);
        // Accounting chain uses L2 adapters (with sequencer uptime check)
        priceOracle_accountingChain.setOracleAdapterForAsset(
            address(USDC),
            address(
                new ChainlinkL2PriceOracleAdapter(
                    address(USDC), address(usdcPriceFeed_accountingChain), HEARTBEAT, address(mockSequencerUptimeFeed)
                )
            )
        );
        priceOracle_accountingChain.setOracleAdapterForAsset(
            address(GHO),
            address(
                new ChainlinkL2PriceOracleAdapter(
                    address(GHO), address(ghoPriceFeed_accountingChain), HEARTBEAT, address(mockSequencerUptimeFeed)
                )
            )
        );
        // Earning chain uses standard adapters (no sequencer uptime check)
        priceOracle_earningChain.setOracleAdapterForAsset(
            address(USDC),
            address(new ChainlinkPriceOracleAdapter(address(USDC), address(usdcPriceFeed_earningChain), HEARTBEAT))
        );
        priceOracle_earningChain.setOracleAdapterForAsset(
            address(GHO),
            address(new ChainlinkPriceOracleAdapter(address(GHO), address(ghoPriceFeed_earningChain), HEARTBEAT))
        );
        vm.stopPrank();
    }

    function _deployStableVault(
        address adminParam,
        uint256, // maxPerSecondRate
        uint256 defaultSubVaultPerSecondRate,
        address iouToken,
        address fundsHandlerAddr,
        address assetRegistry,
        address transferHelper,
        address withdrawalFeeCalculator,
        address priceOracle,
        uint256 maxActiveSubVaults,
        address treasuryAddress,
        address policyRegistry
    ) internal virtual override returns (StableVault) {
        // Deploy a vault without restriction in the valid per-second rate
        address vaultImpl = address(
            new StableVault(
                type(uint256).max,
                assetRegistry,
                iouToken,
                fundsHandlerAddr,
                transferHelper,
                withdrawalFeeCalculator,
                priceOracle,
                maxActiveSubVaults,
                policyRegistry
            )
        );
        return StableVault(
            address(
                new TransparentUpgradeableProxy(
                    address(vaultImpl),
                    proxyAdmin,
                    abi.encodeCall(
                        StableVault.initialize,
                        (adminParam, treasuryAddress, defaultSubVaultPerSecondRate, "Aave USD Stable Vault", "ASV-USD")
                    )
                )
            )
        );
    }

    // -----------------------------------------------------------------------
    // Chain Balance Oracle Feed Tests
    // -----------------------------------------------------------------------

    /// @notice Full withdrawal E2E flowing through the oracle feed pipeline.
    function test_oracleFeedWithdrawalE2E() public {
        Logger.log("\nOracleFeedE2ETest - Withdrawal E2E");

        uint256 userInitialDeposit = 500 * (10 ** 6);

        // 0. Set the default rate on Stable Vault to 5% APY
        vm.prank(everyRoleAccount);
        vault.setDefaultSubVault(1_000000001547125957863212449);

        // 1. User1 deposits 500 USDC to Vault on Accounting Chain
        _mintAndDepositUsdcToStableVault(user1, userInitialDeposit);

        assertEq(
            fundsHandler.getAggregatedBalance(),
            userInitialDeposit.assetDecimalsToRay(address(USDC)),
            "Funds handler should have the deposited amount of USDC"
        );

        // 2. Bridge the assets to the Earning Chain
        _bridgeUsdcToEarningChain(userInitialDeposit);

        // Check the FundsHandler does not see the Earning Chain balance yet
        assertEq(fundsHandler.getAggregatedBalance(), 0, "Funds handler should not see the Earning Chain balance yet");

        // 3. Publish and sync oracle via the feed pipeline
        _publishAndSyncOracle();

        // Verify the FundsHandler now sees the Earning Chain balance via the oracle
        uint256 earningChainBalanceRay = userInitialDeposit.assetDecimalsToRay(address(USDC));
        assertEq(
            fundsHandler.getAggregatedBalance(),
            earningChainBalanceRay,
            "FundsHandler should see the Earning Chain balance via the oracle"
        );

        // Move time forward to simulate interest accrual
        _warpAndRefreshPriceOracles(183 days);
        Logger.log("\nHalf a year has gone by so fast...");

        // Check that the user's balance in the Stable Vault on the Accounting Chain has grown
        uint256 userBalanceWithInterest = vault.getUserBalance(user1);
        assertGt(
            userBalanceWithInterest,
            userInitialDeposit.assetDecimalsToRay(address(USDC)),
            "User should have the deposited amount of USDC"
        );

        // Check that if the user request a full withdrawal, the system will revert
        vm.expectRevert(
            abi.encodeWithSelector(
                IStableVault.InsufficientAssets.selector,
                user1,
                userBalanceWithInterest,
                userInitialDeposit.assetDecimalsToRay(address(USDC))
            )
        );
        vm.prank(user1);
        vault.requestWithdrawal(user1, userBalanceWithInterest, "");

        // Top up Earning Chain Allocator with USDC to simulate interest accrual
        uint256 interestAccrued = userBalanceWithInterest - userInitialDeposit.assetDecimalsToRay(address(USDC));
        // Conversion to asset decimals truncates the RAY, so we need to add 1 wei to cover the precision loss
        USDC.mint(address(allocator_earningChain), interestAccrued.rayToAssetDecimals(address(USDC)) + 1);

        // Publish and sync oracle to reflect pre-exchange balance
        _publishAndSyncOracle();

        // 4. User requests withdrawal -> gets IOUs
        vm.prank(user1);
        vault.requestWithdrawal(user1, userBalanceWithInterest, "");
        assertEq(
            iouToken_accountingChain.balanceOf(user1), userBalanceWithInterest, "User should have minted IOU tokens"
        );

        // 5. Bridge IOUs to Earning Chain
        uint256 bridgeFeeAmount = 1000;
        vm.prank(user1);
        IERC20(address(iouToken_accountingChain))
            .approve(address(iouTokenManager_accountingChain), userBalanceWithInterest);
        vm.deal(user1, bridgeFeeAmount);
        vm.prank(user1);
        vault.bridgeIouTokens{value: bridgeFeeAmount}(
            EARNING_CHAIN_ID,
            user1,
            userBalanceWithInterest,
            address(ccipAdapter_accountingChain),
            DEFAULT_GAS_LIMIT,
            abi.encode(
                ICcipBridgeAdapter.CcipFeeParams({
                    feeToken: Constants.NATIVE_CURRENCY, feeAmount: bridgeFeeAmount, feeRefundThreshold: 0
                })
            ),
            ""
        );
        assertEq(iouToken_accountingChain.balanceOf(user1), 0, "User should have bridged IOU tokens");

        // 6. Publish and sync oracle to reflect pre-exchange balance
        _publishAndSyncOracle();

        // 7. User exchanges IOU tokens on Earning Chain
        uint256 amountIouToExchange = userBalanceWithInterest;
        vm.deal(user1, 1000);
        // Mock oracle to reflect balance after IOU exchange (Accounting Chain gateway processes burn)
        uint256 earningBalanceBefore = earningChainGateway.getAggregatedBalance();
        _mockChainBalance(
            EARNING_CHAIN_ID,
            earningBalanceBefore - amountIouToExchange,
            block.timestamp,
            block.timestamp - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS,
            false
        );
        vm.prank(user1);
        earningChainGateway.exchangeIouTokens{value: 1}(
            amountIouToExchange,
            address(USDC),
            0,
            user1,
            address(ccipAdapter_earningChain),
            DEFAULT_GAS_LIMIT,
            abi.encode(
                ICcipBridgeAdapter.CcipFeeParams({
                    feeToken: Constants.NATIVE_CURRENCY, feeAmount: 1, feeRefundThreshold: 0
                })
            ),
            ""
        );

        // 8. Verify user received the assets
        assertEq(iouToken_earningChain.balanceOf(user1), 0, "User should have exchanged all IOUs");
        assertGt(IERC20(address(USDC)).balanceOf(user1), 0, "User should have received USDC after exchanging IOUs");
    }

    /// @notice Validates that publishing state through the feed pipeline produces the same balance
    /// as reading EarningChainStateProvider directly.
    function test_oracleFeed_publishState_matchesEarningChainStateProvider() public {
        uint256 userDeposit = 1000 * (10 ** 6);

        _mintAndDepositUsdcToStableVault(user1, userDeposit);
        _bridgeUsdcToEarningChain(userDeposit);

        // Read state directly from EarningChainStateProvider
        bytes memory stateBytes = earningChainStateProvider.getState();
        IEarningChainStateProvider.State memory state = abi.decode(stateBytes, (IEarningChainStateProvider.State));
        EarningChainStateSchemaV1.BalanceSnapshot memory snapshot =
            abi.decode(state.data, (EarningChainStateSchemaV1.BalanceSnapshot));

        // Publish to MockBundleFeed and read via adapter
        mockBundleFeed.publishState(stateBytes);
        IChainBalanceOracle.ChainBalance memory earningChainBalanceFromOracle =
            chainBalanceOracleAdapter.getChainBalance(EARNING_CHAIN_ID);

        // Assert adapter balance matches direct read
        assertEq(
            earningChainBalanceFromOracle.balanceRay,
            snapshot.balanceRay,
            "Adapter balance should match direct EarningChainStateProvider read"
        );
        assertEq(
            earningChainBalanceFromOracle.sourceChainTimestamp,
            snapshot.timestamp,
            "Adapter source timestamp should match snapshot timestamp"
        );
        assertEq(
            earningChainBalanceFromOracle.sourceChainBlockNumber,
            snapshot.blockNumber,
            "Adapter source block number should match snapshot block number"
        );
        assertFalse(earningChainBalanceFromOracle.isStale, "Fresh publish should not be stale");
    }

    /// @notice Validates staleness detection after heartbeat + buffer elapses.
    function test_oracleFeed_staleness() public {
        uint256 userDeposit = 100 * (10 ** 6);

        _mintAndDepositUsdcToStableVault(user1, userDeposit);
        _bridgeUsdcToEarningChain(userDeposit);

        // Publish state (sets _latestBundleTimestamp = block.timestamp)
        bytes memory stateBytes = earningChainStateProvider.getState();
        mockBundleFeed.publishState(stateBytes);

        // Verify not stale initially
        IChainBalanceOracle.ChainBalance memory cbFresh = chainBalanceOracleAdapter.getChainBalance(EARNING_CHAIN_ID);
        assertFalse(cbFresh.isStale, "Should not be stale immediately after publish");

        // Warp past heartbeat + buffer
        _warpAndRefreshPriceOracles(HEARTBEAT + PUBLISH_BUFFER_SECONDS);

        // Should now be stale
        IChainBalanceOracle.ChainBalance memory cbStale = chainBalanceOracleAdapter.getChainBalance(EARNING_CHAIN_ID);
        assertTrue(cbStale.isStale, "Should be stale after heartbeat + buffer");
    }

    /// @notice Stale chain balance oracle causes FundsHandler to report zero for that Earning Chain,
    /// which deflates aggregated balance and can block interest-bearing withdrawals.
    function test_oracleFeed_staleChainBalance_deflatesAggregatedBalance() public {
        uint256 userDeposit = 500 * (10 ** 6);

        // Set 5% APY so user accrues interest
        vm.prank(everyRoleAccount);
        vault.setDefaultSubVault(1_000000001547125957863212449);

        _mintAndDepositUsdcToStableVault(user1, userDeposit);
        _bridgeUsdcToEarningChain(userDeposit);

        // Sync oracle -- balance is visible
        _publishAndSyncOracle();
        uint256 balanceBeforeStale = fundsHandler.getAggregatedBalance();
        assertGt(balanceBeforeStale, 0, "Balance should be non-zero before stale");

        // Mark the chain balance as stale
        _mockChainBalance(EARNING_CHAIN_ID, userDeposit.assetDecimalsToRay(address(USDC)), 0, 0, true);

        // Aggregated balance should now exclude the Earning Chain (returns 0 for stale)
        uint256 balanceAfterStale = fundsHandler.getAggregatedBalance();
        assertEq(balanceAfterStale, 0, "Stale Earning Chain should contribute zero to aggregated balance");

        // Warp time so user accrues interest
        _warpAndRefreshPriceOracles(90 days);

        // User's vault balance has grown, but the system sees 0 assets -- withdrawal of interest should fail
        uint256 userBalance = vault.getUserBalance(user1);
        assertGt(userBalance, userDeposit.assetDecimalsToRay(address(USDC)), "User should have accrued interest");

        // Attempting to withdraw the full balance (including interest) should fail with InsufficientAssets
        vm.expectRevert(
            abi.encodeWithSelector(
                IStableVault.InsufficientAssets.selector,
                user1,
                userBalance,
                userDeposit.assetDecimalsToRay(address(USDC))
            )
        );
        vm.prank(user1);
        vault.requestWithdrawal(user1, userBalance, "");

        // Recovery: restore oracle and user can now withdraw
        _mockChainBalance(
            EARNING_CHAIN_ID,
            userDeposit.assetDecimalsToRay(address(USDC)),
            block.timestamp,
            block.timestamp - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS,
            false
        );
        uint256 balanceAfterRecovery = fundsHandler.getAggregatedBalance();
        assertEq(
            balanceAfterRecovery,
            userDeposit.assetDecimalsToRay(address(USDC)),
            "Balance should recover after oracle un-stales"
        );

        // User can now withdraw their original deposit (not the interest beyond available)
        uint256 guaranteedAmount = userDeposit.assetDecimalsToRay(address(USDC));
        vm.prank(user1);
        vault.requestWithdrawal(user1, guaranteedAmount, "");
        assertEq(iouToken_accountingChain.balanceOf(user1), guaranteedAmount, "User should receive IOUs after recovery");
    }

    /// @notice Version mismatch in the adapter causes a revert that cascades through the system.
    function test_oracleFeed_versionMismatch_reverts() public {
        // Construct a state with version=2 (adapter expects version=1)
        EarningChainStateSchemaV1.BalanceSnapshot memory snapshot = EarningChainStateSchemaV1.BalanceSnapshot({
            balanceRay: 1000 * MathLib.RAY,
            timestamp: block.timestamp,
            blockNumber: block.number,
            // Need to set the same chainId because the e2e test simulates 2 chains although they are the same.
            chainId: block.chainid
        });
        bytes memory stateBytes = abi.encode(IEarningChainStateProvider.State({version: 2, data: abi.encode(snapshot)}));

        mockBundleFeed.publishState(stateBytes);

        // Adapter should revert with InvalidEarningChainStateVersion
        vm.expectRevert(
            abi.encodeWithSelector(IChainBalanceOracleAdapter.InvalidEarningChainStateVersion.selector, 1, 2)
        );
        chainBalanceOracleAdapter.getChainBalance(EARNING_CHAIN_ID);
    }

    /// @notice Adapter rejects queries for the wrong chain ID.
    function test_oracleFeed_wrongChainId_reverts() public {
        uint256 wrongChainId = 999;
        vm.expectRevert(abi.encodeWithSelector(IChainBalanceOracleAdapter.InvalidChainId.selector, wrongChainId));
        chainBalanceOracleAdapter.getChainBalance(wrongChainId);
    }

    /// @notice Staleness boundary: not stale at heartbeat + buffer - 1, stale at heartbeat + buffer.
    function test_oracleFeed_stalenessBoundary() public {
        uint256 userDeposit = 100 * (10 ** 6);
        _mintAndDepositUsdcToStableVault(user1, userDeposit);
        _bridgeUsdcToEarningChain(userDeposit);

        bytes memory stateBytes = earningChainStateProvider.getState();
        mockBundleFeed.publishState(stateBytes);

        // Just before threshold: should NOT be stale
        _warpAndRefreshPriceOracles(HEARTBEAT + PUBLISH_BUFFER_SECONDS - 1);
        IChainBalanceOracle.ChainBalance memory cbBefore = chainBalanceOracleAdapter.getChainBalance(EARNING_CHAIN_ID);
        assertFalse(cbBefore.isStale, "Should not be stale 1 second before threshold");

        // Exactly at threshold: should be stale
        _warpAndRefreshPriceOracles(1);
        IChainBalanceOracle.ChainBalance memory cbAt = chainBalanceOracleAdapter.getChainBalance(EARNING_CHAIN_ID);
        assertTrue(cbAt.isStale, "Should be stale exactly at threshold");
    }

    // -----------------------------------------------------------------------
    // Price Oracle E2E Tests
    // -----------------------------------------------------------------------

    /// @notice When Accounting Chain price oracle returns 0 (stale), the local balance aggregator
    /// zeroes that asset's contribution to getAggregatedBalance().
    function test_priceOracle_stalePriceOnAccountingChain_zerosLocalBalance() public {
        uint256 userDeposit = 500 * (10 ** 6);

        _mintAndDepositUsdcToStableVault(user1, userDeposit);

        // With normal 1 RAY price, balance is correct
        uint256 balanceBefore = fundsHandler.getAggregatedBalance();
        assertEq(
            balanceBefore,
            userDeposit.assetDecimalsToRay(address(USDC)),
            "Balance should reflect deposit with valid price"
        );

        // Simulate stale price at the adapter level.
        usdcPriceFeed_accountingChain.setAnswer(PRICE_ONE, _staleUpdateTimestamp());

        // Local aggregated balance should now be 0
        uint256 balanceAfterStale = fundsHandler.getAggregatedBalance();
        assertEq(balanceAfterStale, 0, "Stale price should zero out asset contribution to local balance");

        // Restore fresh price -- balance recovers
        usdcPriceFeed_accountingChain.setAnswer(PRICE_ONE, block.timestamp);
        uint256 balanceAfterRecovery = fundsHandler.getAggregatedBalance();
        assertEq(
            balanceAfterRecovery,
            userDeposit.assetDecimalsToRay(address(USDC)),
            "Balance should recover when price is restored"
        );
    }

    /// @notice When price oracle is stale, validatePrice reverts, which blocks deposits to Stable Vault.
    function test_priceOracle_stalePriceBlocksDeposits() public {
        // Make USDC adapter stale.
        usdcPriceFeed_accountingChain.setAnswer(PRICE_ONE, _staleUpdateTimestamp());

        // Deposit should revert because validatePrice is called during deposit
        uint256 depositAmount = 100 * (10 ** 6);
        USDC.mint(user1, depositAmount);
        vm.startPrank(user1);
        USDC.approve(address(vault), depositAmount);
        vm.expectRevert(abi.encodeWithSelector(IPriceOracle.StalePrice.selector));
        vault.deposit(user1, address(USDC), depositAmount, "");
        vm.stopPrank();
    }

    /// @notice Stale price on the Earning Chain causes EarningChainStateProvider to report zero balance,
    /// which propagates through the entire oracle feed pipeline.
    function test_priceOracle_stalePriceOnEarningChain_zerosEarningChainStateProviderBalance() public {
        uint256 userDeposit = 500 * (10 ** 6);

        _mintAndDepositUsdcToStableVault(user1, userDeposit);
        _bridgeUsdcToEarningChain(userDeposit);

        // With valid price on Earning Chain, EarningChainStateProvider reports full balance
        bytes memory stateBefore = earningChainStateProvider.getState();
        IEarningChainStateProvider.State memory decodedBefore =
            abi.decode(stateBefore, (IEarningChainStateProvider.State));
        EarningChainStateSchemaV1.BalanceSnapshot memory snapBefore =
            abi.decode(decodedBefore.data, (EarningChainStateSchemaV1.BalanceSnapshot));
        assertEq(
            snapBefore.balanceRay,
            userDeposit.assetDecimalsToRay(address(USDC)),
            "Earning chain state should report full balance with valid price"
        );

        // Stale price on Earning Chain -> PriceOracle.getPrice returns 0
        usdcPriceFeed_earningChain.setAnswer(PRICE_ONE, _staleUpdateTimestamp());

        // EarningChainStateProvider now reports 0 balance
        bytes memory stateAfter = earningChainStateProvider.getState();
        IEarningChainStateProvider.State memory decodedAfter =
            abi.decode(stateAfter, (IEarningChainStateProvider.State));
        EarningChainStateSchemaV1.BalanceSnapshot memory snapAfter =
            abi.decode(decodedAfter.data, (EarningChainStateSchemaV1.BalanceSnapshot));
        assertEq(snapAfter.balanceRay, 0, "Earning chain state should report zero balance with stale price");

        // Publish this zero-balance snapshot through the feed pipeline
        mockBundleFeed.publishState(stateAfter);
        // On the Accounting Chain, the balance reflected by the ChainBalanceOracle should be 0
        IChainBalanceOracle.ChainBalance memory earningChainBalanceFromOracle =
            chainBalanceOracleAdapter.getChainBalance(EARNING_CHAIN_ID);
        assertEq(
            earningChainBalanceFromOracle.balanceRay,
            0,
            "Adapter should report zero balance from stale Earning Chain price"
        );
        assertFalse(earningChainBalanceFromOracle.isStale, "Feed itself is fresh - only the embedded balance is zero");
    }

    /// @notice Price drop below MIN_VALID_PRICE_RAY blocks deposits (validatePrice reverts with InvalidPrice)
    /// but getPrice still returns the depegged price for balance calculations.
    function test_priceOracle_depeggedPrice_blocksDepositsButReportsBalance() public {
        uint256 userDeposit = 500 * (10 ** 6);
        _mintAndDepositUsdcToStableVault(user1, userDeposit);

        // Simulate a depeg: price drops to 0.90 RAY (below MIN_VALID_PRICE_RAY of 0.9995 RAY)
        uint256 depeggedPrice = 9e26; // 0.90 RAY
        // forge-lint: disable-next-line(unsafe-typecast)
        usdcPriceFeed_accountingChain.setAnswer(int256(depeggedPrice / 1e19), block.timestamp);

        // getAggregatedBalance uses getPrice (which returns the depegged price - NOT zero, since not stale)
        uint256 expectedBalance = depeggedPrice.rayMulDown(userDeposit.assetDecimalsToRay(address(USDC)));
        uint256 actualBalance = fundsHandler.getAggregatedBalance();
        assertEq(actualBalance, expectedBalance, "Balance should be price-adjusted for depeg");
        assertLt(
            actualBalance, userDeposit.assetDecimalsToRay(address(USDC)), "Balance should be less than nominal deposit"
        );

        // But validatePrice should block new deposits due to MIN_VALID_PRICE_RAY.
        uint256 newDeposit = 100 * (10 ** 6);
        USDC.mint(user2, newDeposit);
        vm.startPrank(user2);
        USDC.approve(address(vault), newDeposit);
        vm.expectRevert(abi.encodeWithSelector(IPriceOracle.PriceTooLow.selector));
        vault.deposit(user2, address(USDC), newDeposit, "");
        vm.stopPrank();
    }

    /// @notice Multi-asset scenario: one asset price goes stale, only that asset's balance is zeroed.
    /// The other asset's balance is unaffected.
    function test_priceOracle_partialStaleness_onlyAffectedAssetZeroed() public {
        uint256 usdcDeposit = 500 * (10 ** 6);
        uint256 ghoDeposit = 500 ether;

        // Deposit USDC
        _mintAndDepositUsdcToStableVault(user1, usdcDeposit);

        // Deposit GHO
        GHO.mint(user2, ghoDeposit);
        vm.startPrank(user2);
        GHO.approve(address(vault), ghoDeposit);
        vault.deposit(user2, address(GHO), ghoDeposit, "");
        vm.stopPrank();

        // Both assets at price 1 RAY
        uint256 fullBalance = fundsHandler.getAggregatedBalance();
        uint256 usdcRay = usdcDeposit.assetDecimalsToRay(address(USDC));
        uint256 ghoRay = ghoDeposit.assetDecimalsToRay(address(GHO));
        assertEq(fullBalance, usdcRay + ghoRay, "Full balance should include both assets");

        // Make USDC stale, keep GHO fresh.
        usdcPriceFeed_accountingChain.setAnswer(PRICE_ONE, _staleUpdateTimestamp());
        ghoPriceFeed_accountingChain.setAnswer(PRICE_ONE, block.timestamp);

        uint256 partialBalance = fundsHandler.getAggregatedBalance();
        assertEq(partialBalance, ghoRay, "Only GHO should contribute when USDC price is stale");

        // Restore USDC price
        usdcPriceFeed_accountingChain.setAnswer(PRICE_ONE, block.timestamp);
        assertEq(fundsHandler.getAggregatedBalance(), usdcRay + ghoRay, "Full balance should restore");
    }

    // -----------------------------------------------------------------------
    // Combined Oracle Edge Cases
    // -----------------------------------------------------------------------

    /// @notice Both price and chain balance oracles going stale simultaneously.
    /// Verifies the system under-reports but doesn't revert for view calls.
    function test_combined_bothOraclesStale_systemUnderReportsButDoesNotRevert() public {
        uint256 localDeposit = 300 * (10 ** 6);
        uint256 earningDeposit = 200 * (10 ** 6);

        // Deposit locally + bridge some to Earning Chain
        _mintAndDepositUsdcToStableVault(user1, localDeposit + earningDeposit);
        _bridgeUsdcToEarningChain(earningDeposit);
        _publishAndSyncOracle();

        uint256 expectedTotal = (localDeposit + earningDeposit).assetDecimalsToRay(address(USDC));
        assertEq(fundsHandler.getAggregatedBalance(), expectedTotal, "Baseline total should be correct");

        // Stale both: price oracle returns 0 for USDC, chain balance is stale
        usdcPriceFeed_accountingChain.setAnswer(PRICE_ONE, _staleUpdateTimestamp());
        _mockChainBalance(EARNING_CHAIN_ID, earningDeposit.assetDecimalsToRay(address(USDC)), 0, 0, true);

        // Both zeroed - total is 0 but view call does NOT revert
        uint256 staleTotalBalance = fundsHandler.getAggregatedBalance();
        assertEq(staleTotalBalance, 0, "Both stale should produce zero aggregated balance");

        // Restore both
        usdcPriceFeed_accountingChain.setAnswer(PRICE_ONE, block.timestamp);
        _mockChainBalance(
            EARNING_CHAIN_ID,
            earningDeposit.assetDecimalsToRay(address(USDC)),
            block.timestamp,
            block.timestamp - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS,
            false
        );
        assertEq(fundsHandler.getAggregatedBalance(), expectedTotal, "Should recover after both oracles restore");
    }

    /// @notice Stale price on Earning Chain produces a zero-balance snapshot. After price recovers
    /// and a new snapshot is published, the balance bounces back. Verifies the adapter faithfully
    /// reports whatever the feed contains (zero or non-zero).
    function test_combined_earningChainPriceStale_snapshotRecovery() public {
        uint256 userDeposit = 500 * (10 ** 6);
        _mintAndDepositUsdcToStableVault(user1, userDeposit);
        _bridgeUsdcToEarningChain(userDeposit);

        // Normal snapshot
        _publishAndSyncOracle();
        uint256 normalBalance = fundsHandler.getAggregatedBalance();
        assertGt(normalBalance, 0, "Should have non-zero balance");

        // Stale Earning Chain price -> publish zero-balance snapshot
        usdcPriceFeed_earningChain.setAnswer(PRICE_ONE, _staleUpdateTimestamp());
        _publishAndSyncOracle();
        assertEq(
            fundsHandler.getAggregatedBalance(), 0, "Zero-balance snapshot should be published when earning price stale"
        );

        // Price recovers on Earning Chain -> publish corrected snapshot
        usdcPriceFeed_earningChain.setAnswer(PRICE_ONE, block.timestamp);
        _publishAndSyncOracle();
        assertEq(
            fundsHandler.getAggregatedBalance(),
            userDeposit.assetDecimalsToRay(address(USDC)),
            "Balance should recover after Earning Chain price restores"
        );
    }

    /// @notice Withdrawal request with interest should fail when the chain balance oracle is stale,
    /// because the system can't verify solvency for the interest portion.
    function test_combined_staleOracleBlocksInterestWithdrawal_originalDepositStillWorks() public {
        uint256 userDeposit = 500 * (10 ** 6);

        // Set a rate so user accrues interest
        vm.prank(everyRoleAccount);
        vault.setDefaultSubVault(1_000000001547125957863212449); // ~5% APY

        _mintAndDepositUsdcToStableVault(user1, userDeposit);
        _bridgeUsdcToEarningChain(userDeposit);
        _publishAndSyncOracle();

        // Warp 1 year to accrue interest
        _warpAndRefreshPriceOracles(365 days);

        uint256 userBalance = vault.getUserBalance(user1);
        uint256 depositRay = userDeposit.assetDecimalsToRay(address(USDC));
        assertGt(userBalance, depositRay, "User should have accrued interest");

        // Mark chain balance as stale - aggregated balance drops to 0 (no local funds)
        _mockChainBalance(EARNING_CHAIN_ID, depositRay, 0, 0, true);

        // Full withdrawal (with interest) should fail - no interest available when balance is 0
        vm.expectRevert();
        vm.prank(user1);
        vault.requestWithdrawal(user1, userBalance, "");

        // But withdrawing the original guaranteed amount should still succeed
        // since guaranteedObligations includes the originalDeposit and the interest portion is 0
        vm.prank(user1);
        vault.requestWithdrawal(user1, depositRay, "");
        assertEq(
            iouToken_accountingChain.balanceOf(user1),
            depositRay,
            "User should be able to withdraw guaranteed deposit even with stale oracle"
        );
    }

    /// @notice Price oracle capping: prices above 1 RAY are capped to 1 RAY.
    /// This means a token trading above peg doesn't inflate the aggregated balance.
    function test_priceOracle_priceAboveOneRay_capped() public {
        uint256 userDeposit = 500 * (10 ** 6);
        _mintAndDepositUsdcToStableVault(user1, userDeposit);

        // Set USDC feed to 1.5 with 8 decimals.
        usdcPriceFeed_accountingChain.setAnswer(15e7, block.timestamp);

        // getAggregatedBalance should use the capped price (1 RAY), not 1.5 RAY.
        uint256 balance = fundsHandler.getAggregatedBalance();
        uint256 depositRay = userDeposit.assetDecimalsToRay(address(USDC));
        assertEq(balance, depositRay, "Price should be capped to 1 RAY");

        // At exactly 1 RAY, balance remains the same.
        usdcPriceFeed_accountingChain.setAnswer(PRICE_ONE, block.timestamp);
        uint256 cappedBalance = fundsHandler.getAggregatedBalance();
        assertEq(cappedBalance, depositRay, "At 1 RAY price, balance should equal deposit");
    }

    /// @notice EarningChainStateProvider produces a consistent balance snapshot that round-trips through
    /// the full feed pipeline without loss of precision.
    function test_oracleFeed_precisionRoundTrip() public {
        // Use an odd amount to test precision
        uint256 userDeposit = 123_456_789; // 123.456789 USDC
        _mintAndDepositUsdcToStableVault(user1, userDeposit);
        _bridgeUsdcToEarningChain(userDeposit);

        // Direct read from EarningChainStateProvider
        bytes memory stateBytes = earningChainStateProvider.getState();
        IEarningChainStateProvider.State memory state = abi.decode(stateBytes, (IEarningChainStateProvider.State));
        EarningChainStateSchemaV1.BalanceSnapshot memory snapshot =
            abi.decode(state.data, (EarningChainStateSchemaV1.BalanceSnapshot));

        // Round-trip through feed pipeline
        mockBundleFeed.publishState(stateBytes);
        IChainBalanceOracle.ChainBalance memory earningChainBalanceFromOracle =
            chainBalanceOracleAdapter.getChainBalance(EARNING_CHAIN_ID);

        assertEq(
            earningChainBalanceFromOracle.balanceRay,
            snapshot.balanceRay,
            "Balance should survive round-trip without precision loss"
        );
        assertEq(
            earningChainBalanceFromOracle.balanceRay,
            userDeposit.assetDecimalsToRay(address(USDC)),
            "Round-tripped balance should match deposit in RAY"
        );
    }

    // -----------------------------------------------------------------------
    // Cross-Chain Fund Return Tests
    // -----------------------------------------------------------------------

    /// @notice Full round-trip: deposit on Accounting Chain, bridge to Earning Chain, oracle sync,
    /// return funds to Accounting Chain, oracle re-sync. Verifies balances are consistent throughout.
    function test_oracleFeed_pushAndReturnFundsRoundTrip() public {
        uint256 depositAmount = 500 * (10 ** 6);
        uint256 depositRay = depositAmount.assetDecimalsToRay(address(USDC));

        // 1. Deposit USDC into Stable Vault on Accounting Chain
        _mintAndDepositUsdcToStableVault(user1, depositAmount);
        assertEq(fundsHandler.getAggregatedBalance(), depositRay, "Initial aggregated balance should match deposit");

        // 2. Bridge USDC to Earning Chain
        _bridgeUsdcToEarningChain(depositAmount);

        // Verify funds left on Accounting Chain (local balance is 0)
        assertEq(fundsHandler.getAggregatedBalance(), 0, "Local balance should be zero after bridging to Earning Chain");

        // Verify funds arrived on Earning Chain
        address defaultUsdcVault_earningChain = allocator_earningChain.getDefaultStrategy(address(USDC));
        assertEq(
            IERC20(address(USDC)).balanceOf(defaultUsdcVault_earningChain),
            depositAmount,
            "Earning chain strategy should have the USDC"
        );

        // 3. Publish and sync oracle - FundsHandler sees Earning Chain balance
        _publishAndSyncOracle();
        assertEq(
            fundsHandler.getAggregatedBalance(),
            depositRay,
            "Aggregated balance should reflect Earning Chain balance via oracle"
        );

        // Verify EarningChainStateProvider reports the correct balance
        bytes memory stateBytes = earningChainStateProvider.getState();
        IEarningChainStateProvider.State memory state = abi.decode(stateBytes, (IEarningChainStateProvider.State));
        EarningChainStateSchemaV1.BalanceSnapshot memory snapshot =
            abi.decode(state.data, (EarningChainStateSchemaV1.BalanceSnapshot));
        assertEq(snapshot.balanceRay, depositRay, "EarningChainStateProvider should report full deposit");

        // 4. Return funds from Earning Chain to Accounting Chain
        // The RETURN_FUNDS message includes the source block number. The oracle snapshot must include a source block
        // number at or after that message block.
        // Since we just synced the oracle at the current block, the validation will pass.
        uint256 returnAmount = depositAmount;
        uint256 bridgeFeeAmount = 1000;
        vm.prank(everyRoleAccount);
        vm.deal(everyRoleAccount, bridgeFeeAmount);
        earningChainGateway.pushFundsToAccountingChain{value: bridgeFeeAmount}(
            address(USDC),
            returnAmount,
            address(ccipAdapter_earningChain),
            DEFAULT_GAS_LIMIT,
            abi.encode(
                ICcipBridgeAdapter.CcipFeeParams({
                    feeToken: Constants.NATIVE_CURRENCY, feeAmount: bridgeFeeAmount, feeRefundThreshold: 0
                })
            )
        );

        // 5. Verify funds arrived back on Accounting Chain
        address defaultUsdcVault_accountingChain = allocator_accountingChain.getDefaultStrategy(address(USDC));
        assertEq(
            IERC20(address(USDC)).balanceOf(defaultUsdcVault_accountingChain),
            returnAmount,
            "Accounting chain strategy should have the returned USDC"
        );

        // 6. Earning chain now has 0 balance - re-sync oracle
        _publishAndSyncOracle();

        // 7. Verify final state: all funds are back on Accounting Chain, oracle reports 0 for Earning Chain
        assertEq(
            fundsHandler.getAggregatedBalance(),
            depositRay,
            "Aggregated balance should be back to initial deposit (local only)"
        );

        // Verify Earning Chain reports 0
        IChainBalanceOracle.ChainBalance memory earningChainBalanceFromOracle =
            chainBalanceOracleAdapter.getChainBalance(EARNING_CHAIN_ID);
        assertEq(earningChainBalanceFromOracle.balanceRay, 0, "Earning chain balance should be 0 after funds returned");
        // The Earning Chain balance snapshot should reflect 0 after funds were returned
        bytes memory finalStateBytes = earningChainStateProvider.getState();
        IEarningChainStateProvider.State memory finalState =
            abi.decode(finalStateBytes, (IEarningChainStateProvider.State));
        EarningChainStateSchemaV1.BalanceSnapshot memory finalSnapshot =
            abi.decode(finalState.data, (EarningChainStateSchemaV1.BalanceSnapshot));
        assertEq(finalSnapshot.balanceRay, 0, "Earning chain should report zero after funds returned");
    }

    /// @notice Partial return: bridge funds to Earning Chain, return only a portion, verify both
    /// local and oracle-reported balances are correct.
    function test_oracleFeed_partialReturnFunds() public {
        uint256 depositAmount = 1000 * (10 ** 6);
        uint256 depositRay = depositAmount.assetDecimalsToRay(address(USDC));
        uint256 returnAmount = 400 * (10 ** 6); // Return 400 of 1000 USDC
        uint256 returnRay = returnAmount.assetDecimalsToRay(address(USDC));
        uint256 remainingRay = depositRay - returnRay;

        // Deposit and bridge to Earning Chain
        _mintAndDepositUsdcToStableVault(user1, depositAmount);
        _bridgeUsdcToEarningChain(depositAmount);
        _publishAndSyncOracle();

        assertEq(fundsHandler.getAggregatedBalance(), depositRay, "Full deposit should be on Earning Chain");

        // Return only 400 USDC
        uint256 bridgeFeeAmount = 1000;
        vm.prank(everyRoleAccount);
        vm.deal(everyRoleAccount, bridgeFeeAmount);
        earningChainGateway.pushFundsToAccountingChain{value: bridgeFeeAmount}(
            address(USDC),
            returnAmount,
            address(ccipAdapter_earningChain),
            DEFAULT_GAS_LIMIT,
            abi.encode(
                ICcipBridgeAdapter.CcipFeeParams({
                    feeToken: Constants.NATIVE_CURRENCY, feeAmount: bridgeFeeAmount, feeRefundThreshold: 0
                })
            )
        );

        // Re-sync oracle to reflect the remaining Earning Chain balance
        _publishAndSyncOracle();

        // Local balance: 400 USDC returned to Accounting Chain allocator
        // Earning chain balance: 600 USDC remaining (via oracle)
        // Total: 1000 USDC
        assertEq(
            fundsHandler.getAggregatedBalance(),
            depositRay,
            "Total aggregated balance should still equal original deposit (local + Earning Chain)"
        );

        // Verify the Earning Chain state only reports the remaining 600 USDC
        bytes memory stateBytes = earningChainStateProvider.getState();
        IEarningChainStateProvider.State memory state = abi.decode(stateBytes, (IEarningChainStateProvider.State));
        EarningChainStateSchemaV1.BalanceSnapshot memory snapshot =
            abi.decode(state.data, (EarningChainStateSchemaV1.BalanceSnapshot));
        assertEq(snapshot.balanceRay, remainingRay, "Earning chain should report only remaining balance");
    }

    /// @notice Return funds reverts when chain balance source block number is older than the message block number.
    function test_oracleFeed_returnFunds_revertsWhenChainBalanceBlockNumberIsOlderThanMessage() public {
        uint256 depositAmount = 500 * (10 ** 6);
        uint256 depositRay = depositAmount.assetDecimalsToRay(address(USDC));

        _mintAndDepositUsdcToStableVault(user1, depositAmount);
        _bridgeUsdcToEarningChain(depositAmount);
        _publishAndSyncOracle();

        assertEq(fundsHandler.getAggregatedBalance(), depositRay, "Baseline earning chain balance should be visible");

        // Move to a new block so the message can carry a strictly newer block number than the snapshot.
        vm.roll(block.number + 1);
        // Make oracle snapshot older than the outgoing RETURN_FUNDS message block number.
        _mockChainBalance(
            EARNING_CHAIN_ID,
            earningChainGateway.getAggregatedBalance(),
            block.timestamp - 1,
            block.timestamp - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS,
            block.number - 1,
            false
        );

        // NOTE: the tx reverts from this call because the CCIP send and CCIP receive happen atomically given the test
        // harness.
        uint256 bridgeFeeAmount = 1000;
        vm.prank(everyRoleAccount);
        vm.deal(everyRoleAccount, bridgeFeeAmount);
        vm.expectRevert(
            abi.encodeWithSelector(
                MockCCIPRouter.ReceiverError.selector,
                abi.encodeWithSelector(IAccountingChainGateway.StaleChainBalance.selector)
            )
        );
        earningChainGateway.pushFundsToAccountingChain{value: bridgeFeeAmount}(
            address(USDC),
            depositAmount,
            address(ccipAdapter_earningChain),
            DEFAULT_GAS_LIMIT,
            abi.encode(
                ICcipBridgeAdapter.CcipFeeParams({
                    feeToken: Constants.NATIVE_CURRENCY, feeAmount: bridgeFeeAmount, feeRefundThreshold: 0
                })
            )
        );
    }

    /// @notice Return funds followed by a second bridge out -- verifies oracle accurately tracks
    /// multiple movements of funds between chains.
    function test_oracleFeed_returnThenReBridge() public {
        uint256 depositAmount = 800 * (10 ** 6);
        uint256 depositRay = depositAmount.assetDecimalsToRay(address(USDC));

        // Deposit, bridge to Earning Chain, sync oracle
        _mintAndDepositUsdcToStableVault(user1, depositAmount);
        _bridgeUsdcToEarningChain(depositAmount);
        _publishAndSyncOracle();
        assertEq(fundsHandler.getAggregatedBalance(), depositRay, "Baseline balance on Earning Chain");

        // Return all funds to Accounting Chain
        uint256 bridgeFeeAmount = 1000;
        vm.prank(everyRoleAccount);
        vm.deal(everyRoleAccount, bridgeFeeAmount);
        earningChainGateway.pushFundsToAccountingChain{value: bridgeFeeAmount}(
            address(USDC),
            depositAmount,
            address(ccipAdapter_earningChain),
            DEFAULT_GAS_LIMIT,
            abi.encode(
                ICcipBridgeAdapter.CcipFeeParams({
                    feeToken: Constants.NATIVE_CURRENCY, feeAmount: bridgeFeeAmount, feeRefundThreshold: 0
                })
            )
        );
        _publishAndSyncOracle();

        // All funds local now
        assertEq(fundsHandler.getAggregatedBalance(), depositRay, "All funds should be local after return");

        // Re-bridge half to Earning Chain
        uint256 reBridgeAmount = 400 * (10 ** 6);
        uint256 reBridgeRay = reBridgeAmount.assetDecimalsToRay(address(USDC));
        _bridgeUsdcToEarningChain(reBridgeAmount);
        _publishAndSyncOracle();

        // Local: 400 USDC, Earning chain: 400 USDC (via oracle), Total: 800 USDC
        assertEq(fundsHandler.getAggregatedBalance(), depositRay, "Total should remain constant after re-bridge");

        // Verify Earning Chain reports re-bridged amount
        bytes memory stateBytes = earningChainStateProvider.getState();
        IEarningChainStateProvider.State memory state = abi.decode(stateBytes, (IEarningChainStateProvider.State));
        EarningChainStateSchemaV1.BalanceSnapshot memory snapshot =
            abi.decode(state.data, (EarningChainStateSchemaV1.BalanceSnapshot));
        assertEq(snapshot.balanceRay, reBridgeRay, "Earning chain should report re-bridged amount");
    }

    // -----------------------------------------------------------------------
    // Helpers
    // -----------------------------------------------------------------------

    /// @dev Reads state from EarningChainStateProvider and publishes it to MockBundleFeed.
    /// The production path (adapter -> ChainBalanceOracle -> FundsHandler) consumes this published bundle.
    function _publishAndSyncOracle() internal {
        // 1. Read live state from Earning Chain
        bytes memory stateBytes = earningChainStateProvider.getState();

        // 2. Publish to feed on Accounting Chain
        mockBundleFeed.publishState(stateBytes);
    }

    function _mintAndDepositUsdcToStableVault(address user, uint256 amount) internal {
        USDC.mint(user, amount);
        vm.startPrank(user);
        USDC.approve(address(vault), amount);
        vault.deposit(user, address(USDC), amount, "");
        vm.stopPrank();
    }

    function _bridgeUsdcToEarningChain(uint256 amount) internal {
        uint256 bridgeFeeAmount = 1000;
        vm.prank(everyRoleAccount);
        vm.deal(everyRoleAccount, bridgeFeeAmount);
        fundsHandler.pushFundsToChain{value: bridgeFeeAmount}(
            address(USDC),
            amount,
            EARNING_CHAIN_ID,
            address(ccipAdapter_accountingChain),
            DEFAULT_GAS_LIMIT,
            abi.encode(
                ICcipBridgeAdapter.CcipFeeParams({
                    feeToken: Constants.NATIVE_CURRENCY, feeAmount: bridgeFeeAmount, feeRefundThreshold: 0
                })
            )
        );
    }

    function _staleUpdateTimestamp() internal view returns (uint256) {
        return block.timestamp - HEARTBEAT - PUBLISH_BUFFER_SECONDS;
    }

    function _warpAndRefreshPriceOracles(uint256 timeDelta) internal {
        uint256 targetTimestamp = block.timestamp + timeDelta;
        vm.warp(targetTimestamp);
        // Avoid isStale returning true and causing the adjusted balance to be 0.
        _refreshPriceFeedTimestamp(usdcPriceFeed_accountingChain, targetTimestamp);
        _refreshPriceFeedTimestamp(ghoPriceFeed_accountingChain, targetTimestamp);
        _refreshPriceFeedTimestamp(usdcPriceFeed_earningChain, targetTimestamp);
        _refreshPriceFeedTimestamp(ghoPriceFeed_earningChain, targetTimestamp);
        // Keep sequencer feeds healthy after warp (sequencer up, grace period elapsed).
        mockSequencerUptimeFeed.setAnswer(0, 0);
    }

    function _refreshPriceFeedTimestamp(MockChainlinkAggregator feed, uint256 newTimestamp) internal {
        (, int256 answer,,,) = feed.latestRoundData();
        feed.setAnswer(answer, newTimestamp);
    }
}

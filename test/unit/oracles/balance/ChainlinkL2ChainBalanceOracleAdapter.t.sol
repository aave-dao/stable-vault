// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";

import {IChainBalanceOracle} from "src/interfaces/IChainBalanceOracle.sol";
import {IChainBalanceOracleAdapter} from "src/interfaces/IChainBalanceOracleAdapter.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {ChainlinkL2ChainBalanceOracleAdapter} from "src/oracles/balance/ChainlinkL2ChainBalanceOracleAdapter.sol";

import {MockBundleAggregator} from "test/mocks/MockBundleAggregator.sol";
import {MockSequencerUptimeFeed} from "test/mocks/MockSequencerUptimeFeed.sol";

contract ChainlinkL2ChainBalanceOracleAdapterTest is Test {
    using AssetLib for uint256;

    uint256 constant CHAIN_ID = 8453;
    uint256 constant SNAPSHOT_CHAIN_ID = 1;
    uint256 constant HEARTBEAT = 3600;
    uint256 constant HEARTBEAT_BUFFER_SECONDS = 90;
    uint256 constant GRACE_PERIOD_TIME_SECONDS = 7200;

    MockBundleAggregator internal _bundleAggregator;
    MockSequencerUptimeFeed internal _sequencerFeed;
    ChainlinkL2ChainBalanceOracleAdapter internal _adapter;

    function setUp() public {
        _bundleAggregator = new MockBundleAggregator();
        _sequencerFeed = new MockSequencerUptimeFeed();

        // Default: sequencer is up (answer=0) and has been up since the beginning of time (startedAt=0).
        _sequencerFeed.setAnswer(0, 0);

        _bundleAggregator.setAnswer(1, 1000e18, block.timestamp, SNAPSHOT_CHAIN_ID);
        _adapter = new ChainlinkL2ChainBalanceOracleAdapter(
            SNAPSHOT_CHAIN_ID, address(_bundleAggregator), HEARTBEAT, address(_sequencerFeed)
        );

        // Warp forward so grace period calculations don't underflow.
        vm.warp(block.timestamp + 2 days);
    }

    function test_constructor_setsImmutables() public {
        _bundleAggregator.setAnswer(1, 5000e18, block.timestamp, SNAPSHOT_CHAIN_ID);

        IChainBalanceOracle.ChainBalance memory response = _adapter.getChainBalance(SNAPSHOT_CHAIN_ID);

        assertEq(response.balanceRay, 5000e18, "Balance should match the set value");
        assertFalse(response.isStale, "Should not be stale with fresh data and sequencer up");
    }

    function test_constructor_reverts_ifSequencerUptimeFeedIsInvalid() public {
        // Calling latestRoundData() on a non-contract address will revert.
        vm.expectRevert();
        new ChainlinkL2ChainBalanceOracleAdapter(SNAPSHOT_CHAIN_ID, address(_bundleAggregator), HEARTBEAT, address(0));
    }

    function test_getChainBalance_returnsBalance_whenSequencerUpAndGracePeriodElapsed() public {
        _sequencerFeed.setAnswer(0, block.timestamp - GRACE_PERIOD_TIME_SECONDS - 1);
        _bundleAggregator.setAnswer(1, 2000e18, block.timestamp, SNAPSHOT_CHAIN_ID);

        IChainBalanceOracle.ChainBalance memory response = _adapter.getChainBalance(SNAPSHOT_CHAIN_ID);

        assertEq(response.balanceRay, 2000e18, "Balance should be returned correctly");
        assertEq(response.lastUpdateTimestamp, block.timestamp, "Timestamp should match");
        assertFalse(response.isStale, "Should not be stale when sequencer up and grace period elapsed");
    }

    function test_getChainBalance_returnsBalance_whenSequencerUp(uint128 rawBalance) public {
        uint256 balance = uint256(rawBalance);
        _sequencerFeed.setAnswer(0, block.timestamp - GRACE_PERIOD_TIME_SECONDS - 1);
        _bundleAggregator.setAnswer(1, balance, block.timestamp, SNAPSHOT_CHAIN_ID);

        IChainBalanceOracle.ChainBalance memory response = _adapter.getChainBalance(SNAPSHOT_CHAIN_ID);

        assertEq(response.balanceRay, balance, "Balance should match the set value");
        assertFalse(response.isStale, "Should not be stale");
    }

    function test_getChainBalance_notStale_whenSequencerUpExactlyAtGracePeriod() public {
        // Sequencer came up exactly GRACE_PERIOD_TIME_SECONDS seconds ago — grace period has elapsed, so feed is safe
        // to use.
        _sequencerFeed.setAnswer(0, block.timestamp - GRACE_PERIOD_TIME_SECONDS);
        _bundleAggregator.setAnswer(1, 1e18, block.timestamp, SNAPSHOT_CHAIN_ID);

        IChainBalanceOracle.ChainBalance memory response = _adapter.getChainBalance(SNAPSHOT_CHAIN_ID);

        assertFalse(response.isStale, "Should not be stale when timeSinceUp == GRACE_PERIOD_TIME_SECONDS");
    }

    function test_getChainBalance_isStale_whenSequencerDown() public {
        // answer=1 indicates sequencer is down.
        _sequencerFeed.setAnswer(1, block.timestamp);
        _bundleAggregator.setAnswer(1, 2000e18, block.timestamp, SNAPSHOT_CHAIN_ID);

        IChainBalanceOracle.ChainBalance memory response = _adapter.getChainBalance(SNAPSHOT_CHAIN_ID);

        assertTrue(response.isStale, "Should be stale when sequencer is down");
        assertEq(response.balanceRay, 2000e18, "Balance should still be returned even when stale");
    }

    function test_getChainBalance_isStale_whenSequencerDown_withNonOneAnswer(uint256 answer) public {
        vm.assume(answer != 0);
        // Any non-zero answer should be treated as sequencer down.
        // forge-lint: disable-next-line(unsafe-typecast)
        _sequencerFeed.setAnswer(int256(answer), block.timestamp);
        _bundleAggregator.setAnswer(1, 1e18, block.timestamp, SNAPSHOT_CHAIN_ID);

        IChainBalanceOracle.ChainBalance memory response = _adapter.getChainBalance(SNAPSHOT_CHAIN_ID);

        assertTrue(response.isStale, "Should be stale when sequencer answer is non-zero");
    }

    function test_getChainBalance_isStale_whenGracePeriodNotElapsed() public {
        // Sequencer came back up 1 second ago (grace period has not elapsed).
        _sequencerFeed.setAnswer(0, block.timestamp - 1);
        _bundleAggregator.setAnswer(1, 2000e18, block.timestamp, SNAPSHOT_CHAIN_ID);

        IChainBalanceOracle.ChainBalance memory response = _adapter.getChainBalance(SNAPSHOT_CHAIN_ID);

        assertTrue(response.isStale, "Should be stale when grace period has not elapsed");
        assertEq(response.balanceRay, 2000e18, "Balance should still be returned even during grace period");
    }

    function test_getChainBalance_isStale_whenGracePeriodAlmostElapsed() public {
        // Sequencer came up GRACE_PERIOD_TIME_SECONDS - 1 seconds ago — 1 second short.
        _sequencerFeed.setAnswer(0, block.timestamp - GRACE_PERIOD_TIME_SECONDS + 1);
        _bundleAggregator.setAnswer(1, 1500e18, block.timestamp, SNAPSHOT_CHAIN_ID);

        IChainBalanceOracle.ChainBalance memory response = _adapter.getChainBalance(SNAPSHOT_CHAIN_ID);

        assertTrue(response.isStale, "Should be stale when 1 second short of grace period");
    }

    function test_getChainBalance_isStale_whenSequencerJustCameUp() public {
        // Sequencer came up at exactly block.timestamp (timeSinceUp = 0).
        _sequencerFeed.setAnswer(0, block.timestamp);
        _bundleAggregator.setAnswer(1, 1e18, block.timestamp, SNAPSHOT_CHAIN_ID);

        IChainBalanceOracle.ChainBalance memory response = _adapter.getChainBalance(SNAPSHOT_CHAIN_ID);

        assertTrue(response.isStale, "Should be stale when sequencer just came up (timeSinceUp=0)");
    }

    function test_getChainBalance_isStale_whenBothSequencerDownAndHeartbeatStale() public {
        _sequencerFeed.setAnswer(1, block.timestamp);
        uint256 staleUpdateTime = block.timestamp - (HEARTBEAT + HEARTBEAT_BUFFER_SECONDS + 1000);
        _bundleAggregator.setAnswer(1, 1e18, staleUpdateTime, SNAPSHOT_CHAIN_ID);

        IChainBalanceOracle.ChainBalance memory response = _adapter.getChainBalance(SNAPSHOT_CHAIN_ID);

        assertTrue(response.isStale, "Should be stale when both sequencer down and heartbeat stale");
    }

    function test_getChainBalance_isStale_whenHeartbeatStaleButSequencerUp() public {
        _sequencerFeed.setAnswer(0, block.timestamp - GRACE_PERIOD_TIME_SECONDS - 1);
        uint256 staleUpdateTime = block.timestamp - (HEARTBEAT + HEARTBEAT_BUFFER_SECONDS);
        _bundleAggregator.setAnswer(1, 1e18, staleUpdateTime, SNAPSHOT_CHAIN_ID);

        IChainBalanceOracle.ChainBalance memory response = _adapter.getChainBalance(SNAPSHOT_CHAIN_ID);

        assertTrue(response.isStale, "Should be stale due to heartbeat staleness even when sequencer is up");
    }

    function test_getChainBalance_notStale_whenSequencerUpAndHeartbeatFresh() public {
        _sequencerFeed.setAnswer(0, block.timestamp - GRACE_PERIOD_TIME_SECONDS - 1);
        _bundleAggregator.setAnswer(1, 1e18, block.timestamp, SNAPSHOT_CHAIN_ID);

        IChainBalanceOracle.ChainBalance memory response = _adapter.getChainBalance(SNAPSHOT_CHAIN_ID);

        assertFalse(response.isStale, "Should not be stale when both sequencer up and heartbeat fresh");
    }

    function test_getChainBalance_reverts_ifChainIdDoesNotMatch(uint256 wrongChainId) public {
        vm.assume(wrongChainId != SNAPSHOT_CHAIN_ID);

        vm.expectRevert(abi.encodeWithSelector(IChainBalanceOracleAdapter.InvalidChainId.selector, wrongChainId));
        _adapter.getChainBalance(wrongChainId);
    }

    function test_getChainBalance_doesNotRevert_ifBalanceIsZero() public {
        _sequencerFeed.setAnswer(0, block.timestamp - GRACE_PERIOD_TIME_SECONDS - 1);
        _bundleAggregator.setAnswer(1, 0, block.timestamp, SNAPSHOT_CHAIN_ID);

        IChainBalanceOracle.ChainBalance memory response = _adapter.getChainBalance(SNAPSHOT_CHAIN_ID);

        assertEq(response.balanceRay, 0, "Zero balance should return 0 without reverting");
    }

    function test_getChainBalance_reverts_ifVersionDoesNotMatch() public {
        _bundleAggregator.setAnswer(2, 1e18, block.timestamp, SNAPSHOT_CHAIN_ID);

        vm.expectRevert(
            abi.encodeWithSelector(IChainBalanceOracleAdapter.InvalidEarningChainStateVersion.selector, 1, 2)
        );
        _adapter.getChainBalance(SNAPSHOT_CHAIN_ID);
    }

    function test_getChainBalance_reverts_ifSnapshotChainIdDoesNotMatch() public {
        _bundleAggregator.setAnswer(1, 1e18, block.timestamp, 2);

        vm.expectRevert(
            abi.encodeWithSelector(IChainBalanceOracleAdapter.InvalidSnapshotChainId.selector, SNAPSHOT_CHAIN_ID, 2)
        );
        _adapter.getChainBalance(SNAPSHOT_CHAIN_ID);
    }

    function test_getChainBalance_sequencer(uint128 rawBalance, uint256 timeSinceSequencerUp, bool sequencerDown)
        public
    {
        timeSinceSequencerUp = bound(timeSinceSequencerUp, 0, 365 days);
        vm.warp(block.timestamp + 365 days);

        uint256 balance = uint256(rawBalance);
        _bundleAggregator.setAnswer(1, balance, block.timestamp, SNAPSHOT_CHAIN_ID);

        int256 sequencerAnswer = sequencerDown ? int256(1) : int256(0);
        uint256 sequencerStartedAt = block.timestamp - timeSinceSequencerUp;
        _sequencerFeed.setAnswer(sequencerAnswer, sequencerStartedAt);

        IChainBalanceOracle.ChainBalance memory response = _adapter.getChainBalance(SNAPSHOT_CHAIN_ID);

        assertEq(response.balanceRay, balance, "Fuzz: balance should match");

        bool expectedStale = sequencerDown || timeSinceSequencerUp < GRACE_PERIOD_TIME_SECONDS;
        assertEq(response.isStale, expectedStale, "Fuzz: staleness should match expected sequencer state");
    }

    function test_getChainBalance_combinedStaleness(uint128 rawBalance, uint256 timeDelta, uint256 timeSinceSequencerUp)
        public
    {
        timeDelta = bound(timeDelta, 0, 365 days);
        timeSinceSequencerUp = bound(timeSinceSequencerUp, GRACE_PERIOD_TIME_SECONDS, 365 days);
        vm.warp(block.timestamp + 365 days);

        uint256 balance = uint256(rawBalance);
        uint256 updateTime = block.timestamp - timeDelta;
        _bundleAggregator.setAnswer(1, balance, updateTime, SNAPSHOT_CHAIN_ID);

        // Sequencer is up and grace period has elapsed.
        _sequencerFeed.setAnswer(0, block.timestamp - timeSinceSequencerUp);

        IChainBalanceOracle.ChainBalance memory response = _adapter.getChainBalance(SNAPSHOT_CHAIN_ID);

        // Staleness should only come from heartbeat when sequencer is healthy.
        bool expectedStale =
            updateTime < block.timestamp && block.timestamp - updateTime >= HEARTBEAT + HEARTBEAT_BUFFER_SECONDS;
        assertEq(response.isStale, expectedStale, "Fuzz: staleness should match heartbeat staleness only");
    }
}

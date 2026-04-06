// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";

import {IPriceOracleAdapter} from "src/interfaces/IPriceOracleAdapter.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {ChainlinkL2PriceOracleAdapter} from "src/oracles/price/ChainlinkL2PriceOracleAdapter.sol";
import {Constants} from "src/types/Constants.sol";
import {Errors} from "src/types/Errors.sol";

import {MockChainlinkAggregator} from "test/mocks/MockChainlinkAggregator.sol";
import {MockSequencerUptimeFeed} from "test/mocks/MockSequencerUptimeFeed.sol";

contract ChainlinkL2PriceOracleAdapterTest is Test {
    using AssetLib for uint256;

    address constant ASSET = address(0xA55E7);
    uint256 constant HEARTBEAT = 3600;
    uint256 constant HEARTBEAT_BUFFER_SECONDS = 90;
    uint256 constant GRACE_PERIOD_TIME_SECONDS = 7200;
    uint8 constant DECIMALS = 8;

    MockChainlinkAggregator internal _aggregator;
    MockSequencerUptimeFeed internal _sequencerFeed;
    ChainlinkL2PriceOracleAdapter internal _adapter;

    function setUp() public {
        _aggregator = new MockChainlinkAggregator(DECIMALS);
        _sequencerFeed = new MockSequencerUptimeFeed();

        // Default: sequencer is up (answer=0) and has been up since the beginning of time (startedAt=0).
        _sequencerFeed.setAnswer(0, 0);

        _adapter = new ChainlinkL2PriceOracleAdapter(ASSET, address(_aggregator), HEARTBEAT, address(_sequencerFeed));

        // Warp forward so grace period calculations don't underflow.
        vm.warp(block.timestamp + 2 days);
    }

    function test_constructor_setsImmutables() public {
        int256 price = 1e8;
        _aggregator.setAnswer(price, block.timestamp);

        IPriceOracleAdapter.OracleResponse memory response = _adapter.getPrice(ASSET);

        assertEq(response.priceRay, 1e27, "Price should be 1e27 in RAY");
        assertFalse(response.isStale, "Should not be stale with fresh data and sequencer up");
    }

    function test_constructor_reverts_ifSequencerUptimeFeedIsInvalid() public {
        // Calling latestRoundData() on a non-contract address will revert.
        vm.expectRevert();
        new ChainlinkL2PriceOracleAdapter(ASSET, address(_aggregator), HEARTBEAT, address(0));
    }

    function test_getPrice_returnsPrice_whenSequencerUpAndGracePeriodElapsed() public {
        // Sequencer has been up since well before the grace period.
        _sequencerFeed.setAnswer(0, block.timestamp - GRACE_PERIOD_TIME_SECONDS - 1);
        _aggregator.setAnswer(2000e8, block.timestamp);

        IPriceOracleAdapter.OracleResponse memory response = _adapter.getPrice(ASSET);

        assertEq(response.priceRay, 2000e27, "Price should be 2000e27 in RAY");
        assertFalse(response.isStale, "Should not be stale when sequencer up and grace period elapsed");
    }

    function test_getPrice_returnsPriceInRay_whenSequencerUp(uint256 price) public {
        // Provide enough room for the price to be converted to RAY without overflowing.
        price = price / 10 ** (Constants.RAY_DECIMALS - DECIMALS);
        // forge-lint: disable-next-line(unsafe-typecast)
        _aggregator.setAnswer(int256(price), block.timestamp);
        _sequencerFeed.setAnswer(0, block.timestamp - GRACE_PERIOD_TIME_SECONDS - 1);

        IPriceOracleAdapter.OracleResponse memory response = _adapter.getPrice(ASSET);

        assertEq(
            response.priceRay,
            price.convertDecimals(DECIMALS, Constants.RAY_DECIMALS),
            "Price should be converted from 8 to 27 decimals"
        );
        assertFalse(response.isStale, "Should not be stale");
    }

    function test_getPrice_notStale_whenSequencerUpExactlyAtGracePeriod() public {
        // Sequencer came up exactly GRACE_PERIOD_TIME_SECONDS seconds ago — grace period has elapsed.
        _sequencerFeed.setAnswer(0, block.timestamp - GRACE_PERIOD_TIME_SECONDS);
        _aggregator.setAnswer(1e8, block.timestamp);

        IPriceOracleAdapter.OracleResponse memory response = _adapter.getPrice(ASSET);

        assertFalse(response.isStale, "Should not be stale when timeSinceUp == GRACE_PERIOD_TIME_SECONDS");
    }

    function test_getPrice_isStale_whenSequencerDown() public {
        // answer=1 indicates sequencer is down.
        _sequencerFeed.setAnswer(1, block.timestamp);
        _aggregator.setAnswer(2000e8, block.timestamp);

        IPriceOracleAdapter.OracleResponse memory response = _adapter.getPrice(ASSET);

        assertTrue(response.isStale, "Should be stale when sequencer is down");
        assertEq(response.priceRay, 2000e27, "Price should still be returned even when stale");
    }

    function test_getPrice_isStale_whenSequencerDown_withNonOneAnswer(uint256 answer) public {
        vm.assume(answer != 0);
        // Any non-zero answer should be treated as sequencer down.
        // forge-lint: disable-next-line(unsafe-typecast)
        _sequencerFeed.setAnswer(int256(answer), block.timestamp);
        _aggregator.setAnswer(1e8, block.timestamp);

        IPriceOracleAdapter.OracleResponse memory response = _adapter.getPrice(ASSET);

        assertTrue(response.isStale, "Should be stale when sequencer answer is non-zero");
    }

    function test_getPrice_isStale_whenGracePeriodNotElapsed() public {
        // Sequencer came back up 1 second ago (grace period has not elapsed).
        _sequencerFeed.setAnswer(0, block.timestamp - 1);
        _aggregator.setAnswer(2000e8, block.timestamp);

        IPriceOracleAdapter.OracleResponse memory response = _adapter.getPrice(ASSET);

        assertTrue(response.isStale, "Should be stale when grace period has not elapsed");
        assertEq(response.priceRay, 2000e27, "Price should still be returned even during grace period");
    }

    function test_getPrice_isStale_whenGracePeriodAlmostElapsed() public {
        // Sequencer came up GRACE_PERIOD_TIME_SECONDS - 1 seconds ago — 1 second short of grace period.
        _sequencerFeed.setAnswer(0, block.timestamp - GRACE_PERIOD_TIME_SECONDS + 1);
        _aggregator.setAnswer(1500e8, block.timestamp);

        IPriceOracleAdapter.OracleResponse memory response = _adapter.getPrice(ASSET);

        assertTrue(response.isStale, "Should be stale when 1 second short of grace period");
    }

    function test_getPrice_isStale_whenSequencerJustCameUp() public {
        // Sequencer came up at exactly block.timestamp (timeSinceUp = 0).
        _sequencerFeed.setAnswer(0, block.timestamp);
        _aggregator.setAnswer(1e8, block.timestamp);

        IPriceOracleAdapter.OracleResponse memory response = _adapter.getPrice(ASSET);

        assertTrue(response.isStale, "Should be stale when sequencer just came up (timeSinceUp=0)");
    }

    function test_getPrice_isStale_whenBothSequencerDownAndHeartbeatStale() public {
        // Both conditions: sequencer down AND heartbeat stale.
        _sequencerFeed.setAnswer(1, block.timestamp);
        uint256 staleUpdateTime = block.timestamp - (HEARTBEAT + HEARTBEAT_BUFFER_SECONDS + 1000);
        _aggregator.setAnswer(1e8, staleUpdateTime);

        IPriceOracleAdapter.OracleResponse memory response = _adapter.getPrice(ASSET);

        assertTrue(response.isStale, "Should be stale when both sequencer down and heartbeat stale");
    }

    function test_getPrice_isStale_whenHeartbeatStaleButSequencerUp() public {
        // Sequencer is fine, but price feed is stale by heartbeat.
        _sequencerFeed.setAnswer(0, block.timestamp - GRACE_PERIOD_TIME_SECONDS - 1);
        uint256 staleUpdateTime = block.timestamp - (HEARTBEAT + HEARTBEAT_BUFFER_SECONDS);
        _aggregator.setAnswer(1e8, staleUpdateTime);

        IPriceOracleAdapter.OracleResponse memory response = _adapter.getPrice(ASSET);

        assertTrue(response.isStale, "Should be stale due to heartbeat staleness even when sequencer is up");
    }

    function test_getPrice_notStale_whenSequencerUpAndHeartbeatFresh() public {
        // Both conditions are good: sequencer up with grace period elapsed, and price is fresh.
        _sequencerFeed.setAnswer(0, block.timestamp - GRACE_PERIOD_TIME_SECONDS - 1);
        _aggregator.setAnswer(1e8, block.timestamp);

        IPriceOracleAdapter.OracleResponse memory response = _adapter.getPrice(ASSET);

        assertFalse(response.isStale, "Should not be stale when both sequencer up and heartbeat fresh");
    }

    function test_getPrice_reverts_ifAssetDoesNotMatch(address wrongAsset) public {
        vm.assume(wrongAsset != ASSET);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAsset.selector, wrongAsset));
        _adapter.getPrice(wrongAsset);
    }

    function test_getPrice_returnsZero_forNegativePrice() public {
        _sequencerFeed.setAnswer(0, block.timestamp - GRACE_PERIOD_TIME_SECONDS - 1);
        _aggregator.setAnswer(-1, block.timestamp);

        IPriceOracleAdapter.OracleResponse memory response = _adapter.getPrice(ASSET);

        assertEq(response.priceRay, 0, "Negative price should return 0");
    }

    function test_getPrice_doesNotRevert_ifPriceIsZero() public {
        _sequencerFeed.setAnswer(0, block.timestamp - GRACE_PERIOD_TIME_SECONDS - 1);
        _aggregator.setAnswer(0, block.timestamp);

        IPriceOracleAdapter.OracleResponse memory response = _adapter.getPrice(ASSET);

        assertEq(response.priceRay, 0, "Zero price should return 0 without reverting");
    }

    function test_getPrice_sequencer(uint128 rawPrice, uint256 timeSinceSequencerUp, bool sequencerDown) public {
        vm.assume(rawPrice > 0);
        timeSinceSequencerUp = bound(timeSinceSequencerUp, 0, 365 days);
        vm.warp(block.timestamp + 365 days);

        int256 price = int256(uint256(rawPrice));
        _aggregator.setAnswer(price, block.timestamp);

        int256 sequencerAnswer = sequencerDown ? int256(1) : int256(0);
        uint256 sequencerStartedAt = block.timestamp - timeSinceSequencerUp;
        _sequencerFeed.setAnswer(sequencerAnswer, sequencerStartedAt);

        IPriceOracleAdapter.OracleResponse memory response = _adapter.getPrice(ASSET);

        uint256 expectedRay = uint256(rawPrice) * 1e19;
        assertEq(response.priceRay, expectedRay, "Fuzz: price should convert to RAY correctly");

        bool expectedStale = sequencerDown || timeSinceSequencerUp < GRACE_PERIOD_TIME_SECONDS;
        assertEq(response.isStale, expectedStale, "Fuzz: staleness should match expected sequencer state");
    }

    function test_getPrice_combinedStaleness(uint128 rawPrice, uint256 timeDelta, uint256 timeSinceSequencerUp) public {
        vm.assume(rawPrice > 0);
        timeDelta = bound(timeDelta, 0, 365 days);
        timeSinceSequencerUp = bound(timeSinceSequencerUp, GRACE_PERIOD_TIME_SECONDS, 365 days);
        vm.warp(block.timestamp + 365 days);

        int256 price = int256(uint256(rawPrice));
        uint256 updateTime = block.timestamp - timeDelta;
        _aggregator.setAnswer(price, updateTime);

        // Sequencer is up and grace period has elapsed.
        _sequencerFeed.setAnswer(0, block.timestamp - timeSinceSequencerUp);

        IPriceOracleAdapter.OracleResponse memory response = _adapter.getPrice(ASSET);

        // Staleness should only come from heartbeat when sequencer is healthy.
        bool expectedStale =
            updateTime < block.timestamp && block.timestamp - updateTime >= HEARTBEAT + HEARTBEAT_BUFFER_SECONDS;
        assertEq(response.isStale, expectedStale, "Fuzz: staleness should match heartbeat staleness only");
    }
}

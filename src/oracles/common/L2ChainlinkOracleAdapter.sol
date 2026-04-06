// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

// solhint-disable-next-line interface-starts-with-i
interface AggregatorV3Interface {
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title L2ChainlinkOracleAdapter
/// @author Aave Labs
/// @notice Adapter for fetching data from a Chainlink L2 oracle.
/// @dev When an L2 sequencer goes offline, Chainlink feeds stop receiving updates and the last reported data
/// becomes frozen. However, on optimistic rollups (Arbitrum, Optimism, Base) users can still force-include transactions
/// via the L1 delayed inbox, bypassing the sequencer. This creates an exploit window: the heartbeat-based staleness
/// check may still pass because `block.timestamp` on the L2 can also stall or advance slowly during the outage,
/// making the frozen data appear fresh. An attacker can exploit this by executing transactions against stale data.
///
/// This adapter mitigates the attack by querying the Chainlink L2 Sequencer Uptime Feed, which is updated from the L1
/// inbox and accurately reflects sequencer status regardless of L2 block production. If the sequencer is down
/// (`sequencerStatus != 0`), the response is marked as stale. Additionally, a configurable grace period is enforced
/// after the sequencer spins back up, giving oracle nodes time to push fresh data before the data is trusted again.
abstract contract L2ChainlinkOracleAdapter {
    enum SequencerUptime {
        UP,
        DOWN
    }

    address immutable SEQUENCER_UPTIME_FEED;

    /// @dev The grace period (in seconds) to wait after the sequencer comes back up before trusting feed data.
    uint256 private constant GRACE_PERIOD_TIME_SECONDS = 7200;

    /// @dev Constructor.
    /// @param sequencerUptimeFeed The Chainlink L2 Sequencer Uptime Feed address.
    constructor(address sequencerUptimeFeed) {
        AggregatorV3Interface(sequencerUptimeFeed).latestRoundData();
        SEQUENCER_UPTIME_FEED = sequencerUptimeFeed;
    }

    /// @dev Returns the sequencer uptime data.
    /// @return sequencerUptime The sequencer uptime status.
    /// @return uptimeElapsedGracePeriod Whether the grace recovery period has elapsed since the sequencer came back up.
    function _getSequencerUptimeData() internal view returns (SequencerUptime, bool) {
        (, int256 sequencerStatus, uint256 startedAt,,) = AggregatorV3Interface(SEQUENCER_UPTIME_FEED).latestRoundData();
        // Ensure the grace period has elapsed since the sequencer came back up.
        uint256 timeSinceUp = block.timestamp > startedAt ? block.timestamp - startedAt : 0;
        bool uptimeElapsedGracePeriod = timeSinceUp >= GRACE_PERIOD_TIME_SECONDS;
        return (sequencerStatus == 0 ? SequencerUptime.UP : SequencerUptime.DOWN, uptimeElapsedGracePeriod);
    }

    /// @dev Checks the uptime feed to determine if the feed is healthy.
    /// @dev If the feed is unhealthy on the L2, it should be handled carefully to avoid operating on stale data.
    /// @return true if the feed is healthy, false otherwise.
    function _isFeedHealthy() internal view returns (bool) {
        (SequencerUptime sequencerUptime, bool uptimeElapsedGracePeriod) = _getSequencerUptimeData();
        return sequencerUptime == SequencerUptime.UP && uptimeElapsedGracePeriod;
    }
}

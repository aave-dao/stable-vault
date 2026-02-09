// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IChainBalanceOracleAdapter} from "src/interfaces/IChainBalanceOracleAdapter.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {Constants} from "src/types/Constants.sol";

// solhint-disable-next-line interface-starts-with-i
interface AggregatorV3Interface {
    function decimals() external view returns (uint8);

    function description() external view returns (string memory);

    function version() external view returns (uint256);

    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title ChainlinkChainBalanceOracleAdapter
/// @author Aave Labs
/// @notice Adapter for fetching a chain aggregated balance value from the Chainlink Aggregator.
contract ChainlinkChainBalanceOracleAdapter is IChainBalanceOracleAdapter {
    using AssetLib for uint256;

    /// @dev Added to the heartbeat to account for potential publishing delays during periods of network congestion.
    uint256 constant HEARTBEAT_BUFFER_SECONDS = 90;

    uint256 immutable CHAIN_ID;
    address immutable DATA_FEED;
    uint256 immutable DECIMALS;
    uint256 immutable HEARTBEAT;

    constructor(uint256 chainId, address dataFeed, uint256 heartbeat) {
        CHAIN_ID = chainId;
        DATA_FEED = dataFeed;
        DECIMALS = AggregatorV3Interface(dataFeed).decimals();
        HEARTBEAT = heartbeat;
    }

    /// @inheritdoc IChainBalanceOracleAdapter
    function getChainBalance(uint256 chainId)
        external
        view
        override
        returns (IChainBalanceOracleAdapter.OracleResponse memory)
    {
        require(chainId == CHAIN_ID, InvalidChainId(chainId));
        (, int256 balance,, uint256 updatedAt,) = AggregatorV3Interface(DATA_FEED).latestRoundData();
        uint256 balanceRay = _convertDecimalsToRay(balance);
        bool isStale = false;
        if (updatedAt < block.timestamp && block.timestamp - updatedAt >= HEARTBEAT + HEARTBEAT_BUFFER_SECONDS) {
            isStale = true;
        }
        return IChainBalanceOracleAdapter.OracleResponse({
            balanceRay: balanceRay, lastUpdateTimestamp: updatedAt, isStale: isStale
        });
    }

    /// @dev Chainlink feeds support up to 18 decimals. Because balances on an Earning Chain are normalized to RAY, we
    /// need to convert the decimals to 27. This will slightly cause an under-estimation of the balance on the Earning
    /// Chain which is acceptable.
    function _convertDecimalsToRay(int256 balance) internal view returns (uint256) {
        if (balance <= 0) {
            // Return 0 to avoid disrupting any aggregation that may take place at a higher level.
            return 0;
        }
        // Casting to 'uint256' is safe because we checked that balance > 0.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(balance).convertDecimals(DECIMALS, Constants.RAY_DECIMALS);
    }
}

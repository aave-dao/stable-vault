// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";

import {IChainBalanceOracle} from "src/interfaces/IChainBalanceOracle.sol";
import {IChainBalanceOracleAdapter} from "src/interfaces/IChainBalanceOracleAdapter.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {ChainlinkChainBalanceOracleAdapter} from "src/oracles/balance/ChainlinkChainBalanceOracleAdapter.sol";
import {MockBundleAggregator} from "test/mocks/MockBundleAggregator.sol";

contract ChainlinkChainBalanceOracleAdapterTest is Test {
    using AssetLib for uint256;

    uint256 constant CHAIN_ID = 8453;
    uint256 constant SNAPSHOT_CHAIN_ID = 1;
    uint256 constant HEARTBEAT = 3600; // 1 hour
    uint256 constant HEARTBEAT_BUFFER_SECONDS = 90;

    MockBundleAggregator internal _bundleAggregator;
    ChainlinkChainBalanceOracleAdapter internal _adapter;

    function setUp() public {
        _bundleAggregator = new MockBundleAggregator();
        _bundleAggregator.setAnswer(1, 1000e18, block.timestamp, SNAPSHOT_CHAIN_ID);
        _adapter = new ChainlinkChainBalanceOracleAdapter(SNAPSHOT_CHAIN_ID, address(_bundleAggregator), HEARTBEAT);
        // Warp to a reasonable timestamp to avoid underflow.
        vm.warp(block.timestamp + 1 days);
    }

    function test_constructor_setsImmutables() public view {
        IChainBalanceOracle.ChainBalance memory response = _adapter.getChainBalance(SNAPSHOT_CHAIN_ID);
        // Verify the adapter works with the correct chain id
        assertEq(response.balanceRay, 1000e18);
    }

    function test_getChainBalance_returnsBalanceInRay(uint256 balance) public {
        _bundleAggregator.setAnswer(1, balance, block.timestamp, SNAPSHOT_CHAIN_ID);
        IChainBalanceOracle.ChainBalance memory response = _adapter.getChainBalance(SNAPSHOT_CHAIN_ID);
        assertEq(response.balanceRay, balance);
        assertEq(response.lastUpdateTimestamp, block.timestamp);
        assertFalse(response.isStale);
    }

    function test_getChainBalance_returnsCorrectTimestamp() public {
        vm.warp(block.timestamp + 1 days);
        uint256 updateTime = block.timestamp - 100;
        _bundleAggregator.setAnswer(1, 1e18, updateTime, SNAPSHOT_CHAIN_ID);
        IChainBalanceOracle.ChainBalance memory response = _adapter.getChainBalance(SNAPSHOT_CHAIN_ID);
        assertEq(response.lastUpdateTimestamp, updateTime);
    }

    function test_getChainBalance_notStale_whenWithinHeartbeatPlusBuffer() public {
        vm.warp(block.timestamp + 1 days);
        // Set updatedAt to just within the heartbeat + buffer threshold
        uint256 updateTime = block.timestamp - (HEARTBEAT + HEARTBEAT_BUFFER_SECONDS - 1);
        _bundleAggregator.setAnswer(1, 1e18, updateTime, SNAPSHOT_CHAIN_ID);
        IChainBalanceOracle.ChainBalance memory response = _adapter.getChainBalance(SNAPSHOT_CHAIN_ID);
        assertFalse(response.isStale, "Should not be stale when within heartbeat + buffer");
    }

    function test_getChainBalance_stale_whenExactlyAtHeartbeatPlusBuffer() public {
        vm.warp(block.timestamp + 1 days);
        uint256 updateTime = block.timestamp - (HEARTBEAT + HEARTBEAT_BUFFER_SECONDS);
        _bundleAggregator.setAnswer(1, 1e18, updateTime, SNAPSHOT_CHAIN_ID);
        IChainBalanceOracle.ChainBalance memory response = _adapter.getChainBalance(SNAPSHOT_CHAIN_ID);
        assertTrue(response.isStale, "Should be stale when exactly at heartbeat + buffer");
    }

    function test_getChainBalance_stale_whenBeyondHeartbeatPlusBuffer() public {
        vm.warp(block.timestamp + 1 days);
        uint256 updateTime = block.timestamp - (HEARTBEAT + HEARTBEAT_BUFFER_SECONDS + 1000);
        _bundleAggregator.setAnswer(1, 1e18, updateTime, SNAPSHOT_CHAIN_ID);

        IChainBalanceOracle.ChainBalance memory response = _adapter.getChainBalance(SNAPSHOT_CHAIN_ID);

        assertTrue(response.isStale, "Should be stale when beyond heartbeat + buffer");
    }

    function test_getChainBalance_notStale_whenUpdatedAtEqualsBlockTimestamp() public {
        _bundleAggregator.setAnswer(1, 1e18, block.timestamp, SNAPSHOT_CHAIN_ID);

        IChainBalanceOracle.ChainBalance memory response = _adapter.getChainBalance(SNAPSHOT_CHAIN_ID);

        assertFalse(response.isStale, "Should not be stale when updatedAt == block.timestamp");
    }

    function test_getChainBalance_notStale_whenUpdatedAtIsInTheFuture() public {
        // Handle case where the update time is in the future due to clock skew.
        _bundleAggregator.setAnswer(1, 1e18, block.timestamp + 100, SNAPSHOT_CHAIN_ID);
        IChainBalanceOracle.ChainBalance memory response = _adapter.getChainBalance(SNAPSHOT_CHAIN_ID);
        assertFalse(response.isStale, "Should not be stale when updatedAt > block.timestamp");
    }

    function test_getChainBalance_reverts_ifChainIdDoesNotMatch(uint256 wrongChainId) public {
        vm.assume(wrongChainId != SNAPSHOT_CHAIN_ID);
        vm.expectRevert(abi.encodeWithSelector(IChainBalanceOracleAdapter.InvalidChainId.selector, wrongChainId));
        _adapter.getChainBalance(wrongChainId);
    }

    function test_getChainBalance_doesNotRevert_ifBalanceIsZero() public {
        _bundleAggregator.setAnswer(1, 0, block.timestamp, SNAPSHOT_CHAIN_ID);
        IChainBalanceOracle.ChainBalance memory response = _adapter.getChainBalance(SNAPSHOT_CHAIN_ID);
        assertEq(response.balanceRay, 0);
    }

    function test_getChainBalance_convertsSmallBalance() public {
        // 1 unit in 27 decimals
        _bundleAggregator.setAnswer(1, 1, block.timestamp, SNAPSHOT_CHAIN_ID);
        IChainBalanceOracle.ChainBalance memory response = _adapter.getChainBalance(SNAPSHOT_CHAIN_ID);
        assertEq(response.balanceRay, 1);
    }

    function test_getChainBalance_fuzz(uint128 rawBalance) public {
        uint256 balance = uint256(rawBalance);
        _bundleAggregator.setAnswer(1, balance, block.timestamp, SNAPSHOT_CHAIN_ID);
        IChainBalanceOracle.ChainBalance memory response = _adapter.getChainBalance(SNAPSHOT_CHAIN_ID);
        assertEq(response.balanceRay, balance);
    }

    function test_getChainBalance_staleness_fuzz(uint128 rawBalance, uint256 timeDelta) public {
        timeDelta = bound(timeDelta, 0, 365 days);
        vm.warp(block.timestamp + 365 days);

        uint256 balance = uint256(rawBalance);
        uint256 updateTime = block.timestamp - timeDelta;
        _bundleAggregator.setAnswer(1, balance, updateTime, SNAPSHOT_CHAIN_ID);
        IChainBalanceOracle.ChainBalance memory response = _adapter.getChainBalance(SNAPSHOT_CHAIN_ID);
        assertEq(
            response.isStale,
            updateTime < block.timestamp && block.timestamp - updateTime >= HEARTBEAT + HEARTBEAT_BUFFER_SECONDS
        );
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
}

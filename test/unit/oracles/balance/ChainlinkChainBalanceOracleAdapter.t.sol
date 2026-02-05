// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";

import {IChainBalanceOracleAdapter} from "src/interfaces/IChainBalanceOracleAdapter.sol";
import {ChainlinkChainBalanceOracleAdapter} from "src/oracles/balance/ChainlinkChainBalanceOracleAdapter.sol";

import {MockChainlinkAggregator} from "test/mocks/MockChainlinkAggregator.sol";

contract ChainlinkChainBalanceOracleAdapterTest is Test {
    uint256 constant CHAIN_ID = 8453;
    uint256 constant HEARTBEAT = 3600; // 1 hour
    uint256 constant HEARTBEAT_BUFFER_SECONDS = 90;
    uint8 constant DECIMALS = 18;
    uint8 constant RAY_DECIMALS = 27;

    MockChainlinkAggregator internal _aggregator;
    ChainlinkChainBalanceOracleAdapter internal _adapter;

    function setUp() public {
        _aggregator = new MockChainlinkAggregator(DECIMALS);
        _aggregator.setAnswer(1000e18, block.timestamp);
        _adapter = new ChainlinkChainBalanceOracleAdapter(CHAIN_ID, address(_aggregator), HEARTBEAT);
    }

    function test_constructor_setsImmutables() public view {
        IChainBalanceOracleAdapter.OracleResponse memory response = _adapter.getChainBalance(CHAIN_ID);
        // Verify the adapter works with the correct chain id
        assertEq(response.balanceRay, 1000e27);
    }

    function test_getChainBalance_returnsBalanceInRay() public {
        int256 balance = 500e18;
        _aggregator.setAnswer(balance, block.timestamp);

        IChainBalanceOracleAdapter.OracleResponse memory response = _adapter.getChainBalance(CHAIN_ID);

        assertEq(response.balanceRay, 500e27, "Balance should be converted from 18 to 27 decimals");
        assertEq(response.lastUpdateTimestamp, block.timestamp);
        assertFalse(response.isStale);
    }

    function test_getChainBalance_returnsCorrectTimestamp() public {
        vm.warp(block.timestamp + 1 days);
        uint256 updateTime = block.timestamp - 100;
        _aggregator.setAnswer(1e18, updateTime);

        IChainBalanceOracleAdapter.OracleResponse memory response = _adapter.getChainBalance(CHAIN_ID);

        assertEq(response.lastUpdateTimestamp, updateTime);
    }

    function test_getChainBalance_notStale_whenWithinHeartbeatPlusBuffer() public {
        vm.warp(block.timestamp + 1 days);
        // Set updatedAt to just within the heartbeat + buffer threshold
        uint256 updateTime = block.timestamp - (HEARTBEAT + HEARTBEAT_BUFFER_SECONDS - 1);
        _aggregator.setAnswer(1e18, updateTime);

        IChainBalanceOracleAdapter.OracleResponse memory response = _adapter.getChainBalance(CHAIN_ID);

        assertFalse(response.isStale, "Should not be stale when within heartbeat + buffer");
    }

    function test_getChainBalance_stale_whenExactlyAtHeartbeatPlusBuffer() public {
        vm.warp(block.timestamp + 1 days);
        uint256 updateTime = block.timestamp - (HEARTBEAT + HEARTBEAT_BUFFER_SECONDS);
        _aggregator.setAnswer(1e18, updateTime);

        IChainBalanceOracleAdapter.OracleResponse memory response = _adapter.getChainBalance(CHAIN_ID);

        assertTrue(response.isStale, "Should be stale when exactly at heartbeat + buffer");
    }

    function test_getChainBalance_stale_whenBeyondHeartbeatPlusBuffer() public {
        vm.warp(block.timestamp + 1 days);
        uint256 updateTime = block.timestamp - (HEARTBEAT + HEARTBEAT_BUFFER_SECONDS + 1000);
        _aggregator.setAnswer(1e18, updateTime);

        IChainBalanceOracleAdapter.OracleResponse memory response = _adapter.getChainBalance(CHAIN_ID);

        assertTrue(response.isStale, "Should be stale when beyond heartbeat + buffer");
    }

    function test_getChainBalance_notStale_whenUpdatedAtEqualsBlockTimestamp() public {
        _aggregator.setAnswer(1e18, block.timestamp);

        IChainBalanceOracleAdapter.OracleResponse memory response = _adapter.getChainBalance(CHAIN_ID);

        assertFalse(response.isStale, "Should not be stale when updatedAt == block.timestamp");
    }

    function test_getChainBalance_notStale_whenUpdatedAtIsInTheFuture() public {
        _aggregator.setAnswer(1e18, block.timestamp + 100);

        IChainBalanceOracleAdapter.OracleResponse memory response = _adapter.getChainBalance(CHAIN_ID);

        assertFalse(response.isStale, "Should not be stale when updatedAt > block.timestamp");
    }

    function test_getChainBalance_reverts_ifChainIdDoesNotMatch(uint256 wrongChainId) public {
        vm.assume(wrongChainId != CHAIN_ID);

        vm.expectRevert(abi.encodeWithSelector(IChainBalanceOracleAdapter.InvalidChainId.selector, wrongChainId));
        _adapter.getChainBalance(wrongChainId);
    }

    function test_getChainBalance_doesNotRevert_ifBalanceIsZero() public {
        _aggregator.setAnswer(0, block.timestamp);

        IChainBalanceOracleAdapter.OracleResponse memory response = _adapter.getChainBalance(CHAIN_ID);

        assertEq(response.balanceRay, 0);
    }

    function test_getChainBalance_convertsSmallBalance() public {
        // 1 wei in 18 decimals
        _aggregator.setAnswer(1, block.timestamp);

        IChainBalanceOracleAdapter.OracleResponse memory response = _adapter.getChainBalance(CHAIN_ID);

        // 1 * 10^(27-18) = 1e9
        assertEq(response.balanceRay, 1e9, "1 unit at 18 decimals should be 1e9 in RAY");
    }

    function test_getChainBalance_convertsLargeBalance() public {
        // 1 billion tokens in 18 decimals
        int256 balance = 1_000_000_000e18;
        _aggregator.setAnswer(balance, block.timestamp);

        IChainBalanceOracleAdapter.OracleResponse memory response = _adapter.getChainBalance(CHAIN_ID);

        assertEq(response.balanceRay, 1_000_000_000e27, "Large balance should scale correctly");
    }

    function test_getChainBalance_fuzz(uint128 rawBalance) public {
        vm.assume(rawBalance > 0);
        int256 balance = int256(uint256(rawBalance));
        _aggregator.setAnswer(balance, block.timestamp);

        IChainBalanceOracleAdapter.OracleResponse memory response = _adapter.getChainBalance(CHAIN_ID);

        uint256 expectedRay = uint256(rawBalance) * 1e9;
        assertEq(response.balanceRay, expectedRay, "Fuzz: balance should convert to RAY correctly");
    }

    function test_getChainBalance_staleness_fuzz(uint128 rawBalance, uint256 timeDelta) public {
        vm.assume(rawBalance > 0);
        timeDelta = bound(timeDelta, 0, 365 days);
        vm.warp(block.timestamp + 365 days);

        int256 balance = int256(uint256(rawBalance));
        uint256 updateTime = block.timestamp - timeDelta;
        _aggregator.setAnswer(balance, updateTime);

        IChainBalanceOracleAdapter.OracleResponse memory response = _adapter.getChainBalance(CHAIN_ID);

        bool expectedStale =
            updateTime < block.timestamp && block.timestamp - updateTime >= HEARTBEAT + HEARTBEAT_BUFFER_SECONDS;
        assertEq(response.isStale, expectedStale, "Fuzz: staleness should match expected");
    }
}

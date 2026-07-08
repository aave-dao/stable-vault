// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";

import {IPriceOracleAdapter} from "src/interfaces/IPriceOracleAdapter.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {ChainlinkPriceOracleAdapter} from "src/oracles/price/ChainlinkPriceOracleAdapter.sol";
import {Constants} from "src/types/Constants.sol";
import {Errors} from "src/types/Errors.sol";

import {MockChainlinkAggregator} from "test/mocks/MockChainlinkAggregator.sol";

contract ChainlinkPriceOracleAdapterTest is Test {
    using AssetLib for uint256;

    address constant ASSET = address(0xA55E7);
    uint256 constant HEARTBEAT = 3600; // 1 hour
    uint256 constant HEARTBEAT_BUFFER_SECONDS = 90;
    uint8 constant DECIMALS = 8;

    MockChainlinkAggregator internal _aggregator;
    ChainlinkPriceOracleAdapter internal _adapter;

    function setUp() public {
        _aggregator = new MockChainlinkAggregator(DECIMALS);
        _adapter = new ChainlinkPriceOracleAdapter(ASSET, address(_aggregator), HEARTBEAT);
    }

    function test_constructor_setsImmutables() public {
        int256 price = 1e8;
        _aggregator.setAnswer(price, block.timestamp);
        IPriceOracleAdapter.OracleResponse memory response = _adapter.getPrice(ASSET);
        // Verify the adapter works with the correct asset
        assertEq(response.priceRay, 1e27);
    }

    function test_getPrice_returnsPriceInRay(uint256 price) public {
        // Provide enough room for the price to be converted to RAY without overflowing.
        price = price / 10 ** (Constants.RAY_DECIMALS - DECIMALS);
        // forge-lint: disable-next-line(unsafe-typecast)
        _aggregator.setAnswer(int256(price), block.timestamp);
        IPriceOracleAdapter.OracleResponse memory response = _adapter.getPrice(ASSET);
        assertEq(
            response.priceRay,
            price.convertDecimals(DECIMALS, Constants.RAY_DECIMALS),
            "Price should be converted from 8 to 27 decimals"
        );
        assertFalse(response.isStale);
    }

    function test_getPrice_returnsZero_forAnyNegativePrice(int256 price) public {
        price = bound(price, type(int256).min, -1);
        _aggregator.setAnswer(price, block.timestamp);

        IPriceOracleAdapter.OracleResponse memory response = _adapter.getPrice(ASSET);

        assertEq(response.priceRay, 0, "Any negative price should return 0");
    }

    function test_getPrice_notStale_whenWithinHeartbeatPlusBuffer() public {
        vm.warp(block.timestamp + 1 days);
        uint256 updateTime = block.timestamp - (HEARTBEAT + HEARTBEAT_BUFFER_SECONDS - 1);
        _aggregator.setAnswer(1e8, updateTime);

        IPriceOracleAdapter.OracleResponse memory response = _adapter.getPrice(ASSET);

        assertFalse(response.isStale, "Should not be stale when within heartbeat + buffer");
    }

    function test_getPrice_stale_whenExactlyAtHeartbeatPlusBuffer() public {
        vm.warp(block.timestamp + 1 days);
        uint256 updateTime = block.timestamp - (HEARTBEAT + HEARTBEAT_BUFFER_SECONDS);
        _aggregator.setAnswer(1e8, updateTime);

        IPriceOracleAdapter.OracleResponse memory response = _adapter.getPrice(ASSET);

        assertTrue(response.isStale, "Should be stale when exactly at heartbeat + buffer");
    }

    function test_getPrice_stale_whenBeyondHeartbeatPlusBuffer() public {
        vm.warp(block.timestamp + 1 days);
        uint256 updateTime = block.timestamp - (HEARTBEAT + HEARTBEAT_BUFFER_SECONDS + 1000);
        _aggregator.setAnswer(1e8, updateTime);

        IPriceOracleAdapter.OracleResponse memory response = _adapter.getPrice(ASSET);

        assertTrue(response.isStale, "Should be stale when beyond heartbeat + buffer");
    }

    function test_getPrice_notStale_whenUpdatedAtEqualsBlockTimestamp() public {
        _aggregator.setAnswer(1e8, block.timestamp);

        IPriceOracleAdapter.OracleResponse memory response = _adapter.getPrice(ASSET);

        assertFalse(response.isStale, "Should not be stale when updatedAt == block.timestamp");
    }

    function test_getPrice_notStale_whenUpdatedAtIsInTheFuture() public {
        _aggregator.setAnswer(1e8, block.timestamp + 100);

        IPriceOracleAdapter.OracleResponse memory response = _adapter.getPrice(ASSET);

        assertFalse(response.isStale, "Should not be stale when updatedAt > block.timestamp");
    }

    function test_getPrice_reverts_ifAssetDoesNotMatch(address wrongAsset) public {
        vm.assume(wrongAsset != ASSET);

        vm.expectRevert(abi.encodeWithSelector(Errors.InvalidAsset.selector, wrongAsset));
        _adapter.getPrice(wrongAsset);
    }

    function test_getPrice_doesNotRevert_ifPriceIsZero() public {
        _aggregator.setAnswer(0, block.timestamp);

        IPriceOracleAdapter.OracleResponse memory response = _adapter.getPrice(ASSET);

        assertEq(response.priceRay, 0);
    }

    function test_getPrice_convertsSmallPrice() public {
        // 99957801 in 8 decimals
        _aggregator.setAnswer(99957801, block.timestamp);

        IPriceOracleAdapter.OracleResponse memory response = _adapter.getPrice(ASSET);

        // 99957801 * 10^(27-8) = 99957801e19
        assertEq(response.priceRay, 99957801e19, "99957801 unit at 8 decimals should be 99957801e19 in RAY");
    }

    function test_getPrice_convertsLargePrice() public {
        // 1 billion in 8 decimals
        int256 price = 1_234_567_890e8;
        _aggregator.setAnswer(price, block.timestamp);

        IPriceOracleAdapter.OracleResponse memory response = _adapter.getPrice(ASSET);
        assertEq(response.priceRay, 1_234_567_890e27, "Large price should scale correctly");
    }

    function test_getPrice_fuzz(uint128 rawPrice) public {
        vm.assume(rawPrice > 0);
        int256 price = int256(uint256(rawPrice));
        _aggregator.setAnswer(price, block.timestamp);

        IPriceOracleAdapter.OracleResponse memory response = _adapter.getPrice(ASSET);

        uint256 expectedRay = uint256(rawPrice) * 1e19;
        assertEq(response.priceRay, expectedRay, "Fuzz: price should convert to RAY correctly");
    }

    function test_getPrice_staleness_fuzz(uint128 rawPrice, uint256 timeDelta) public {
        vm.assume(rawPrice > 0);
        timeDelta = bound(timeDelta, 0, 365 days);
        vm.warp(block.timestamp + 365 days);

        int256 price = int256(uint256(rawPrice));
        uint256 updateTime = block.timestamp - timeDelta;
        _aggregator.setAnswer(price, updateTime);

        IPriceOracleAdapter.OracleResponse memory response = _adapter.getPrice(ASSET);

        bool expectedStale =
            updateTime < block.timestamp && block.timestamp - updateTime >= HEARTBEAT + HEARTBEAT_BUFFER_SECONDS;
        assertEq(response.isStale, expectedStale, "Fuzz: staleness should match expected");
    }
}

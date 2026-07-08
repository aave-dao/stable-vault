// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";

import {Constants} from "src/types/Constants.sol";

/// @notice Pins sentinel addresses to their expected values so an accidental change (e.g. collapsing back to
/// `address(0)`) is caught regardless of the rest of the suite passing.
contract ConstantsTest is Test {
    function test_nativeCurrencyConstant_matchesExpectedValue() public pure {
        assertEq(Constants.NATIVE_CURRENCY, 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
    }

    function test_assetForDataOnlyBridgeConstant_matchesExpectedValue() public pure {
        assertEq(Constants.ASSET_FOR_DATA_ONLY_BRIDGE, 0xDA7ada7aDA7ADA7ADA7AdA7aDA7aDA7ADA7adA7a);
    }

    function test_sentinels_areNonZeroAndDistinct() public pure {
        assertTrue(Constants.NATIVE_CURRENCY != address(0), "NATIVE_CURRENCY must not be address(0)");
        assertTrue(
            Constants.ASSET_FOR_DATA_ONLY_BRIDGE != address(0), "ASSET_FOR_DATA_ONLY_BRIDGE must not be address(0)"
        );
        assertTrue(
            Constants.NATIVE_CURRENCY != Constants.ASSET_FOR_DATA_ONLY_BRIDGE,
            "NATIVE_CURRENCY and ASSET_FOR_DATA_ONLY_BRIDGE must be distinct"
        );
    }
}

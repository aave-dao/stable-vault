// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Test} from "forge-std/Test.sol";

import {AssetLibWrapper} from "../mocks/AssetLibWrapper.sol";
import {TestErc20} from "../mocks/TestErc20.sol";

contract AssetLibTest is Test {
    AssetLibWrapper internal w;

    function setUp() public {
        w = new AssetLibWrapper();
    }

    function test_convertDecimals() public view {
        assertEq(w.convertDecimals(0, 0, 5), 0);
        assertEq(w.convertDecimals(0, 5, 0), 0);
        assertEq(w.convertDecimals(0, 5, 5), 0);
        assertEq(w.convertDecimals(0, 1, 0), 0);
        assertEq(w.convertDecimals(0, 0, 1), 0);

        assertEq(w.convertDecimals(1, 0, 5), 100000);
        assertEq(w.convertDecimals(1, 5, 0), 0);
        assertEq(w.convertDecimals(1, 5, 5), 1);
        assertEq(w.convertDecimals(1, 1, 0), 0);
        assertEq(w.convertDecimals(1, 0, 1), 10);
        assertEq(w.convertDecimals(11, 0, 1), 110);
        assertEq(w.convertDecimals(11, 1, 0), 1);
        assertEq(w.convertDecimals(19, 1, 0), 1);

        assertEq(w.convertDecimals(3, 0, 5), 300000);
        assertEq(w.convertDecimals(3, 5, 0), 0);
        assertEq(w.convertDecimals(3, 5, 5), 3);
        assertEq(w.convertDecimals(3, 1, 0), 0);
        assertEq(w.convertDecimals(3, 0, 1), 30);
        assertEq(w.convertDecimals(31, 1, 0), 3);
        assertEq(w.convertDecimals(31, 0, 1), 310);
        assertEq(w.convertDecimals(39, 1, 0), 3);

        assertEq(w.convertDecimals(1234567, 6, 18), 1234567 * 1e12);
        assertEq(w.convertDecimals(1234567, 6, 3), 1234);
        assertEq(w.convertDecimals(12345678901234567890, 18, 6), 12345678);
    }

    function test_assetDecimalsToRay() public {
        address assetWith6Decimals = address(new TestErc20(6));
        assertEq(w.assetDecimalsToRay(0, assetWith6Decimals), 0);
        assertEq(w.assetDecimalsToRay(1, assetWith6Decimals), 1 * 1e21);
        assertEq(w.assetDecimalsToRay(12, assetWith6Decimals), 12 * 1e21);
        assertEq(w.assetDecimalsToRay(123, assetWith6Decimals), 123 * 1e21);
        assertEq(w.assetDecimalsToRay(1234, assetWith6Decimals), 1234 * 1e21);
        assertEq(w.assetDecimalsToRay(12345, assetWith6Decimals), 12345 * 1e21);
        assertEq(w.assetDecimalsToRay(123456, assetWith6Decimals), 123456 * 1e21);
        assertEq(w.assetDecimalsToRay(1234567, assetWith6Decimals), 1234567 * 1e21);

        address assetWith18Decimals = address(new TestErc20(18));
        assertEq(w.assetDecimalsToRay(0, assetWith18Decimals), 0);
        assertEq(w.assetDecimalsToRay(1, assetWith18Decimals), 1 * 1e9);
        assertEq(w.assetDecimalsToRay(12, assetWith18Decimals), 12 * 1e9);
        assertEq(w.assetDecimalsToRay(123, assetWith18Decimals), 123 * 1e9);
        assertEq(w.assetDecimalsToRay(1234, assetWith18Decimals), 1234 * 1e9);
        assertEq(w.assetDecimalsToRay(12345, assetWith18Decimals), 12345 * 1e9);
        assertEq(w.assetDecimalsToRay(123456, assetWith18Decimals), 123456 * 1e9);
        assertEq(w.assetDecimalsToRay(1234567, assetWith18Decimals), 1234567 * 1e9);

        address assetWith27Decimals = address(new TestErc20(27));
        assertEq(w.assetDecimalsToRay(0, assetWith27Decimals), 0);
        assertEq(w.assetDecimalsToRay(1, assetWith27Decimals), 1);
        assertEq(w.assetDecimalsToRay(12, assetWith27Decimals), 12);
        assertEq(w.assetDecimalsToRay(123, assetWith27Decimals), 123);
        assertEq(w.assetDecimalsToRay(1234, assetWith27Decimals), 1234);
        assertEq(w.assetDecimalsToRay(12345, assetWith27Decimals), 12345);
        assertEq(w.assetDecimalsToRay(123456, assetWith27Decimals), 123456);
        assertEq(w.assetDecimalsToRay(1234567, assetWith27Decimals), 1234567);

        address assetWith33Decimals = address(new TestErc20(33));
        assertEq(w.assetDecimalsToRay(0, assetWith33Decimals), 0);
        assertEq(w.assetDecimalsToRay(1, assetWith33Decimals), 0);
        assertEq(w.assetDecimalsToRay(12, assetWith33Decimals), 0);
        assertEq(w.assetDecimalsToRay(123, assetWith33Decimals), 0);
        assertEq(w.assetDecimalsToRay(1234, assetWith33Decimals), 0);
        assertEq(w.assetDecimalsToRay(12345, assetWith33Decimals), 0);
        assertEq(w.assetDecimalsToRay(123456, assetWith33Decimals), 0);
        assertEq(w.assetDecimalsToRay(1234567, assetWith33Decimals), 1);
        assertEq(w.assetDecimalsToRay(12345678, assetWith33Decimals), 12);
        assertEq(w.assetDecimalsToRay(123456789, assetWith33Decimals), 123);
        assertEq(w.assetDecimalsToRay(1234567890, assetWith33Decimals), 1234);
        assertEq(w.assetDecimalsToRay(12345678901, assetWith33Decimals), 12345);
        assertEq(w.assetDecimalsToRay(123456789012, assetWith33Decimals), 123456);
        assertEq(w.assetDecimalsToRay(1234567890123, assetWith33Decimals), 1234567);
        assertEq(w.assetDecimalsToRay(12345678901234, assetWith33Decimals), 12345678);
        assertEq(w.assetDecimalsToRay(123456789012345, assetWith33Decimals), 123456789);
        assertEq(w.assetDecimalsToRay(1234567890123456, assetWith33Decimals), 1234567890);
    }

    function test_rayToAssetDecimals() public {
        address assetWith6Decimals = address(new TestErc20(6));
        assertEq(w.rayToAssetDecimals(0, assetWith6Decimals), 0);
        assertEq(w.rayToAssetDecimals(1, assetWith6Decimals), 0);
        assertEq(w.rayToAssetDecimals(12, assetWith6Decimals), 0);
        assertEq(w.rayToAssetDecimals(123, assetWith6Decimals), 0);
        assertEq(w.rayToAssetDecimals(1234, assetWith6Decimals), 0);
        assertEq(w.rayToAssetDecimals(12345, assetWith6Decimals), 0);
        assertEq(w.rayToAssetDecimals(123456, assetWith6Decimals), 0);
        assertEq(w.rayToAssetDecimals(1234567, assetWith6Decimals), 0);
        assertEq(w.rayToAssetDecimals(12345678, assetWith6Decimals), 0);
        assertEq(w.rayToAssetDecimals(123456789, assetWith6Decimals), 0);
        assertEq(w.rayToAssetDecimals(1234567890, assetWith6Decimals), 0);
        assertEq(w.rayToAssetDecimals(12345678901, assetWith6Decimals), 0);
        assertEq(w.rayToAssetDecimals(123456789012, assetWith6Decimals), 0);
        assertEq(w.rayToAssetDecimals(1234567890123, assetWith6Decimals), 0);
        assertEq(w.rayToAssetDecimals(12345678901234, assetWith6Decimals), 0);
        assertEq(w.rayToAssetDecimals(123456789012345, assetWith6Decimals), 0);
        assertEq(w.rayToAssetDecimals(1234567890123456, assetWith6Decimals), 0);
        assertEq(w.rayToAssetDecimals(12345678901234567, assetWith6Decimals), 0);
        assertEq(w.rayToAssetDecimals(123456789012345678, assetWith6Decimals), 0);
        assertEq(w.rayToAssetDecimals(1234567890123456789, assetWith6Decimals), 0);
        assertEq(w.rayToAssetDecimals(12345678901234567890, assetWith6Decimals), 0);
        assertEq(w.rayToAssetDecimals(123456789012345678901, assetWith6Decimals), 0);
        assertEq(w.rayToAssetDecimals(1234567890123456789012, assetWith6Decimals), 1);
        assertEq(w.rayToAssetDecimals(12345678901234567890123, assetWith6Decimals), 12);
        assertEq(w.rayToAssetDecimals(123456789012345678901234, assetWith6Decimals), 123);
        assertEq(w.rayToAssetDecimals(1234567890123456789012345, assetWith6Decimals), 1234);
        assertEq(w.rayToAssetDecimals(12345678901234567890123456, assetWith6Decimals), 12345);
        assertEq(w.rayToAssetDecimals(123456789012345678901234567, assetWith6Decimals), 123456);

        address assetWith18Decimals = address(new TestErc20(18));
        assertEq(w.rayToAssetDecimals(0, assetWith18Decimals), 0);
        assertEq(w.rayToAssetDecimals(1, assetWith18Decimals), 0);
        assertEq(w.rayToAssetDecimals(12, assetWith18Decimals), 0);
        assertEq(w.rayToAssetDecimals(123, assetWith18Decimals), 0);
        assertEq(w.rayToAssetDecimals(1234, assetWith18Decimals), 0);
        assertEq(w.rayToAssetDecimals(12345, assetWith18Decimals), 0);
        assertEq(w.rayToAssetDecimals(123456, assetWith18Decimals), 0);
        assertEq(w.rayToAssetDecimals(1234567, assetWith18Decimals), 0);
        assertEq(w.rayToAssetDecimals(12345678, assetWith18Decimals), 0);
        assertEq(w.rayToAssetDecimals(123456789, assetWith18Decimals), 0);
        assertEq(w.rayToAssetDecimals(1234567890, assetWith18Decimals), 1);
        assertEq(w.rayToAssetDecimals(12345678901, assetWith18Decimals), 12);
        assertEq(w.rayToAssetDecimals(123456789012, assetWith18Decimals), 123);
        assertEq(w.rayToAssetDecimals(1234567890123, assetWith18Decimals), 1234);
        assertEq(w.rayToAssetDecimals(12345678901234, assetWith18Decimals), 12345);
        assertEq(w.rayToAssetDecimals(123456789012345, assetWith18Decimals), 123456);

        address assetWith27Decimals = address(new TestErc20(27));
        assertEq(w.rayToAssetDecimals(0, assetWith27Decimals), 0);
        assertEq(w.rayToAssetDecimals(1, assetWith27Decimals), 1);
        assertEq(w.rayToAssetDecimals(12, assetWith27Decimals), 12);
        assertEq(w.rayToAssetDecimals(123, assetWith27Decimals), 123);
        assertEq(w.rayToAssetDecimals(1234, assetWith27Decimals), 1234);
        assertEq(w.rayToAssetDecimals(12345, assetWith27Decimals), 12345);
        assertEq(w.rayToAssetDecimals(123456, assetWith27Decimals), 123456);
        assertEq(w.rayToAssetDecimals(1234567, assetWith27Decimals), 1234567);

        address assetWith33Decimals = address(new TestErc20(33));
        assertEq(w.rayToAssetDecimals(0, assetWith33Decimals), 0);
        assertEq(w.rayToAssetDecimals(1, assetWith33Decimals), 1 * 1e6);
        assertEq(w.rayToAssetDecimals(12, assetWith33Decimals), 12 * 1e6);
        assertEq(w.rayToAssetDecimals(123, assetWith33Decimals), 123 * 1e6);
        assertEq(w.rayToAssetDecimals(1234, assetWith33Decimals), 1234 * 1e6);
        assertEq(w.rayToAssetDecimals(12345, assetWith33Decimals), 12345 * 1e6);
        assertEq(w.rayToAssetDecimals(123456, assetWith33Decimals), 123456 * 1e6);
        assertEq(w.rayToAssetDecimals(1234567, assetWith33Decimals), 1234567 * 1e6);
        assertEq(w.rayToAssetDecimals(12345678, assetWith33Decimals), 12345678 * 1e6);
        assertEq(w.rayToAssetDecimals(123456789, assetWith33Decimals), 123456789 * 1e6);
        assertEq(w.rayToAssetDecimals(1234567890, assetWith33Decimals), 1234567890 * 1e6);
        assertEq(w.rayToAssetDecimals(12345678901, assetWith33Decimals), 12345678901 * 1e6);
        assertEq(w.rayToAssetDecimals(123456789012, assetWith33Decimals), 123456789012 * 1e6);
        assertEq(w.rayToAssetDecimals(1234567890123, assetWith33Decimals), 1234567890123 * 1e6);
        assertEq(w.rayToAssetDecimals(12345678901234, assetWith33Decimals), 12345678901234 * 1e6);
        assertEq(w.rayToAssetDecimals(123456789012345, assetWith33Decimals), 123456789012345 * 1e6);
        assertEq(w.rayToAssetDecimals(1234567890123456, assetWith33Decimals), 1234567890123456 * 1e6);
    }

    function test_convertDecimals_fuzz(uint256 inputAmount, uint256 inputDecimals, uint256 outputDecimals) public view {
        if (inputDecimals == outputDecimals) {
            uint256 result = w.convertDecimals(inputAmount, inputDecimals, outputDecimals);
            assertEq(result, inputAmount, "wrong output when inputDecimals == outputDecimals");
            return;
        }

        // Bounding to not overflow
        inputDecimals = bound(inputDecimals, 0, 77);
        outputDecimals = bound(outputDecimals, 0, 77 - inputDecimals);
        if (outputDecimals > inputDecimals) {
            uint256 multiplier = 10 ** (outputDecimals - inputDecimals);
            inputAmount = bound(inputAmount, 0, type(uint256).max / multiplier);
        }

        uint256 expectedResult = _calculateExpectedResult(inputAmount, inputDecimals, outputDecimals);
        assertEq(expectedResult, w.convertDecimals(inputAmount, inputDecimals, outputDecimals), "wrong output");
    }

    function _calculateExpectedResult(uint256 inputAmount, uint256 inputDecimals, uint256 outputDecimals)
        internal
        pure
        returns (uint256)
    {
        if (inputDecimals == outputDecimals) {
            return inputAmount;
        } else if (inputDecimals < outputDecimals) {
            uint256 decimalsDiff = outputDecimals - inputDecimals;
            uint256 multiplier = 10 ** decimalsDiff;
            return inputAmount * multiplier;
        } else {
            uint256 decimalsDiff = inputDecimals - outputDecimals;
            uint256 divisor = 10 ** decimalsDiff;
            return inputAmount / divisor;
        }
    }

    function test_assetDecimalsToRay_fuzz(uint256 inputAmount, uint256 assetDecimals) public {
        uint256 outputDecimals = 27;
        assetDecimals = bound(assetDecimals, 0, 50);
        if (assetDecimals < outputDecimals) {
            uint256 decimalsDiff = outputDecimals - assetDecimals;
            uint256 multiplier = 10 ** decimalsDiff;
            inputAmount = bound(inputAmount, 0, type(uint256).max / multiplier);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        address asset = address(new TestErc20(uint8(assetDecimals)));
        uint256 expectedResult = _calculateExpectedResult(inputAmount, assetDecimals, outputDecimals);
        assertEq(expectedResult, w.assetDecimalsToRay(inputAmount, asset), "assetDecimalsToRay wrong output");
    }

    function test_rayToAssetDecimals_fuzz(uint256 inputAmount, uint256 assetDecimals) public {
        uint256 inputDecimals = 27;
        assetDecimals = bound(assetDecimals, 0, 77);
        if (assetDecimals > inputDecimals) {
            uint256 decimalsDiff = assetDecimals - inputDecimals;
            uint256 multiplier = 10 ** decimalsDiff;
            inputAmount = bound(inputAmount, 0, type(uint256).max / multiplier);
        }
        // forge-lint: disable-next-line(unsafe-typecast)
        address asset = address(new TestErc20(uint8(assetDecimals)));
        uint256 expectedResult = _calculateExpectedResult(inputAmount, inputDecimals, assetDecimals);
        assertEq(expectedResult, w.rayToAssetDecimals(inputAmount, asset), "rayToAssetDecimals wrong output");
    }

    function test_convertAssetDecimals_fuzz(uint256 inputAmount, uint256 inputDecimals, uint256 outputDecimals) public {
        if (inputDecimals == outputDecimals) {
            uint256 result = w.convertDecimals(inputAmount, inputDecimals, outputDecimals);
            assertEq(result, inputAmount, "wrong output when inputDecimals == outputDecimals");
            return;
        }

        // Bounding to not overflow
        inputDecimals = bound(inputDecimals, 0, 77);
        outputDecimals = bound(outputDecimals, 0, 77 - inputDecimals);
        if (outputDecimals > inputDecimals) {
            uint256 multiplier = 10 ** (outputDecimals - inputDecimals);
            inputAmount = bound(inputAmount, 0, type(uint256).max / multiplier);
        }

        uint256 expectedResult = _calculateExpectedResult(inputAmount, inputDecimals, outputDecimals);

        // forge-lint: disable-next-line(unsafe-typecast)
        address fromAsset = address(new TestErc20(uint8(inputDecimals)));
        // forge-lint: disable-next-line(unsafe-typecast)
        address toAsset = address(new TestErc20(uint8(outputDecimals)));
        assertEq(
            expectedResult, w.convertAssetDecimals(inputAmount, fromAsset, toAsset), "convertAssetDecimals wrong output"
        );
    }

    function test_getDecimals(uint256 decimals) public {
        decimals = bound(decimals, 0, 77);
        // forge-lint: disable-next-line(unsafe-typecast)
        address asset = address(new TestErc20(uint8(decimals)));
        vm.expectCall(asset, abi.encodeWithSelector(IERC20Metadata.decimals.selector));
        uint256 decimalsFromAsset = w.getDecimals(asset);
        assertEq(decimalsFromAsset, decimals, "got wrong decimals from asset");
    }

    function test_getDecimals_fromNonStandardAsset() public {
        uint256 defaultDecimals = 18;
        address asset = makeAddr("NonStandardAsset");
        vm.expectCall(asset, abi.encodeWithSelector(IERC20Metadata.decimals.selector));
        uint256 decimalsFromAsset = w.getDecimals(asset);
        assertEq(decimalsFromAsset, defaultDecimals, "got wrong decimals from non-standard asset");
    }
}

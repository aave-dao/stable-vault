// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Test} from "forge-std/Test.sol";

import {IPriceOracle} from "src/interfaces/IPriceOracle.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {PriceOracle} from "src/oracles/price/PriceOracle.sol";

import {IMockErc20} from "test/mocks/MockErc20.sol";

contract TestWithHelpers is Test {
    uint256 constant DEFAULT_MAX_PER_SECOND_RATE = 1000000005781378656804591713; // ~20% APY

    uint256 constant MAX_DEPOSIT_AMOUNT = 100_000_000_000_000; // 100 trillion

    uint256 constant NATIVE_CURRENCY_DECIMALS = 18;

    function _boundAssetDecimals(uint8 assetDecimals) internal pure returns (uint8) {
        return uint8(bound(assetDecimals, 2, 18));
    }

    function _assumeNotProxyAdmin(address fuzzedAddress, address targetAddress) internal view {
        address proxyAdmin = address(uint160(uint256(vm.load(targetAddress, ERC1967Utils.ADMIN_SLOT))));
        vm.assume(fuzzedAddress != proxyAdmin);
    }

    function _boundRate(uint256 rate) internal pure returns (uint256) {
        return bound(rate, MathLib.RAY, DEFAULT_MAX_PER_SECOND_RATE);
    }

    function _boundRate(uint256 rate, uint256 maxValidRate) internal pure returns (uint256) {
        return bound(rate, MathLib.RAY, maxValidRate);
    }

    function _boundRayAmountAllowingZero(uint256 amount) internal pure returns (uint256) {
        return _boundAmountAllowingZero(amount, MathLib.RAY);
    }

    function _boundAssetAmount(address asset, uint256 amount) internal view returns (uint256) {
        return _boundNonZeroAmount(amount, _decimalsToScaleFactor(IMockErc20(asset).decimals()));
    }

    function _boundAssetAmountAllowingZero(address asset, uint256 amount) internal view returns (uint256) {
        return _boundAmountAllowingZero(amount, _decimalsToScaleFactor(IMockErc20(asset).decimals()));
    }

    function _boundNativeAmount(uint256 amount) internal pure returns (uint256) {
        return _boundNonZeroAmount(amount, _decimalsToScaleFactor(NATIVE_CURRENCY_DECIMALS));
    }

    function _boundNativeAmountAllowingZero(uint256 amount) internal pure returns (uint256) {
        return _boundAmountAllowingZero(amount, _decimalsToScaleFactor(NATIVE_CURRENCY_DECIMALS));
    }

    function _boundRayAmount(uint256 amount) internal pure returns (uint256) {
        return _boundNonZeroAmount(amount, MathLib.RAY);
    }

    function _boundNonZeroAmount(uint256 amount, uint256 scaleFactor) internal pure returns (uint256) {
        return _boundAmount(amount, 1, scaleFactor);
    }

    function _boundAmountAllowingZero(uint256 amount, uint256 scaleFactor) internal pure returns (uint256) {
        return _boundAmount(amount, 0, scaleFactor);
    }

    function _boundAmount(uint256 amount, uint256 minAmount, uint256 scaleFactor) internal pure returns (uint256) {
        return bound(amount, minAmount, MAX_DEPOSIT_AMOUNT * scaleFactor);
    }

    function _decimalsToScaleFactor(uint256 decimals) private pure returns (uint256) {
        return 10 ** decimals;
    }

    ///////////// Price Oracle Helpers /////////////

    /// @dev Deploys a PriceOracle with TransparentUpgradeableProxy
    function _deployPriceOracle(address accessManager, uint256 minValidPriceRay)
        internal
        virtual
        returns (PriceOracle)
    {
        address priceOracleImpl = address(new PriceOracle(minValidPriceRay));
        return PriceOracle(
            address(
                new TransparentUpgradeableProxy(
                    priceOracleImpl, address(this), abi.encodeCall(PriceOracle.initialize, (accessManager))
                )
            )
        );
    }

    /// @dev Mocks the price for an asset on a price oracle using vm.mockCall
    function _mockAssetPrice(address priceOracle, address asset, uint256 priceRay) internal {
        vm.mockCall(priceOracle, abi.encodeCall(IPriceOracle.getPrice, (asset)), abi.encode(priceRay));
    }

    /// @dev Mocks validatePrice to not revert (valid price) for a specific asset
    function _mockValidatePrice(address priceOracle, address asset) internal {
        vm.mockCall(priceOracle, abi.encodeCall(IPriceOracle.validatePrice, (asset)), abi.encode());
    }

    /// @dev Mocks validatePrice to not revert (valid price) for ANY asset
    function _mockValidatePriceForAll(address priceOracle) internal {
        vm.mockCall(priceOracle, abi.encodeWithSelector(IPriceOracle.validatePrice.selector), abi.encode());
    }

    /// @dev Mocks validatePrice to revert with InvalidPrice error
    function _mockInvalidPrice(address priceOracle, address asset) internal {
        vm.mockCallRevert(
            priceOracle,
            abi.encodeCall(IPriceOracle.validatePrice, (asset)),
            abi.encodeWithSelector(IPriceOracle.InvalidPrice.selector)
        );
    }
}

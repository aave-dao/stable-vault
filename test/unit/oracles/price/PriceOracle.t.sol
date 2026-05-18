// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {IPriceOracle} from "src/interfaces/IPriceOracle.sol";
import {IPriceOracle} from "src/interfaces/IPriceOracle.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {PriceOracle} from "src/oracles/price/PriceOracle.sol";
import {Errors} from "src/types/Errors.sol";

import {TestWithHelpers} from "test/helpers/TestWithHelpers.sol";
import {GasBurnerPriceOracleAdapter} from "test/mocks/GasBurnerPriceOracleAdapter.sol";
import {MockAccessManager} from "test/mocks/MockAccessManager.sol";
import {MockPriceOracleAdapter} from "test/mocks/MockPriceOracleAdapter.sol";

contract PriceOracleTest is TestWithHelpers {
    address admin = makeAddr("ADMIN");
    address everyRoleAccount = makeAddr("EVERY_ROLE_ACCOUNT");
    uint256 constant MIN_VALID_PRICE_RAY = 9_995e23;

    address asset1 = makeAddr("asset1");
    address asset2 = makeAddr("asset2");
    address asset3 = makeAddr("asset3");

    MockAccessManager internal _mockAccessManager;
    PriceOracle internal _priceOracle;
    MockPriceOracleAdapter internal _mockAdapter;

    function _deployPriceOracleWithMinPrice(address accessManager, uint256 minValidPriceRay)
        internal
        returns (PriceOracle)
    {
        address impl = address(new PriceOracle(minValidPriceRay));
        return PriceOracle(
            address(
                new TransparentUpgradeableProxy(
                    impl, address(this), abi.encodeCall(PriceOracle.initialize, (accessManager))
                )
            )
        );
    }

    function setUp() public virtual {
        _mockAccessManager = new MockAccessManager(admin);
        // Use 0 as minValidPriceRay for most tests (no minimum price validation)
        _priceOracle = _deployPriceOracleWithMinPrice(address(_mockAccessManager), MIN_VALID_PRICE_RAY);
        _mockAdapter = new MockPriceOracleAdapter();
    }

    function test_initialize_setsAccessManager() public view {
        assertEq(_priceOracle.authority(), address(_mockAccessManager));
    }

    function test_initialize_reverts_ifCalledTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        _priceOracle.initialize(address(_mockAccessManager));
    }

    function test_constructor_disablesInitializers() public {
        PriceOracle impl = new PriceOracle(MIN_VALID_PRICE_RAY);
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(_mockAccessManager));
    }

    function test_constructor_reverts_ifMinValidPriceAboveRay() public {
        vm.expectRevert(IPriceOracle.InvalidMinPrice.selector);
        new PriceOracle(MathLib.RAY + 1);
    }

    function test_setOracleAdapterForAsset_setsAdapter(uint256 priceRay) public {
        priceRay = bound(priceRay, 0, MathLib.RAY);
        _mockAdapter.mockResponse(asset1, priceRay, false);

        vm.expectEmit(true, true, true, true);
        emit PriceOracle.OracleAdapterSet(asset1, address(_mockAdapter), address(0));

        vm.prank(everyRoleAccount);
        _priceOracle.setOracleAdapterForAsset(asset1, address(_mockAdapter));
    }

    function test_setOracleAdapterForAsset_emitsEventWithPreviousAdapter(uint256 priceRay) public {
        priceRay = bound(priceRay, 0, MathLib.RAY);
        _mockAdapter.mockResponse(asset1, priceRay, false);

        vm.prank(everyRoleAccount);
        _priceOracle.setOracleAdapterForAsset(asset1, address(_mockAdapter));

        // Create new adapter
        MockPriceOracleAdapter newAdapter = new MockPriceOracleAdapter();
        newAdapter.mockResponse(asset1, priceRay, false);

        // Setting a new adapter should emit event with previous adapter
        vm.expectEmit(true, true, true, true);
        emit PriceOracle.OracleAdapterSet(asset1, address(newAdapter), address(_mockAdapter));

        vm.prank(everyRoleAccount);
        _priceOracle.setOracleAdapterForAsset(asset1, address(newAdapter));
    }

    function test_setOracleAdapterForAsset_reverts_ifAssetIsZeroAddress() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        vm.prank(everyRoleAccount);
        _priceOracle.setOracleAdapterForAsset(address(0), address(_mockAdapter));
    }

    function test_setOracleAdapterForAsset_reverts_ifAdapterCallFails() public {
        _mockAdapter.setShouldRevert(true, "reason");

        vm.expectRevert("reason");
        vm.prank(everyRoleAccount);
        _priceOracle.setOracleAdapterForAsset(asset1, address(_mockAdapter));
    }

    function test_setOracleAdapterForAsset_reverts_ifNotAuthorized(address unauthorizedCaller) public {
        vm.assume(unauthorizedCaller != address(0));
        _assumeNotProxyAdmin(unauthorizedCaller, address(_priceOracle));

        _mockAccessManager.mockRejectCall(
            unauthorizedCaller, address(_priceOracle), PriceOracle.setOracleAdapterForAsset.selector
        );

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedCaller));
        vm.prank(unauthorizedCaller);
        _priceOracle.setOracleAdapterForAsset(asset1, address(_mockAdapter));
    }

    function test_getOracleAdapterForAsset_returnsZeroIfNotSet(address asset) public view {
        assertEq(_priceOracle.getOracleAdapterForAsset(asset), address(0));
    }

    function test_getOracleAdapterForAsset_returnsConfiguredAdapter(uint256 priceRay) public {
        priceRay = bound(priceRay, 0, MathLib.RAY);
        _mockAdapter.mockResponse(asset1, priceRay, false);

        vm.prank(everyRoleAccount);
        _priceOracle.setOracleAdapterForAsset(asset1, address(_mockAdapter));

        assertEq(_priceOracle.getOracleAdapterForAsset(asset1), address(_mockAdapter));
    }

    function test_getPrice_returnsPrice_whenNotStale(uint256 priceRay) public {
        priceRay = bound(priceRay, 0, MathLib.RAY);
        _mockAdapter.mockResponse(asset1, priceRay, false);

        vm.prank(everyRoleAccount);
        _priceOracle.setOracleAdapterForAsset(asset1, address(_mockAdapter));

        uint256 result = _priceOracle.getPrice(asset1);
        assertEq(result, priceRay, "Should return priceRay when not stale");
    }

    function test_getPrice_returnsZero_whenStale(uint256 priceRay) public {
        priceRay = bound(priceRay, 1, MathLib.RAY);
        _mockAdapter.mockResponse(asset1, priceRay, true);

        vm.prank(everyRoleAccount);
        _priceOracle.setOracleAdapterForAsset(asset1, address(_mockAdapter));

        uint256 result = _priceOracle.getPrice(asset1);
        assertEq(result, 0, "Should return 0 when stale");
    }

    function test_getPrice_reverts_ifAdapterNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(PriceOracle.OracleAdapterNotFound.selector, asset1));
        _priceOracle.getPrice(asset1);
    }

    function test_getPrice_returnsZero_whenAdapterReverts() public {
        vm.prank(everyRoleAccount);
        _priceOracle.setOracleAdapterForAsset(asset1, address(_mockAdapter));

        _mockAdapter.setShouldRevert(true, "feed paused");

        uint256 result = _priceOracle.getPrice(asset1);
        assertEq(result, 0, "Should return 0 when adapter reverts");
    }

    function test_getPrice_reverts_whenAdapterOOGs() public {
        GasBurnerPriceOracleAdapter burner = new GasBurnerPriceOracleAdapter();
        burner.setResponse(MathLib.RAY, false);

        vm.prank(everyRoleAccount);
        _priceOracle.setOracleAdapterForAsset(asset1, address(burner));

        burner.setBurnEnabled(true);

        // Cap forwarded gas so the inner loop OOGs while the outer frame can still execute the catch.
        vm.expectRevert(PriceOracle.InsufficientGasForExternalCall.selector);
        _priceOracle.getPrice{gas: 200_000}(asset1);
    }

    function test_getPrice_capsToMaxPriceRay(uint256 priceRay) public {
        priceRay = bound(priceRay, MathLib.RAY + 1, type(uint256).max);
        _mockAdapter.mockResponse(asset1, priceRay, false);

        vm.prank(everyRoleAccount);
        _priceOracle.setOracleAdapterForAsset(asset1, address(_mockAdapter));

        uint256 result = _priceOracle.getPrice(asset1);
        assertEq(result, MathLib.RAY, "Should cap price to MAX_PRICE_RAY (1 RAY)");
    }

    function test_getPrices_returnsArrayOfPrices() public {
        uint256 price1 = 0.5e27;
        uint256 price2 = 0.8e27;
        uint256 price3 = 1e27;

        MockPriceOracleAdapter adapter1 = new MockPriceOracleAdapter();
        MockPriceOracleAdapter adapter2 = new MockPriceOracleAdapter();
        MockPriceOracleAdapter adapter3 = new MockPriceOracleAdapter();

        adapter1.mockResponse(asset1, price1, false);
        adapter2.mockResponse(asset2, price2, false);
        // This one is stale
        adapter3.mockResponse(asset3, price3, true);

        vm.startPrank(everyRoleAccount);
        _priceOracle.setOracleAdapterForAsset(asset1, address(adapter1));
        _priceOracle.setOracleAdapterForAsset(asset2, address(adapter2));
        _priceOracle.setOracleAdapterForAsset(asset3, address(adapter3));
        vm.stopPrank();

        address[] memory assets = new address[](3);
        assets[0] = asset1;
        assets[1] = asset2;
        assets[2] = asset3;

        uint256[] memory prices = _priceOracle.getPrices(assets);

        assertEq(prices.length, 3, "Should return 3 prices");
        assertEq(prices[0], price1, "Asset 1 price mismatch");
        assertEq(prices[1], price2, "Asset 2 price mismatch");
        assertEq(prices[2], 0, "Asset 3 should return 0 (stale)");
    }

    function test_getPrices_returnsEmptyArray_forEmptyInput() public view {
        address[] memory assets = new address[](0);
        uint256[] memory prices = _priceOracle.getPrices(assets);
        assertEq(prices.length, 0, "Should return empty array");
    }

    function test_validatePrice_reverts_ifStale(uint256 priceRay) public {
        priceRay = bound(priceRay, 1, MathLib.RAY);
        _mockAdapter.mockResponse(asset1, priceRay, true);

        vm.prank(everyRoleAccount);
        _priceOracle.setOracleAdapterForAsset(asset1, address(_mockAdapter));

        vm.expectRevert(IPriceOracle.StalePrice.selector);
        _priceOracle.validatePrice(asset1);
    }

    function test_validatePrice_reverts_ifAdapterNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(PriceOracle.OracleAdapterNotFound.selector, asset1));
        _priceOracle.validatePrice(asset1);
    }

    function test_validatePrice_reverts_ifPriceBelowMinimum() public {
        uint256 minValidPrice = 0.9e27;
        PriceOracle oracleWithMinPrice = _deployPriceOracleWithMinPrice(address(_mockAccessManager), minValidPrice);

        uint256 lowPrice = 0.5e27;
        _mockAdapter.mockResponse(asset1, lowPrice, false);

        vm.prank(everyRoleAccount);
        oracleWithMinPrice.setOracleAdapterForAsset(asset1, address(_mockAdapter));

        vm.expectRevert(IPriceOracle.PriceTooLow.selector);
        oracleWithMinPrice.validatePrice(asset1);
    }

    function test_validatePrice_passes_whenValidAndNotStale(uint256 priceRay) public {
        _priceOracle = _deployPriceOracleWithMinPrice(address(_mockAccessManager), 1);
        priceRay = bound(priceRay, 1, MathLib.RAY);
        _mockAdapter.mockResponse(asset1, priceRay, false);

        vm.prank(everyRoleAccount);
        _priceOracle.setOracleAdapterForAsset(asset1, address(_mockAdapter));

        _priceOracle.validatePrice(asset1);
    }

    function test_validatePrice_passes_whenPriceAtMinimum() public {
        uint256 minValidPrice = 0.9e27;
        PriceOracle oracleWithMinPrice = _deployPriceOracleWithMinPrice(address(_mockAccessManager), minValidPrice);

        _mockAdapter.mockResponse(asset1, minValidPrice, false);

        vm.prank(everyRoleAccount);
        oracleWithMinPrice.setOracleAdapterForAsset(asset1, address(_mockAdapter));

        oracleWithMinPrice.validatePrice(asset1);
    }

    function test_getPrice_withMultipleAssets() public {
        uint256 price1 = 1000 * 1e27;
        uint256 price2 = 2000 * 1e27;
        uint256 price3 = 3000 * 1e27;

        MockPriceOracleAdapter adapter1 = new MockPriceOracleAdapter();
        MockPriceOracleAdapter adapter2 = new MockPriceOracleAdapter();
        MockPriceOracleAdapter adapter3 = new MockPriceOracleAdapter();

        adapter1.mockResponse(asset1, price1, false);
        adapter2.mockResponse(asset2, price2, false);
        // This one is stale
        adapter3.mockResponse(asset3, price3, true);

        vm.startPrank(everyRoleAccount);
        _priceOracle.setOracleAdapterForAsset(asset1, address(adapter1));
        _priceOracle.setOracleAdapterForAsset(asset2, address(adapter2));
        _priceOracle.setOracleAdapterForAsset(asset3, address(adapter3));
        vm.stopPrank();

        assertEq(_priceOracle.getPrice(asset1), MathLib.RAY, "Asset 1 price should be capped to RAY");
        assertEq(_priceOracle.getPrice(asset2), MathLib.RAY, "Asset 2 price should be capped to RAY");
        assertEq(_priceOracle.getPrice(asset3), 0, "Asset 3 should return 0 (stale)");
    }
}

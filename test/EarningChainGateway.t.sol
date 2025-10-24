// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Test} from "forge-std/Test.sol";

import {EarningChainGateway} from "../src/earning/EarningChainGateway.sol";
import {IEarningChainGateway} from "../src/interfaces/IEarningChainGateway.sol";
import {AssetLib} from "../src/libraries/AssetLib.sol";
import {ErrorsLib} from "../src/libraries/ErrorsLib.sol";
import {MathLib} from "../src/libraries/MathLib.sol";
import {MockAllocator} from "./mocks/MockAllocator.sol";
import {MockAssetRegistry} from "./mocks/MockAssetRegistry.sol";
import {MockBridgeAdapter} from "./mocks/MockBridgeAdapter.sol";
import {IMockErc20} from "./mocks/MockErc20.sol";
import {MockIouTokenManager} from "./mocks/MockIouTokenManager.sol";
import {MockNonStandardErc20} from "./mocks/MockNonStandardErc20.sol";

contract EarningChainGatewayTest is Test {
    using MathLib for uint256;
    using AssetLib for uint256;

    uint256 internal ACCOUNTING_CHAIN_ID = 1;
    uint256 internal EARNING_CHAIN_ID = 2;

    address internal admin = makeAddr("admin");
    address internal manager = makeAddr("manager");

    IMockErc20 internal _mockAsset;
    MockAllocator internal _mockAllocator;
    MockBridgeAdapter internal _mockBridgeAdapter;
    MockIouTokenManager internal _mockIouTokenManager;
    MockAssetRegistry internal _mockAssetRegistry;

    IEarningChainGateway internal _earningChainGateway;

    function _deployEarningChainGateway(address iouTokenManager) internal returns (IEarningChainGateway) {
        return IEarningChainGateway(new EarningChainGateway(admin, EARNING_CHAIN_ID, iouTokenManager));
    }

    function setUp() public {
        _mockAsset = IMockErc20(address(new MockNonStandardErc20("Test USDT", "tUSDT", 6)));

        _mockIouTokenManager = new MockIouTokenManager();

        _mockAssetRegistry = new MockAssetRegistry();

        _mockAllocator = new MockAllocator();

        _mockBridgeAdapter = new MockBridgeAdapter();

        _earningChainGateway = _deployEarningChainGateway(address(_mockIouTokenManager));
    }

    function test_constructor_setsTheExpectedValues(
        address expectedAdmin,
        address expectedManager,
        uint256 expectedAccountingChainId,
        address expectedIouTokenManager
    ) public {
        vm.assume(expectedAdmin != address(0));
        vm.assume(expectedIouTokenManager != address(0));
        vm.assume(expectedAccountingChainId != 0);
        vm.assume(expectedManager != address(0));

        EarningChainGateway newEarningChainGateway =
            new EarningChainGateway(expectedAdmin, expectedAccountingChainId, expectedIouTokenManager);
        assertEq(newEarningChainGateway.getAdmin(), expectedAdmin);
        assertEq(newEarningChainGateway.getManager(), address(0));
        assertEq(newEarningChainGateway.getAccountingChainId(), expectedAccountingChainId);
        assertEq(newEarningChainGateway.getIouTokenManager(), expectedIouTokenManager);

        vm.prank(expectedAdmin);
        newEarningChainGateway.setManager(expectedManager);

        assertEq(newEarningChainGateway.getManager(), expectedManager);
    }

    function test_constructor_reverts_ifZeroAddressAsAdmin() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new EarningChainGateway(address(0), EARNING_CHAIN_ID, address(_mockIouTokenManager));
    }

    function test_constructor_reverts_ifZeroAddressAsIouTokenManager() public {
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        new EarningChainGateway(admin, EARNING_CHAIN_ID, address(0));
    }

    function test_constructor_reverts_ifZeroAddressAsManager() public {
        EarningChainGateway newEarningChainGateway =
            new EarningChainGateway(admin, EARNING_CHAIN_ID, address(_mockIouTokenManager));
        vm.prank(admin);
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        newEarningChainGateway.setManager(address(0));
    }

    function test_setter_reverts_ifZeroAddressAsManager() public {
        EarningChainGateway newEarningChainGateway =
            new EarningChainGateway(admin, EARNING_CHAIN_ID, address(_mockIouTokenManager));
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        vm.prank(admin);
        newEarningChainGateway.setManager(address(0));
    }

    function test_setter_reverts_ifZeroAddressAsAllocator() public {
        EarningChainGateway newEarningChainGateway =
            new EarningChainGateway(admin, EARNING_CHAIN_ID, address(_mockIouTokenManager));
        vm.expectRevert(ErrorsLib.ZeroAddress.selector);
        vm.prank(admin);
        newEarningChainGateway.setManager(address(0));
    }
}

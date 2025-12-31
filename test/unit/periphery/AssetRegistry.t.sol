// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {AssetRegistry} from "src/periphery/AssetRegistry.sol";
import {Constants} from "src/types/Constants.sol";
import {Errors} from "src/types/Errors.sol";

import {TestWithHelpers} from "test/helpers/TestWithHelpers.sol";
import {MockAccessManager} from "test/mocks/MockAccessManager.sol";
import {IMockErc20} from "test/mocks/MockErc20.sol";
import {MockNonStandardErc20} from "test/mocks/MockNonStandardErc20.sol";

contract AssetRegistryTest is TestWithHelpers {
    AssetRegistry internal _assetRegistry;
    MockAccessManager internal _mockAccessManager;

    address admin = makeAddr("ADMIN");
    address everyRoleAccount = makeAddr("EVERY_ROLE_ACCOUNT");

    IMockErc20 internal _mockUsdt;
    IMockErc20 internal _mockGho;

    function _deployAssetRegistry(address accessManager) internal returns (AssetRegistry) {
        address assetRegistryImpl = address(new AssetRegistry());
        return AssetRegistry(
            address(
                new TransparentUpgradeableProxy(
                    assetRegistryImpl, address(this), abi.encodeCall(AssetRegistry.initialize, (accessManager))
                )
            )
        );
    }

    function setUp() public {
        _mockAccessManager = new MockAccessManager(admin);
        _assetRegistry = _deployAssetRegistry(address(_mockAccessManager));
        _mockUsdt = IMockErc20(address(new MockNonStandardErc20("Test USDT", "tUSDT", 6)));
        _mockGho = IMockErc20(address(new MockNonStandardErc20("Test GHO", "tGHO", 18)));
    }

    function test_setAssetConfig_setsAssetConfig(
        bool depositFromUserAllowed,
        bool depositIntoAllocatorAllowed,
        bool swapInputTokenAllowed,
        bool swapOutputTokenAllowed
    ) public {
        IAssetRegistry.AssetConfig memory config = IAssetRegistry.AssetConfig({
            depositFromUserAllowed: depositFromUserAllowed,
            depositIntoAllocatorAllowed: depositIntoAllocatorAllowed,
            swapInputTokenAllowed: swapInputTokenAllowed,
            swapOutputTokenAllowed: swapOutputTokenAllowed
        });

        vm.expectEmit(true, true, true, true);
        emit IAssetRegistry.AssetConfigSet(address(_mockUsdt), config);
        vm.prank(everyRoleAccount);
        _assetRegistry.setAssetConfig(address(_mockUsdt), config);

        assertEq(_assetRegistry.isUserDepositAllowed(address(_mockUsdt)), depositFromUserAllowed);
        assertEq(_assetRegistry.isDepositToAllocatorAllowed(address(_mockUsdt)), depositIntoAllocatorAllowed);
        assertEq(_assetRegistry.isSwapInputAllowed(address(_mockUsdt)), swapInputTokenAllowed);
        assertEq(_assetRegistry.isSwapOutputAllowed(address(_mockUsdt)), swapOutputTokenAllowed);
        assertEq(_assetRegistry.isAssetRegistered(address(_mockUsdt)), true);

        address[] memory registeredAssets = _assetRegistry.getTrustedAssets();
        assertEq(registeredAssets.length, 1);
        assertEq(registeredAssets[0], address(_mockUsdt));

        vm.expectEmit(true, true, true, true);
        emit IAssetRegistry.AssetConfigSet(address(_mockGho), config);
        vm.prank(everyRoleAccount);
        _assetRegistry.setAssetConfig(address(_mockGho), config);

        assertEq(_assetRegistry.isUserDepositAllowed(address(_mockGho)), depositFromUserAllowed);
        assertEq(_assetRegistry.isDepositToAllocatorAllowed(address(_mockGho)), depositIntoAllocatorAllowed);
        assertEq(_assetRegistry.isSwapInputAllowed(address(_mockGho)), swapInputTokenAllowed);
        assertEq(_assetRegistry.isSwapOutputAllowed(address(_mockGho)), swapOutputTokenAllowed);
        assertEq(_assetRegistry.isAssetRegistered(address(_mockGho)), true);

        registeredAssets = _assetRegistry.getTrustedAssets();
        assertEq(registeredAssets.length, 2);
        assertEq(registeredAssets[0], address(_mockUsdt));
        assertEq(registeredAssets[1], address(_mockGho));
    }

    function test_setAssetConfig_ifAssetHasZeroDecimals() public {
        IMockErc20 _mockTokenWithZeroDecimals =
            IMockErc20(address(new MockNonStandardErc20("Test Zero Decimals Token", "tZERO", 0)));
        IAssetRegistry.AssetConfig memory config = IAssetRegistry.AssetConfig({
            depositFromUserAllowed: true,
            depositIntoAllocatorAllowed: true,
            swapInputTokenAllowed: true,
            swapOutputTokenAllowed: true
        });
        vm.prank(everyRoleAccount);
        _assetRegistry.setAssetConfig(address(_mockTokenWithZeroDecimals), config);
        assertEq(_assetRegistry.isUserDepositAllowed(address(_mockTokenWithZeroDecimals)), true);
        assertEq(_assetRegistry.isDepositToAllocatorAllowed(address(_mockTokenWithZeroDecimals)), true);
        assertEq(_assetRegistry.isSwapInputAllowed(address(_mockTokenWithZeroDecimals)), true);
        assertEq(_assetRegistry.isSwapOutputAllowed(address(_mockTokenWithZeroDecimals)), true);
    }

    function test_setAssetConfig_reverts_ifAttemptingToOverwriteAssetConfig() public {
        IAssetRegistry.AssetConfig memory config = IAssetRegistry.AssetConfig({
            depositFromUserAllowed: false,
            depositIntoAllocatorAllowed: false,
            swapInputTokenAllowed: false,
            swapOutputTokenAllowed: false
        });
        vm.prank(everyRoleAccount);
        _assetRegistry.setAssetConfig(address(_mockUsdt), config);

        assertEq(_assetRegistry.isUserDepositAllowed(address(_mockUsdt)), false);
        assertEq(_assetRegistry.isDepositToAllocatorAllowed(address(_mockUsdt)), false);
        assertEq(_assetRegistry.isSwapInputAllowed(address(_mockUsdt)), false);
        assertEq(_assetRegistry.isSwapOutputAllowed(address(_mockUsdt)), false);

        config.depositFromUserAllowed = true;
        config.depositIntoAllocatorAllowed = true;
        config.swapInputTokenAllowed = true;
        config.swapOutputTokenAllowed = true;
        vm.expectRevert(abi.encodeWithSelector(Errors.AddressAlreadyWhitelisted.selector, address(_mockUsdt)));
        vm.prank(everyRoleAccount);
        _assetRegistry.setAssetConfig(address(_mockUsdt), config);
        assertEq(_assetRegistry.isUserDepositAllowed(address(_mockUsdt)), false);
        assertEq(_assetRegistry.isDepositToAllocatorAllowed(address(_mockUsdt)), false);
        assertEq(_assetRegistry.isSwapInputAllowed(address(_mockUsdt)), false);
        assertEq(_assetRegistry.isSwapOutputAllowed(address(_mockUsdt)), false);
    }

    function test_setAssetConfig_reverts_ifAssetHasUnsupportedDecimals(uint8 decimals) public {
        vm.assume(decimals > Constants.MAX_SUPPORTED_ASSET_DECIMALS);
        IMockErc20 _mockTokenWithUnsupportedDecimals =
            IMockErc20(address(new MockNonStandardErc20("Test Unsupported Decimals Token", "tUNSUPPORTED", decimals)));
        IAssetRegistry.AssetConfig memory config = IAssetRegistry.AssetConfig({
            depositFromUserAllowed: true,
            depositIntoAllocatorAllowed: true,
            swapInputTokenAllowed: true,
            swapOutputTokenAllowed: true
        });
        vm.prank(everyRoleAccount);
        vm.expectRevert(
            abi.encodeWithSelector(Errors.InvalidAsset.selector, address(_mockTokenWithUnsupportedDecimals))
        );
        _assetRegistry.setAssetConfig(address(_mockTokenWithUnsupportedDecimals), config);
    }

    function test_setAssetConfig_reverts_ifUnauthorizedCaller(address unauthorizedCaller) public {
        vm.assume(unauthorizedCaller != everyRoleAccount);
        vm.assume(unauthorizedCaller != address(0));
        _assumeNotProxyAdmin(unauthorizedCaller, address(_assetRegistry));

        vm.mockCall(
            address(_mockAccessManager),
            abi.encodeWithSelector(
                IAccessManager.canCall.selector,
                unauthorizedCaller,
                address(_assetRegistry),
                bytes4(IAssetRegistry.setAssetConfig.selector)
            ),
            abi.encode(false)
        );

        IAssetRegistry.AssetConfig memory config = IAssetRegistry.AssetConfig({
            depositFromUserAllowed: true,
            depositIntoAllocatorAllowed: true,
            swapInputTokenAllowed: true,
            swapOutputTokenAllowed: true
        });

        vm.prank(unauthorizedCaller);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedCaller));
        _assetRegistry.setAssetConfig(address(_mockUsdt), config);
    }

    function test_disableUserDeposits_disablesUserDeposits() public {
        vm.prank(everyRoleAccount);
        _assetRegistry.setAssetConfig(
            address(_mockUsdt),
            IAssetRegistry.AssetConfig({
                depositFromUserAllowed: true,
                depositIntoAllocatorAllowed: true,
                swapInputTokenAllowed: true,
                swapOutputTokenAllowed: true
            })
        );

        vm.expectEmit(true, true, true, true);
        emit IAssetRegistry.AssetConfigSet(
            address(_mockUsdt),
            IAssetRegistry.AssetConfig({
                depositFromUserAllowed: false,
                depositIntoAllocatorAllowed: true,
                swapInputTokenAllowed: true,
                swapOutputTokenAllowed: true
            })
        );
        vm.prank(everyRoleAccount);
        _assetRegistry.disableUserDeposits(address(_mockUsdt));
        assertEq(_assetRegistry.isUserDepositAllowed(address(_mockUsdt)), false);
        assertEq(_assetRegistry.isDepositToAllocatorAllowed(address(_mockUsdt)), true);
    }

    function test_disableAllocatorDeposits_disablesAllocatorDeposits() public {
        vm.prank(everyRoleAccount);
        _assetRegistry.setAssetConfig(
            address(_mockUsdt),
            IAssetRegistry.AssetConfig({
                depositFromUserAllowed: true,
                depositIntoAllocatorAllowed: true,
                swapInputTokenAllowed: true,
                swapOutputTokenAllowed: true
            })
        );

        vm.expectEmit(true, true, true, true);
        emit IAssetRegistry.AssetConfigSet(
            address(_mockUsdt),
            IAssetRegistry.AssetConfig({
                depositFromUserAllowed: true,
                depositIntoAllocatorAllowed: false,
                swapInputTokenAllowed: true,
                swapOutputTokenAllowed: true
            })
        );
        vm.prank(everyRoleAccount);
        _assetRegistry.disableAllocatorDeposits(address(_mockUsdt));
        assertEq(_assetRegistry.isUserDepositAllowed(address(_mockUsdt)), true);
        assertEq(_assetRegistry.isDepositToAllocatorAllowed(address(_mockUsdt)), false);
    }

    function test_disableDeposits_withMulticall_disablesBothUserAndAllocatorDeposits() public {
        bytes memory disableUserDepositsData =
            abi.encodeWithSelector(IAssetRegistry.disableUserDeposits.selector, address(_mockUsdt));
        bytes memory disableAllocatorDepositsData =
            abi.encodeWithSelector(IAssetRegistry.disableAllocatorDeposits.selector, address(_mockUsdt));
        bytes[] memory data = new bytes[](2);
        data[0] = disableUserDepositsData;
        data[1] = disableAllocatorDepositsData;

        vm.prank(everyRoleAccount);
        _assetRegistry.setAssetConfig(
            address(_mockUsdt),
            IAssetRegistry.AssetConfig({
                depositFromUserAllowed: true,
                depositIntoAllocatorAllowed: true,
                swapInputTokenAllowed: true,
                swapOutputTokenAllowed: true
            })
        );

        vm.prank(everyRoleAccount);
        bytes[] memory results = _assetRegistry.multicall(data);
        assertEq(results.length, 2);
        assertEq(_assetRegistry.isUserDepositAllowed(address(_mockUsdt)), false);
        assertEq(_assetRegistry.isDepositToAllocatorAllowed(address(_mockUsdt)), false);
    }

    function test_disableUserDeposits_reverts_ifUserDepositsAreAlreadyDisabled() public {
        vm.prank(everyRoleAccount);
        _assetRegistry.setAssetConfig(
            address(_mockUsdt),
            IAssetRegistry.AssetConfig({
                depositFromUserAllowed: false,
                depositIntoAllocatorAllowed: false,
                swapInputTokenAllowed: true,
                swapOutputTokenAllowed: true
            })
        );

        vm.prank(everyRoleAccount);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.AlreadyDisabled.selector));
        _assetRegistry.disableUserDeposits(address(_mockUsdt));
    }

    function test_disableAllocatorDeposits_reverts_ifAlreadyDisabled() public {
        vm.prank(everyRoleAccount);
        _assetRegistry.setAssetConfig(
            address(_mockUsdt),
            IAssetRegistry.AssetConfig({
                depositFromUserAllowed: false,
                depositIntoAllocatorAllowed: false,
                swapInputTokenAllowed: false,
                swapOutputTokenAllowed: false
            })
        );
        vm.prank(everyRoleAccount);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.AlreadyDisabled.selector));
        _assetRegistry.disableAllocatorDeposits(address(_mockUsdt));
    }

    function test_disableSwapInput_disablesSwapInput() public {
        vm.prank(everyRoleAccount);
        _assetRegistry.setAssetConfig(
            address(_mockUsdt),
            IAssetRegistry.AssetConfig({
                depositFromUserAllowed: false,
                depositIntoAllocatorAllowed: false,
                swapInputTokenAllowed: true,
                swapOutputTokenAllowed: false
            })
        );

        vm.expectEmit(true, true, true, true);
        emit IAssetRegistry.AssetConfigSet(
            address(_mockUsdt),
            IAssetRegistry.AssetConfig({
                depositFromUserAllowed: false,
                depositIntoAllocatorAllowed: false,
                swapInputTokenAllowed: false,
                swapOutputTokenAllowed: false
            })
        );
        vm.prank(everyRoleAccount);
        _assetRegistry.disableSwapInput(address(_mockUsdt));
        assertEq(_assetRegistry.isSwapInputAllowed(address(_mockUsdt)), false);
    }

    function test_disableSwapInput_reverts_ifUnauthorizedCaller(address unauthorizedCaller) public {
        vm.assume(unauthorizedCaller != everyRoleAccount);
        vm.assume(unauthorizedCaller != address(0));
        _assumeNotProxyAdmin(unauthorizedCaller, address(_assetRegistry));

        vm.mockCall(
            address(_mockAccessManager),
            abi.encodeWithSelector(
                IAccessManager.canCall.selector,
                unauthorizedCaller,
                address(_assetRegistry),
                bytes4(IAssetRegistry.disableSwapInput.selector)
            ),
            abi.encode(false)
        );

        vm.prank(unauthorizedCaller);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedCaller));
        _assetRegistry.disableSwapInput(address(_mockUsdt));
    }

    function test_disableSwapInput_reverts_ifAssetIsNotRegistered(address asset) public {
        vm.assume(asset != address(_mockUsdt));
        vm.assume(asset != address(_mockGho));
        vm.assume(asset != address(0));

        vm.prank(everyRoleAccount);
        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedAsset.selector, asset));
        _assetRegistry.disableSwapInput(asset);
    }

    function test_disableSwapInput_reverts_ifAlreadyDisabled() public {
        vm.prank(everyRoleAccount);
        _assetRegistry.setAssetConfig(
            address(_mockUsdt),
            IAssetRegistry.AssetConfig({
                depositFromUserAllowed: false,
                depositIntoAllocatorAllowed: false,
                swapInputTokenAllowed: false,
                swapOutputTokenAllowed: false
            })
        );
        vm.prank(everyRoleAccount);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.AlreadyDisabled.selector));
        _assetRegistry.disableSwapInput(address(_mockUsdt));
    }

    function test_disableUserDeposits_reverts_ifUnauthorizedCaller(address unauthorizedCaller) public {
        vm.assume(unauthorizedCaller != everyRoleAccount);
        vm.assume(unauthorizedCaller != address(0));
        _assumeNotProxyAdmin(unauthorizedCaller, address(_assetRegistry));

        vm.mockCall(
            address(_mockAccessManager),
            abi.encodeWithSelector(
                IAccessManager.canCall.selector,
                unauthorizedCaller,
                address(_assetRegistry),
                bytes4(IAssetRegistry.disableUserDeposits.selector)
            ),
            abi.encode(false)
        );

        vm.prank(unauthorizedCaller);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedCaller));
        _assetRegistry.disableUserDeposits(address(_mockUsdt));
    }

    function test_disableAllocatorDeposits_reverts_ifUnauthorizedCaller(address unauthorizedCaller) public {
        vm.assume(unauthorizedCaller != everyRoleAccount);
        vm.assume(unauthorizedCaller != address(0));
        _assumeNotProxyAdmin(unauthorizedCaller, address(_assetRegistry));

        vm.mockCall(
            address(_mockAccessManager),
            abi.encodeWithSelector(
                IAccessManager.canCall.selector,
                unauthorizedCaller,
                address(_assetRegistry),
                bytes4(IAssetRegistry.disableAllocatorDeposits.selector)
            ),
            abi.encode(false)
        );

        vm.prank(unauthorizedCaller);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedCaller));
        _assetRegistry.disableAllocatorDeposits(address(_mockUsdt));
    }

    function test_disableUserDeposits_reverts_ifAssetIsNotRegistered(address asset) public {
        vm.assume(asset != address(_mockUsdt));
        vm.assume(asset != address(_mockGho));
        vm.assume(asset != address(0));

        vm.prank(everyRoleAccount);
        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedAsset.selector, asset));
        _assetRegistry.disableUserDeposits(asset);
    }

    function test_disableAllocatorDeposits_reverts_ifAssetIsNotRegistered(address asset) public {
        vm.assume(asset != address(_mockUsdt));
        vm.assume(asset != address(_mockGho));
        vm.assume(asset != address(0));

        vm.prank(everyRoleAccount);
        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedAsset.selector, asset));
        _assetRegistry.disableAllocatorDeposits(asset);
    }

    function test_disableSwapOutput_disablesSwapOutput() public {
        vm.prank(everyRoleAccount);
        _assetRegistry.setAssetConfig(
            address(_mockUsdt),
            IAssetRegistry.AssetConfig({
                depositFromUserAllowed: true,
                depositIntoAllocatorAllowed: true,
                swapInputTokenAllowed: true,
                swapOutputTokenAllowed: true
            })
        );

        vm.expectEmit(true, true, true, true);
        emit IAssetRegistry.AssetConfigSet(
            address(_mockUsdt),
            IAssetRegistry.AssetConfig({
                depositFromUserAllowed: true,
                depositIntoAllocatorAllowed: true,
                swapInputTokenAllowed: true,
                swapOutputTokenAllowed: false
            })
        );
        vm.prank(everyRoleAccount);
        _assetRegistry.disableSwapOutput(address(_mockUsdt));
        assertEq(_assetRegistry.isSwapOutputAllowed(address(_mockUsdt)), false);
    }

    function test_disableSwapOutput_reverts_ifUnauthorizedCaller(address unauthorizedCaller) public {
        vm.assume(unauthorizedCaller != everyRoleAccount);
        vm.assume(unauthorizedCaller != address(0));
        _assumeNotProxyAdmin(unauthorizedCaller, address(_assetRegistry));

        vm.mockCall(
            address(_mockAccessManager),
            abi.encodeWithSelector(
                IAccessManager.canCall.selector,
                unauthorizedCaller,
                address(_assetRegistry),
                bytes4(IAssetRegistry.disableSwapOutput.selector)
            ),
            abi.encode(false)
        );

        vm.prank(unauthorizedCaller);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedCaller));
        _assetRegistry.disableSwapOutput(address(_mockUsdt));
    }

    function test_disableSwapOutput_reverts_ifAssetIsNotRegistered(address asset) public {
        vm.assume(asset != address(_mockUsdt));
        vm.assume(asset != address(_mockGho));
        vm.assume(asset != address(0));

        vm.prank(everyRoleAccount);
        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedAsset.selector, asset));
        _assetRegistry.disableSwapOutput(asset);
    }

    function test_disableSwapOutput_reverts_ifAlreadyDisabled() public {
        vm.prank(everyRoleAccount);
        _assetRegistry.setAssetConfig(
            address(_mockUsdt),
            IAssetRegistry.AssetConfig({
                depositFromUserAllowed: false,
                depositIntoAllocatorAllowed: false,
                swapInputTokenAllowed: false,
                swapOutputTokenAllowed: false
            })
        );
        vm.prank(everyRoleAccount);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.AlreadyDisabled.selector));
        _assetRegistry.disableSwapOutput(address(_mockUsdt));
    }

    function test_enableUserDeposits_enablesUserDeposits() public {
        vm.prank(everyRoleAccount);
        _assetRegistry.setAssetConfig(
            address(_mockUsdt),
            IAssetRegistry.AssetConfig({
                depositFromUserAllowed: false,
                depositIntoAllocatorAllowed: false,
                swapInputTokenAllowed: false,
                swapOutputTokenAllowed: false
            })
        );

        vm.expectEmit(true, true, true, true);
        emit IAssetRegistry.AssetConfigSet(
            address(_mockUsdt),
            IAssetRegistry.AssetConfig({
                depositFromUserAllowed: true,
                depositIntoAllocatorAllowed: false,
                swapInputTokenAllowed: false,
                swapOutputTokenAllowed: false
            })
        );
        vm.prank(everyRoleAccount);
        _assetRegistry.enableUserDeposits(address(_mockUsdt));
        assertEq(_assetRegistry.isUserDepositAllowed(address(_mockUsdt)), true);
    }

    function test_enableUserDeposits_reverts_ifUnauthorizedCaller(address unauthorizedCaller) public {
        vm.assume(unauthorizedCaller != everyRoleAccount);
        vm.assume(unauthorizedCaller != address(0));
        _assumeNotProxyAdmin(unauthorizedCaller, address(_assetRegistry));

        vm.mockCall(
            address(_mockAccessManager),
            abi.encodeWithSelector(
                IAccessManager.canCall.selector,
                unauthorizedCaller,
                address(_assetRegistry),
                bytes4(IAssetRegistry.enableUserDeposits.selector)
            ),
            abi.encode(false)
        );

        vm.prank(unauthorizedCaller);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedCaller));
        _assetRegistry.enableUserDeposits(address(_mockUsdt));
    }

    function test_enableUserDeposits_reverts_ifAssetIsNotRegistered(address asset) public {
        vm.assume(asset != address(_mockUsdt));
        vm.assume(asset != address(_mockGho));
        vm.assume(asset != address(0));

        vm.prank(everyRoleAccount);
        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedAsset.selector, asset));
        _assetRegistry.enableUserDeposits(asset);
    }

    function test_enableUserDeposits_reverts_ifAlreadyEnabled() public {
        vm.prank(everyRoleAccount);
        _assetRegistry.setAssetConfig(
            address(_mockUsdt),
            IAssetRegistry.AssetConfig({
                depositFromUserAllowed: true,
                depositIntoAllocatorAllowed: false,
                swapInputTokenAllowed: false,
                swapOutputTokenAllowed: false
            })
        );
        vm.prank(everyRoleAccount);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.AlreadyEnabled.selector));
        _assetRegistry.enableUserDeposits(address(_mockUsdt));
    }

    function test_enableAllocatorDeposits_enablesAllocatorDeposits() public {
        vm.prank(everyRoleAccount);
        _assetRegistry.setAssetConfig(
            address(_mockUsdt),
            IAssetRegistry.AssetConfig({
                depositFromUserAllowed: false,
                depositIntoAllocatorAllowed: false,
                swapInputTokenAllowed: false,
                swapOutputTokenAllowed: false
            })
        );

        vm.expectEmit(true, true, true, true);
        emit IAssetRegistry.AssetConfigSet(
            address(_mockUsdt),
            IAssetRegistry.AssetConfig({
                depositFromUserAllowed: false,
                depositIntoAllocatorAllowed: true,
                swapInputTokenAllowed: false,
                swapOutputTokenAllowed: false
            })
        );
        vm.prank(everyRoleAccount);
        _assetRegistry.enableAllocatorDeposits(address(_mockUsdt));
        assertEq(_assetRegistry.isDepositToAllocatorAllowed(address(_mockUsdt)), true);
    }

    function test_enableAllocatorDeposits_reverts_ifUnauthorizedCaller(address unauthorizedCaller) public {
        vm.assume(unauthorizedCaller != everyRoleAccount);
        vm.assume(unauthorizedCaller != address(0));
        _assumeNotProxyAdmin(unauthorizedCaller, address(_assetRegistry));

        vm.mockCall(
            address(_mockAccessManager),
            abi.encodeWithSelector(
                IAccessManager.canCall.selector,
                unauthorizedCaller,
                address(_assetRegistry),
                bytes4(IAssetRegistry.enableAllocatorDeposits.selector)
            ),
            abi.encode(false)
        );

        vm.prank(unauthorizedCaller);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedCaller));
        _assetRegistry.enableAllocatorDeposits(address(_mockUsdt));
    }

    function test_enableAllocatorDeposits_reverts_ifAssetIsNotRegistered(address asset) public {
        vm.assume(asset != address(_mockUsdt));
        vm.assume(asset != address(_mockGho));
        vm.assume(asset != address(0));

        vm.prank(everyRoleAccount);
        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedAsset.selector, asset));
        _assetRegistry.enableAllocatorDeposits(asset);
    }

    function test_enableAllocatorDeposits_reverts_ifAlreadyEnabled() public {
        vm.prank(everyRoleAccount);
        _assetRegistry.setAssetConfig(
            address(_mockUsdt),
            IAssetRegistry.AssetConfig({
                depositFromUserAllowed: false,
                depositIntoAllocatorAllowed: true,
                swapInputTokenAllowed: false,
                swapOutputTokenAllowed: false
            })
        );
        vm.prank(everyRoleAccount);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.AlreadyEnabled.selector));
        _assetRegistry.enableAllocatorDeposits(address(_mockUsdt));
    }

    function test_enableSwapInput_enablesSwapInput() public {
        vm.prank(everyRoleAccount);
        _assetRegistry.setAssetConfig(
            address(_mockUsdt),
            IAssetRegistry.AssetConfig({
                depositFromUserAllowed: false,
                depositIntoAllocatorAllowed: false,
                swapInputTokenAllowed: false,
                swapOutputTokenAllowed: false
            })
        );

        vm.expectEmit(true, true, true, true);
        emit IAssetRegistry.AssetConfigSet(
            address(_mockUsdt),
            IAssetRegistry.AssetConfig({
                depositFromUserAllowed: false,
                depositIntoAllocatorAllowed: false,
                swapInputTokenAllowed: true,
                swapOutputTokenAllowed: false
            })
        );
        vm.prank(everyRoleAccount);
        _assetRegistry.enableSwapInput(address(_mockUsdt));
        assertEq(_assetRegistry.isSwapInputAllowed(address(_mockUsdt)), true);
    }

    function test_enableSwapInput_reverts_ifUnauthorizedCaller(address unauthorizedCaller) public {
        vm.assume(unauthorizedCaller != everyRoleAccount);
        vm.assume(unauthorizedCaller != address(0));
        _assumeNotProxyAdmin(unauthorizedCaller, address(_assetRegistry));

        vm.mockCall(
            address(_mockAccessManager),
            abi.encodeWithSelector(
                IAccessManager.canCall.selector,
                unauthorizedCaller,
                address(_assetRegistry),
                bytes4(IAssetRegistry.enableSwapInput.selector)
            ),
            abi.encode(false)
        );

        vm.prank(unauthorizedCaller);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedCaller));
        _assetRegistry.enableSwapInput(address(_mockUsdt));
    }

    function test_enableSwapInput_reverts_ifAssetIsNotRegistered(address asset) public {
        vm.assume(asset != address(_mockUsdt));
        vm.assume(asset != address(_mockGho));
        vm.assume(asset != address(0));

        vm.prank(everyRoleAccount);
        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedAsset.selector, asset));
        _assetRegistry.enableSwapInput(asset);
    }

    function test_enableSwapInput_reverts_ifAlreadyEnabled() public {
        vm.prank(everyRoleAccount);
        _assetRegistry.setAssetConfig(
            address(_mockUsdt),
            IAssetRegistry.AssetConfig({
                depositFromUserAllowed: false,
                depositIntoAllocatorAllowed: false,
                swapInputTokenAllowed: true,
                swapOutputTokenAllowed: false
            })
        );
        vm.prank(everyRoleAccount);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.AlreadyEnabled.selector));
        _assetRegistry.enableSwapInput(address(_mockUsdt));
    }

    function test_enableSwapOutput_enablesSwapOutput() public {
        vm.prank(everyRoleAccount);
        _assetRegistry.setAssetConfig(
            address(_mockUsdt),
            IAssetRegistry.AssetConfig({
                depositFromUserAllowed: false,
                depositIntoAllocatorAllowed: false,
                swapInputTokenAllowed: false,
                swapOutputTokenAllowed: false
            })
        );

        vm.expectEmit(true, true, true, true);
        emit IAssetRegistry.AssetConfigSet(
            address(_mockUsdt),
            IAssetRegistry.AssetConfig({
                depositFromUserAllowed: false,
                depositIntoAllocatorAllowed: false,
                swapInputTokenAllowed: false,
                swapOutputTokenAllowed: true
            })
        );
        vm.prank(everyRoleAccount);
        _assetRegistry.enableSwapOutput(address(_mockUsdt));
        assertEq(_assetRegistry.isSwapOutputAllowed(address(_mockUsdt)), true);
    }

    function test_enableSwapOutput_reverts_ifUnauthorizedCaller(address unauthorizedCaller) public {
        vm.assume(unauthorizedCaller != everyRoleAccount);
        vm.assume(unauthorizedCaller != address(0));
        _assumeNotProxyAdmin(unauthorizedCaller, address(_assetRegistry));

        vm.mockCall(
            address(_mockAccessManager),
            abi.encodeWithSelector(
                IAccessManager.canCall.selector,
                unauthorizedCaller,
                address(_assetRegistry),
                bytes4(IAssetRegistry.enableSwapOutput.selector)
            ),
            abi.encode(false)
        );

        vm.prank(unauthorizedCaller);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedCaller));
        _assetRegistry.enableSwapOutput(address(_mockUsdt));
    }

    function test_enableSwapOutput_reverts_ifAssetIsNotRegistered(address asset) public {
        vm.assume(asset != address(_mockUsdt));
        vm.assume(asset != address(_mockGho));
        vm.assume(asset != address(0));

        vm.prank(everyRoleAccount);
        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedAsset.selector, asset));
        _assetRegistry.enableSwapOutput(asset);
    }

    function test_enableSwapOutput_reverts_ifAlreadyEnabled() public {
        vm.prank(everyRoleAccount);
        _assetRegistry.setAssetConfig(
            address(_mockUsdt),
            IAssetRegistry.AssetConfig({
                depositFromUserAllowed: false,
                depositIntoAllocatorAllowed: false,
                swapInputTokenAllowed: false,
                swapOutputTokenAllowed: true
            })
        );
        vm.prank(everyRoleAccount);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.AlreadyEnabled.selector));
        _assetRegistry.enableSwapOutput(address(_mockUsdt));
    }
}

// SPDX-License-Identifier: MIT
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

    function test_getRegisteredAssets_returnsEmptyByDefault() public view {
        address[] memory assets = _assetRegistry.getRegisteredAssets();
        assertEq(assets.length, 0);
    }

    function test_getRegisteredAssets_growsWithRegistration() public {
        IAssetRegistry.AssetConfig memory config = IAssetRegistry.AssetConfig({
            depositFromUserAllowed: false,
            depositIntoAllocatorAllowed: false,
            swapInputTokenAllowed: false,
            swapOutputTokenAllowed: false
        });

        assertEq(_assetRegistry.getRegisteredAssets().length, 0);

        vm.prank(everyRoleAccount);
        _assetRegistry.setAssetConfig(address(_mockUsdt), config);

        address[] memory afterFirst = _assetRegistry.getRegisteredAssets();
        assertEq(afterFirst.length, 1);
        assertEq(afterFirst[0], address(_mockUsdt));

        vm.prank(everyRoleAccount);
        _assetRegistry.setAssetConfig(address(_mockGho), config);

        address[] memory afterSecond = _assetRegistry.getRegisteredAssets();
        assertEq(afterSecond.length, 2);
        assertEq(afterSecond[0], address(_mockUsdt));
        assertEq(afterSecond[1], address(_mockGho));
    }

    function test_getRegisteredAssets_includesDistrustedAssets() public {
        IAssetRegistry.AssetConfig memory config = IAssetRegistry.AssetConfig({
            depositFromUserAllowed: false,
            depositIntoAllocatorAllowed: false,
            swapInputTokenAllowed: false,
            swapOutputTokenAllowed: false
        });

        vm.prank(everyRoleAccount);
        _assetRegistry.setAssetConfig(address(_mockUsdt), config);
        vm.prank(everyRoleAccount);
        _assetRegistry.setAssetConfig(address(_mockGho), config);

        vm.prank(everyRoleAccount);
        _assetRegistry.distrustAsset(address(_mockUsdt));

        address[] memory trustedAssets = _assetRegistry.getTrustedAssets();
        assertEq(trustedAssets.length, 1);

        address[] memory allAssets = _assetRegistry.getRegisteredAssets();
        assertEq(allAssets.length, 2);
    }

    function test_getAssetConfig_returnsExpectedConfig(
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

        vm.prank(everyRoleAccount);
        _assetRegistry.setAssetConfig(address(_mockUsdt), config);

        IAssetRegistry.AssetConfig memory result = _assetRegistry.getAssetConfig(address(_mockUsdt));
        assertEq(result.depositFromUserAllowed, depositFromUserAllowed);
        assertEq(result.depositIntoAllocatorAllowed, depositIntoAllocatorAllowed);
        assertEq(result.swapInputTokenAllowed, swapInputTokenAllowed);
        assertEq(result.swapOutputTokenAllowed, swapOutputTokenAllowed);
    }

    function test_getAssetConfig_returnsDefaultForUnregisteredAsset(address asset) public view {
        vm.assume(asset != address(_mockUsdt) && asset != address(_mockGho));
        IAssetRegistry.AssetConfig memory result = _assetRegistry.getAssetConfig(asset);
        assertEq(result.depositFromUserAllowed, false);
        assertEq(result.depositIntoAllocatorAllowed, false);
        assertEq(result.swapInputTokenAllowed, false);
        assertEq(result.swapOutputTokenAllowed, false);
    }

    function test_getAssetConfig_reflectsConfigChanges() public {
        IAssetRegistry.AssetConfig memory config = IAssetRegistry.AssetConfig({
            depositFromUserAllowed: true,
            depositIntoAllocatorAllowed: true,
            swapInputTokenAllowed: true,
            swapOutputTokenAllowed: true
        });

        vm.prank(everyRoleAccount);
        _assetRegistry.setAssetConfig(address(_mockUsdt), config);

        assertTrue(_assetRegistry.getAssetConfig(address(_mockUsdt)).depositFromUserAllowed);

        vm.prank(everyRoleAccount);
        _assetRegistry.disableUserDeposits(address(_mockUsdt));

        assertFalse(_assetRegistry.getAssetConfig(address(_mockUsdt)).depositFromUserAllowed);
        assertTrue(_assetRegistry.getAssetConfig(address(_mockUsdt)).depositIntoAllocatorAllowed);
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
        // Asset is trusted by default from setAssetConfig
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

    function test_enableUserDeposits_reverts_ifAssetIsNotTrusted() public {
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

        // Distrust the asset
        vm.prank(everyRoleAccount);
        _assetRegistry.distrustAsset(address(_mockUsdt));

        // Attempt to enable user deposits while untrusted
        vm.prank(everyRoleAccount);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.AssetNotTrusted.selector, address(_mockUsdt)));
        _assetRegistry.enableUserDeposits(address(_mockUsdt));
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

    function test_enableSwapOutput_reverts_ifAssetIsNotTrusted() public {
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

        // Distrust the asset
        vm.prank(everyRoleAccount);
        _assetRegistry.distrustAsset(address(_mockUsdt));

        // Attempt to enable swap output while untrusted
        vm.prank(everyRoleAccount);
        vm.expectRevert(abi.encodeWithSelector(IAssetRegistry.AssetNotTrusted.selector, address(_mockUsdt)));
        _assetRegistry.enableSwapOutput(address(_mockUsdt));
    }

    function test_trustAsset_trustsAsset() public {
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
        _assetRegistry.distrustAsset(address(_mockUsdt));
        assertFalse(_assetRegistry.isAssetTrusted(address(_mockUsdt)));

        vm.expectEmit(true, true, true, true);
        emit IAssetRegistry.AssetTrusted(address(_mockUsdt));
        vm.prank(everyRoleAccount);
        _assetRegistry.trustAsset(address(_mockUsdt));

        assertTrue(_assetRegistry.isAssetTrusted(address(_mockUsdt)));
        address[] memory trustedAssets = _assetRegistry.getTrustedAssets();
        assertEq(trustedAssets.length, 1);
        assertEq(trustedAssets[0], address(_mockUsdt));
    }

    function test_trustAsset_reverts_ifUnauthorizedCaller(address unauthorizedCaller) public {
        vm.assume(unauthorizedCaller != everyRoleAccount);
        vm.assume(unauthorizedCaller != address(0));
        _assumeNotProxyAdmin(unauthorizedCaller, address(_assetRegistry));

        vm.mockCall(
            address(_mockAccessManager),
            abi.encodeWithSelector(
                IAccessManager.canCall.selector,
                unauthorizedCaller,
                address(_assetRegistry),
                bytes4(IAssetRegistry.trustAsset.selector)
            ),
            abi.encode(false)
        );

        vm.prank(unauthorizedCaller);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedCaller));
        _assetRegistry.trustAsset(address(_mockUsdt));
    }

    function test_trustAsset_reverts_ifAssetIsNotRegistered(address asset) public {
        vm.assume(asset != address(_mockUsdt));
        vm.assume(asset != address(_mockGho));
        vm.assume(asset != address(0));

        vm.prank(everyRoleAccount);
        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedAsset.selector, asset));
        _assetRegistry.trustAsset(asset);
    }

    function test_trustAsset_reverts_ifAlreadyTrusted() public {
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
        vm.expectRevert(abi.encodeWithSelector(Errors.AlreadyTrusted.selector));
        _assetRegistry.trustAsset(address(_mockUsdt));
    }

    function test_distrustAsset_distrustsAsset() public {
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
        emit IAssetRegistry.AssetDistrusted(address(_mockUsdt));
        vm.prank(everyRoleAccount);
        _assetRegistry.distrustAsset(address(_mockUsdt));

        assertFalse(_assetRegistry.isAssetTrusted(address(_mockUsdt)));
        address[] memory trustedAssets = _assetRegistry.getTrustedAssets();
        assertEq(trustedAssets.length, 0);
    }

    function test_distrustAsset_reverts_ifUnauthorizedCaller(address unauthorizedCaller) public {
        vm.assume(unauthorizedCaller != everyRoleAccount);
        vm.assume(unauthorizedCaller != address(0));
        _assumeNotProxyAdmin(unauthorizedCaller, address(_assetRegistry));

        vm.mockCall(
            address(_mockAccessManager),
            abi.encodeWithSelector(
                IAccessManager.canCall.selector,
                unauthorizedCaller,
                address(_assetRegistry),
                bytes4(IAssetRegistry.distrustAsset.selector)
            ),
            abi.encode(false)
        );

        vm.prank(unauthorizedCaller);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedCaller));
        _assetRegistry.distrustAsset(address(_mockUsdt));
    }

    function test_distrustAsset_reverts_ifAssetIsNotRegistered(address asset) public {
        vm.assume(asset != address(_mockUsdt));
        vm.assume(asset != address(_mockGho));
        vm.assume(asset != address(0));

        vm.prank(everyRoleAccount);
        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedAsset.selector, asset));
        _assetRegistry.distrustAsset(asset);
    }

    function test_distrustAsset_reverts_ifAlreadyDistrusted() public {
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
        _assetRegistry.distrustAsset(address(_mockUsdt));

        vm.prank(everyRoleAccount);
        vm.expectRevert(abi.encodeWithSelector(Errors.AlreadyDistrusted.selector));
        _assetRegistry.distrustAsset(address(_mockUsdt));
    }

    function test_distrustAsset_disablesUserDepositsAndSwapOutput() public {
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
        assertTrue(_assetRegistry.isUserDepositAllowed(address(_mockUsdt)));
        assertTrue(_assetRegistry.isSwapOutputAllowed(address(_mockUsdt)));

        // Distrust should disable user deposits and swap output as a side effect
        vm.expectEmit(true, true, true, true);
        emit IAssetRegistry.AssetDistrusted(address(_mockUsdt));
        vm.expectEmit(true, true, true, true);
        emit IAssetRegistry.AssetConfigSet(
            address(_mockUsdt),
            IAssetRegistry.AssetConfig({
                depositFromUserAllowed: false,
                depositIntoAllocatorAllowed: true,
                swapInputTokenAllowed: true,
                swapOutputTokenAllowed: false
            })
        );
        vm.prank(everyRoleAccount);
        _assetRegistry.distrustAsset(address(_mockUsdt));

        assertFalse(_assetRegistry.isUserDepositAllowed(address(_mockUsdt)));
        assertFalse(_assetRegistry.isSwapOutputAllowed(address(_mockUsdt)));
    }

    function test_distrustAsset_doesNotRevertWhenDepositsAndSwapOutputAlreadyDisabled() public {
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

        // Distrust should succeed even though user deposits and swap output are already disabled
        vm.prank(everyRoleAccount);
        _assetRegistry.distrustAsset(address(_mockUsdt));

        assertFalse(_assetRegistry.isAssetTrusted(address(_mockUsdt)));
        assertFalse(_assetRegistry.isUserDepositAllowed(address(_mockUsdt)));
        assertFalse(_assetRegistry.isSwapOutputAllowed(address(_mockUsdt)));
    }

    function test_distrustAsset_disablesSwapOutputOnly() public {
        vm.prank(everyRoleAccount);
        _assetRegistry.setAssetConfig(
            address(_mockUsdt),
            IAssetRegistry.AssetConfig({
                depositFromUserAllowed: false,
                depositIntoAllocatorAllowed: true,
                swapInputTokenAllowed: true,
                swapOutputTokenAllowed: true
            })
        );

        // Only swap output is enabled, distrust should still emit AssetConfigSet
        vm.expectEmit(true, true, true, true);
        emit IAssetRegistry.AssetDistrusted(address(_mockUsdt));
        vm.expectEmit(true, true, true, true);
        emit IAssetRegistry.AssetConfigSet(
            address(_mockUsdt),
            IAssetRegistry.AssetConfig({
                depositFromUserAllowed: false,
                depositIntoAllocatorAllowed: true,
                swapInputTokenAllowed: true,
                swapOutputTokenAllowed: false
            })
        );
        vm.prank(everyRoleAccount);
        _assetRegistry.distrustAsset(address(_mockUsdt));

        assertFalse(_assetRegistry.isSwapOutputAllowed(address(_mockUsdt)));
    }

    function test_trustAsset_doesNotReEnableUserDepositsOrSwapOutput() public {
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

        // Distrust (disables user deposits and swap output as side effect)
        vm.prank(everyRoleAccount);
        _assetRegistry.distrustAsset(address(_mockUsdt));
        assertFalse(_assetRegistry.isUserDepositAllowed(address(_mockUsdt)));
        assertFalse(_assetRegistry.isSwapOutputAllowed(address(_mockUsdt)));

        // Trust again - should NOT re-enable user deposits or swap output
        vm.prank(everyRoleAccount);
        _assetRegistry.trustAsset(address(_mockUsdt));
        assertTrue(_assetRegistry.isAssetTrusted(address(_mockUsdt)));
        // Both remain disabled, must be explicitly re-enabled
        assertFalse(_assetRegistry.isUserDepositAllowed(address(_mockUsdt)));
        assertFalse(_assetRegistry.isSwapOutputAllowed(address(_mockUsdt)));
    }

    function test_fullCycle_trustEnableDistrustTrustRequiresManualReEnable() public {
        // 1. Register asset (trusted by default, deposits and swap output enabled)
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
        assertTrue(_assetRegistry.isUserDepositAllowed(address(_mockUsdt)));
        assertTrue(_assetRegistry.isSwapOutputAllowed(address(_mockUsdt)));

        // 2. Distrust (auto-disables deposits and swap output)
        vm.prank(everyRoleAccount);
        _assetRegistry.distrustAsset(address(_mockUsdt));
        assertFalse(_assetRegistry.isUserDepositAllowed(address(_mockUsdt)));
        assertFalse(_assetRegistry.isSwapOutputAllowed(address(_mockUsdt)));

        // 3. Trust again
        vm.prank(everyRoleAccount);
        _assetRegistry.trustAsset(address(_mockUsdt));
        // Deposits and swap output still disabled
        assertFalse(_assetRegistry.isUserDepositAllowed(address(_mockUsdt)));
        assertFalse(_assetRegistry.isSwapOutputAllowed(address(_mockUsdt)));

        // 4. Manually re-enable deposits and swap output
        vm.prank(everyRoleAccount);
        _assetRegistry.enableUserDeposits(address(_mockUsdt));
        vm.prank(everyRoleAccount);
        _assetRegistry.enableSwapOutput(address(_mockUsdt));
        assertTrue(_assetRegistry.isUserDepositAllowed(address(_mockUsdt)));
        assertTrue(_assetRegistry.isSwapOutputAllowed(address(_mockUsdt)));
    }
}

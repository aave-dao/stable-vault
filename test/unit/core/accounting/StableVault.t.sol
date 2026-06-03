// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {
    ReentrancyGuardTransientUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {StableVault} from "src/core/accounting/StableVault.sol";
import {IFundsHandler} from "src/interfaces/IFundsHandler.sol";
import {IPolicyRegistry} from "src/interfaces/IPolicyRegistry.sol";
import {IPriceOracle} from "src/interfaces/IPriceOracle.sol";
import {IRescuableNative} from "src/interfaces/IRescuableNative.sol";
import {IRescuableToken} from "src/interfaces/IRescuableToken.sol";
import {IStableVault} from "src/interfaces/IStableVault.sol";
import {IWithdrawalExecutionPolicy} from "src/interfaces/IWithdrawalExecutionPolicy.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {PriceOracle} from "src/oracles/price/PriceOracle.sol";
import {PolicyRegistry} from "src/periphery/PolicyRegistry.sol";
import {WithdrawalExecutionPolicy} from "src/policies/WithdrawalExecutionPolicy.sol";
import {Constants} from "src/types/Constants.sol";
import {Errors} from "src/types/Errors.sol";

import {Vm} from "forge-std/Vm.sol";
import {TestWithHelpers} from "test/helpers/TestWithHelpers.sol";
import {_toAddressArray, _toUint256Array} from "test/helpers/TypeHelpers.sol";
import {MockAccessManager} from "test/mocks/MockAccessManager.sol";
import {MockAssetRegistry} from "test/mocks/MockAssetRegistry.sol";
import {MockErc20} from "test/mocks/MockErc20.sol";
import {IMockErc20} from "test/mocks/MockErc20.sol";
import {MockFundsHandler} from "test/mocks/MockFundsHandler.sol";
import {MockIouTokenManager} from "test/mocks/MockIouTokenManager.sol";
import {MockNonStandardErc20} from "test/mocks/MockNonStandardErc20.sol";
import {MockReentrantErc20} from "test/mocks/MockReentrantErc20.sol";
import {MockTransferHelper} from "test/mocks/MockTransferHelper.sol";
import {StableVaultHarness} from "test/mocks/StableVaultHarness.sol";

contract StableVaultTest is TestWithHelpers {
    using MathLib for uint256;
    using AssetLib for uint256;
    using SafeERC20 for IMockErc20;

    uint256 userSeed = 0;
    address admin = makeAddr("admin");
    address manager = makeAddr("manager");
    address treasury = makeAddr("treasury");

    uint256 internal constant DEFAULT_MAX_ACTIVE_SUB_VAULTS = 201;
    uint256 constant DEFAULT_PER_SECOND_RATE = 1000000001243680656318820313; // ~4% APY
    string internal constant TEST_VAULT_NAME = "Test Aave USD Stable Vault";
    string internal constant TEST_VAULT_SYMBOL = "test-ASV-USD";
    MockAccessManager mockAccessManager;
    IMockErc20 mockAsset;
    MockFundsHandler mockFundsHandler;
    MockErc20 mockIouToken;
    MockIouTokenManager mockIouTokenManager;
    MockAssetRegistry mockAssetRegistry;
    MockTransferHelper mockTransferHelper;
    WithdrawalExecutionPolicy mockWithdrawalExecutionPolicy;
    PolicyRegistry policyRegistry;
    PriceOracle mockPriceOracle;
    IStableVault stableVault;

    function _deployDefaultAsset() internal returns (IMockErc20) {
        return IMockErc20(address(new MockNonStandardErc20("Test USDT", "tUSDT", 6)));
    }

    function _deployStableVault(
        address accessManager,
        uint256 maxPerSecondRate,
        uint256 defaultSubVaultPerSecondRate,
        address iouTokenManager,
        address fundsHandler,
        address assetRegistry,
        address transferHelper,
        address priceOracleAddress,
        uint256 maxActiveSubVaults,
        address treasuryAddress,
        address policyRegistryAddress
    ) internal returns (IStableVault) {
        address vaultImpl = address(
            new StableVault(
                maxPerSecondRate,
                assetRegistry,
                iouTokenManager,
                fundsHandler,
                transferHelper,
                priceOracleAddress,
                maxActiveSubVaults,
                policyRegistryAddress
            )
        );
        return StableVault(
            address(
                new TransparentUpgradeableProxy(
                    vaultImpl,
                    address(this),
                    abi.encodeCall(
                        StableVault.initialize,
                        (
                            accessManager,
                            treasuryAddress,
                            defaultSubVaultPerSecondRate,
                            TEST_VAULT_NAME,
                            TEST_VAULT_SYMBOL
                        )
                    )
                )
            )
        );
    }

    function _deployStableVaultHarness(
        address accessManager,
        uint256 maxPerSecondRate,
        uint256 defaultSubVaultPerSecondRate,
        address iouTokenManager,
        address fundsHandler,
        address assetRegistry,
        address transferHelper,
        address priceOracleAddress,
        uint256 maxActiveSubVaults,
        address treasuryAddress,
        address policyRegistryAddress
    ) internal returns (StableVaultHarness) {
        address vaultImpl = address(
            new StableVaultHarness(
                maxPerSecondRate,
                assetRegistry,
                iouTokenManager,
                fundsHandler,
                transferHelper,
                priceOracleAddress,
                maxActiveSubVaults,
                policyRegistryAddress
            )
        );
        return StableVaultHarness(
            address(
                new TransparentUpgradeableProxy(
                    vaultImpl,
                    address(this),
                    abi.encodeCall(
                        StableVault.initialize,
                        (
                            accessManager,
                            treasuryAddress,
                            defaultSubVaultPerSecondRate,
                            TEST_VAULT_NAME,
                            TEST_VAULT_SYMBOL
                        )
                    )
                )
            )
        );
    }

    function _deployWithdrawalExecutionPolicy(address accessManager, address withdrawalExecutionPolicyApplier)
        internal
        returns (WithdrawalExecutionPolicy)
    {
        WithdrawalExecutionPolicy policy =
            new WithdrawalExecutionPolicy(accessManager, withdrawalExecutionPolicyApplier, 0, 1, 1);
        policy.raiseRedemptionCapacity(type(uint128).max - 1);
        policy.raiseRedemptionRefillRate(1e30);
        return policy;
    }

    function setUp() public {
        mockAccessManager = new MockAccessManager(admin);
        mockIouToken = new MockErc20("I Owe You Tokens", "IOU", 18);
        mockIouTokenManager = new MockIouTokenManager();
        mockIouTokenManager.mockIouToken(address(mockIouToken));
        mockAssetRegistry = new MockAssetRegistry();
        mockAsset = _deployDefaultAsset();
        mockTransferHelper = new MockTransferHelper();
        mockFundsHandler = new MockFundsHandler(address(mockTransferHelper));
        policyRegistry = new PolicyRegistry(address(mockAccessManager));

        mockPriceOracle = _deployPriceOracle(address(mockAccessManager), 9_995e23);
        // Mock price for the default asset (1 RAY = 1:1 price ratio)
        _mockAssetPrice(address(mockPriceOracle), address(mockAsset), MathLib.RAY);
        // Mock validatePrice to pass for any asset (tests may create additional assets)
        _mockValidatePriceForAll(address(mockPriceOracle));

        // Predict StableVault proxy address after the (non-upgradeable) WithdrawalExecutionPolicy and StableVault impl
        // deployments.
        uint256 deployerNonce = vm.getNonce(address(this));
        address expectedStableVaultProxy = vm.computeCreateAddress(address(this), deployerNonce + 2);

        mockWithdrawalExecutionPolicy =
            _deployWithdrawalExecutionPolicy(address(mockAccessManager), expectedStableVaultProxy);
        stableVault = _deployStableVault(
            address(mockAccessManager),
            DEFAULT_MAX_PER_SECOND_RATE,
            DEFAULT_PER_SECOND_RATE,
            address(mockIouTokenManager),
            address(mockFundsHandler),
            address(mockAssetRegistry),
            address(mockTransferHelper),
            address(mockPriceOracle),
            DEFAULT_MAX_ACTIVE_SUB_VAULTS,
            treasury,
            address(policyRegistry)
        );
        policyRegistry.setPolicy(
            keccak256(bytes("aave.stable-vault.StableVault.policy.withdrawal-execution")),
            address(mockWithdrawalExecutionPolicy)
        );
    }

    function test_constructor_setsTheExpectedValues(
        uint256 expectedMaxValidPerSecondRate,
        address expectedIouManager,
        address expectedFundsHandler
    ) public {
        vm.assume(expectedIouManager != address(0));
        vm.assume(expectedFundsHandler != address(0));
        vm.assume(expectedMaxValidPerSecondRate > MathLib.RAY);

        StableVault newStableVault = new StableVault(
            expectedMaxValidPerSecondRate,
            address(mockAssetRegistry),
            expectedIouManager,
            expectedFundsHandler,
            address(mockTransferHelper),
            address(mockPriceOracle),
            DEFAULT_MAX_ACTIVE_SUB_VAULTS,
            address(policyRegistry)
        );

        assertEq(newStableVault.getMaxValidPerSecondRate(), expectedMaxValidPerSecondRate);
    }

    function test_constructor_reverts_ifInvalidMaxValidPerSecondRate(uint256 invalidMaxValidPerSecondRate) public {
        vm.assume(invalidMaxValidPerSecondRate <= MathLib.RAY);

        vm.expectRevert(IStableVault.InvalidRate.selector);
        new StableVault(
            invalidMaxValidPerSecondRate,
            address(mockAssetRegistry),
            address(mockIouTokenManager),
            address(mockFundsHandler),
            address(mockTransferHelper),
            address(mockPriceOracle),
            DEFAULT_MAX_ACTIVE_SUB_VAULTS,
            address(policyRegistry)
        );
    }

    function test_constructor_reverts_ifInvalidTransferHelper() public {
        vm.expectRevert();
        new StableVault(
            DEFAULT_MAX_PER_SECOND_RATE,
            address(mockAssetRegistry),
            address(mockIouTokenManager),
            address(mockFundsHandler),
            address(0),
            address(mockPriceOracle),
            DEFAULT_MAX_ACTIVE_SUB_VAULTS,
            address(policyRegistry)
        );
    }

    function test_initialize_setsTheExpectedValues(
        bytes32 expectedAccessManagerSalt,
        address expectedTreasury,
        uint256 expectedDefaultSubVaultRate,
        address expectedAssetRegistry
    ) public {
        address expectedAccessManager = address(
            new MockAccessManager{salt: expectedAccessManagerSalt}(makeAddr("accessManager"))
        );
        vm.assume(expectedAssetRegistry != address(0));
        expectedDefaultSubVaultRate = _boundRate(expectedDefaultSubVaultRate);

        address stableVaultImpl = address(
            new StableVault(
                DEFAULT_MAX_PER_SECOND_RATE,
                address(mockAssetRegistry),
                address(mockIouTokenManager),
                address(mockFundsHandler),
                address(mockTransferHelper),
                address(mockPriceOracle),
                DEFAULT_MAX_ACTIVE_SUB_VAULTS,
                address(policyRegistry)
            )
        );

        StableVault newStableVault = StableVault(
            address(
                new TransparentUpgradeableProxy(
                    stableVaultImpl,
                    address(this),
                    abi.encodeCall(
                        StableVault.initialize,
                        (
                            expectedAccessManager,
                            expectedTreasury,
                            expectedDefaultSubVaultRate,
                            TEST_VAULT_NAME,
                            TEST_VAULT_SYMBOL
                        )
                    )
                )
            )
        );

        IStableVault.SubVaultData memory defaultSubVault = newStableVault.getDefaultSubVault();
        assertEq(defaultSubVault.perSecondRate, expectedDefaultSubVaultRate);
        assertEq(defaultSubVault.id, newStableVault.getSubVaultIdByRate(expectedDefaultSubVaultRate));
        assertEq(newStableVault.getTreasury(), expectedTreasury);
    }

    function test_initialize_reverts_ifInvalidDefaultSubVaultRate(uint256 invalidDefaultSubVaultRate) public {
        vm.assume(invalidDefaultSubVaultRate < MathLib.RAY || invalidDefaultSubVaultRate > DEFAULT_MAX_PER_SECOND_RATE);

        address stableVaultImpl = address(
            new StableVault(
                DEFAULT_MAX_PER_SECOND_RATE,
                address(mockAssetRegistry),
                address(mockIouTokenManager),
                address(mockFundsHandler),
                address(mockTransferHelper),
                address(mockPriceOracle),
                DEFAULT_MAX_ACTIVE_SUB_VAULTS,
                address(policyRegistry)
            )
        );

        vm.expectRevert(IStableVault.InvalidRate.selector);
        StableVault(
            address(
                new TransparentUpgradeableProxy(
                    stableVaultImpl,
                    address(this),
                    abi.encodeCall(
                        StableVault.initialize,
                        (
                            address(mockAccessManager),
                            treasury,
                            invalidDefaultSubVaultRate,
                            TEST_VAULT_NAME,
                            TEST_VAULT_SYMBOL
                        )
                    )
                )
            )
        );
    }

    /// @dev `decimals()` must return RAY_DECIMALS (27) so Etherscan and wallets display StableVault balances
    /// (which are denominated in RAY) with the correct decimal alignment.
    function test_decimals_returnsRayDecimals() public view {
        assertEq(stableVault.decimals(), Constants.RAY_DECIMALS);
        assertEq(stableVault.decimals(), 27);
    }

    /// @dev `name()` returns the value passed to the initializer, allowing each StableVault deployment
    /// (USD, EUR, etc.) to set its own ERC20 metadata for off-chain display.
    function test_name_returnsValuePassedToInitializer() public view {
        assertEq(stableVault.name(), TEST_VAULT_NAME);
    }

    /// @dev `symbol()` returns the value passed to the initializer.
    function test_symbol_returnsValuePassedToInitializer() public view {
        assertEq(stableVault.symbol(), TEST_VAULT_SYMBOL);
    }

    function test_initialize_setsCustomNameAndSymbol(string memory customName, string memory customSymbol) public {
        vm.assume(bytes(customName).length > 0);
        vm.assume(bytes(customSymbol).length > 0);

        address stableVaultImpl = address(
            new StableVault(
                DEFAULT_MAX_PER_SECOND_RATE,
                address(mockAssetRegistry),
                address(mockIouTokenManager),
                address(mockFundsHandler),
                address(mockTransferHelper),
                address(mockPriceOracle),
                DEFAULT_MAX_ACTIVE_SUB_VAULTS,
                address(policyRegistry)
            )
        );

        StableVault newStableVault = StableVault(
            address(
                new TransparentUpgradeableProxy(
                    stableVaultImpl,
                    address(this),
                    abi.encodeCall(
                        StableVault.initialize,
                        (address(mockAccessManager), treasury, DEFAULT_PER_SECOND_RATE, customName, customSymbol)
                    )
                )
            )
        );

        assertEq(newStableVault.name(), customName);
        assertEq(newStableVault.symbol(), customSymbol);
        assertEq(newStableVault.decimals(), Constants.RAY_DECIMALS);
    }

    function test_initialize_reverts_ifNameIsEmpty() public {
        address stableVaultImpl = address(
            new StableVault(
                DEFAULT_MAX_PER_SECOND_RATE,
                address(mockAssetRegistry),
                address(mockIouTokenManager),
                address(mockFundsHandler),
                address(mockTransferHelper),
                address(mockPriceOracle),
                DEFAULT_MAX_ACTIVE_SUB_VAULTS,
                address(policyRegistry)
            )
        );

        vm.expectRevert(Errors.InvalidParameter.selector);
        new TransparentUpgradeableProxy(
            stableVaultImpl,
            address(this),
            abi.encodeCall(
                StableVault.initialize,
                (address(mockAccessManager), treasury, DEFAULT_PER_SECOND_RATE, "", TEST_VAULT_SYMBOL)
            )
        );
    }

    function test_initialize_reverts_ifSymbolIsEmpty() public {
        address stableVaultImpl = address(
            new StableVault(
                DEFAULT_MAX_PER_SECOND_RATE,
                address(mockAssetRegistry),
                address(mockIouTokenManager),
                address(mockFundsHandler),
                address(mockTransferHelper),
                address(mockPriceOracle),
                DEFAULT_MAX_ACTIVE_SUB_VAULTS,
                address(policyRegistry)
            )
        );

        vm.expectRevert(Errors.InvalidParameter.selector);
        new TransparentUpgradeableProxy(
            stableVaultImpl,
            address(this),
            abi.encodeCall(
                StableVault.initialize,
                (address(mockAccessManager), treasury, DEFAULT_PER_SECOND_RATE, TEST_VAULT_NAME, "")
            )
        );
    }

    function test_deposit_firstUserDepositGoesToDefaultSubVault(address user, uint256 amount) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        amount = _boundAssetAmount(address(mockAsset), amount);

        IStableVault.SubVaultData memory userSubVault = stableVault.getUserSubVault(user);
        vm.assume(userSubVault.id == 0); // no prior deposits

        mockAsset.mint(user, amount);

        vm.prank(user);
        mockAsset.forceApprove(address(stableVault), amount);

        vm.prank(user);
        stableVault.deposit(user, address(mockAsset), amount, "");

        userSubVault = stableVault.getUserSubVault(user);
        assertNotEq(userSubVault.id, 0); // subVault assigned after deposit

        IStableVault.SubVaultData memory defaultSubVault = stableVault.getDefaultSubVault();
        assertEq(userSubVault.id, defaultSubVault.id);
        assertEq(userSubVault.perSecondRate, defaultSubVault.perSecondRate);

        assertEq(stableVault.getGlobalOriginalDepositAmount(), amount.assetDecimalsToRay(address(mockAsset)));
    }

    function test_deposit_goesToCurrentUserSubVaultIfUserAlreadyHasAPosition(
        address user,
        uint256 firstDepositAmount,
        uint256 secondDepositAmount,
        uint256 userRate
    ) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        firstDepositAmount = _boundAssetAmount(address(mockAsset), firstDepositAmount);
        secondDepositAmount = _boundAssetAmount(address(mockAsset), secondDepositAmount);
        // Assumes the sum of the two deposits does not exceed the max expected deposit amount
        vm.assume(
            _boundAssetAmount(address(mockAsset), firstDepositAmount + secondDepositAmount)
                == firstDepositAmount + secondDepositAmount
        );
        userRate = _boundRate(userRate);

        mockAsset.mint(user, firstDepositAmount + secondDepositAmount);

        vm.assume(userRate != stableVault.getDefaultSubVault().perSecondRate);
        vm.assume(stableVault.getUserSubVault(user).id == 0); // no prior deposits

        vm.prank(user);
        mockAsset.forceApprove(address(stableVault), firstDepositAmount);

        vm.prank(user);
        stableVault.deposit(user, address(mockAsset), firstDepositAmount, "");

        assertEq(stableVault.getUserSubVault(user).id, stableVault.getDefaultSubVault().id);

        vm.prank(manager);
        _setUserRate(user, userRate);

        IStableVault.SubVaultData memory userVaultBeforeSecondDeposit = stableVault.getUserSubVault(user);
        assertNotEq(userVaultBeforeSecondDeposit.id, stableVault.getDefaultSubVault().id);

        vm.prank(user);
        mockAsset.forceApprove(address(stableVault), secondDepositAmount);

        vm.prank(user);
        stableVault.deposit(user, address(mockAsset), secondDepositAmount, "");

        IStableVault.SubVaultData memory userVaultAfterSecondDeposit = stableVault.getUserSubVault(user);
        assertEq(userVaultBeforeSecondDeposit.id, userVaultAfterSecondDeposit.id);
        assertEq(userVaultBeforeSecondDeposit.perSecondRate, userVaultAfterSecondDeposit.perSecondRate);

        assertEq(
            stableVault.getGlobalOriginalDepositAmount(),
            (firstDepositAmount + secondDepositAmount).assetDecimalsToRay(address(mockAsset))
        );
    }

    function test_deposit_reverts_ifAmountIsZero(address user) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));

        vm.prank(user);
        vm.expectRevert(Errors.InvalidAmount.selector);
        stableVault.deposit(user, address(mockAsset), 0, "");
    }

    function test_deposit_reverts_ifAssetIsNotAllowedToDepositIntoStableVault(
        address msgSender,
        address user,
        uint256 amount
    ) public {
        vm.assume(msgSender != address(0));
        _assumeNotProxyAdmin(msgSender, address(stableVault));
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        vm.assume(msgSender != user);

        amount = _boundAssetAmount(address(mockAsset), amount);
        mockAsset.mint(user, amount);

        vm.prank(user);
        mockAsset.forceApprove(address(stableVault), amount);

        mockAssetRegistry.mockToDisallowAssetDepositsIntoStableVault(address(mockAsset));

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedAsset.selector, address(mockAsset)));
        stableVault.deposit(user, address(mockAsset), amount, "");
    }

    function test_deposit_reverts_ifUserGetsZeroShares() public {
        // The system will not allow tokens with more than 18 decimals (enforced in AssetRegistry).
        // However, we use a 27-decimal token to trigger the edge case of getting 0 shares on deposit and test that
        // the system would revert to not allow it.
        address user = makeAddr("testUser");

        // After just 1 second with 20% APY, conversionRate > RAY, so:
        // shares = floor(1 * RAY / conversionRate) = floor(RAY / conversionRate) = 0
        MockErc20 highDecimalToken = new MockErc20("HighDecimal", "HD27", 27);

        uint256 twentyPercentApy = 1000000005781378656804591713; // ~20% APY
        IStableVault vault = _deployStableVault(
            address(mockAccessManager),
            twentyPercentApy + 1,
            twentyPercentApy,
            address(mockIouTokenManager),
            address(mockFundsHandler),
            address(mockAssetRegistry),
            address(mockTransferHelper),
            address(mockPriceOracle),
            DEFAULT_MAX_ACTIVE_SUB_VAULTS,
            treasury,
            address(policyRegistry)
        );

        // Warp just 1 second, conversionRate grows slightly above RAY
        vm.warp(block.timestamp + 1);

        uint256 expectedConversionRate = MathLib.RAY.rayMulDown(twentyPercentApy.rpow(1));

        uint256 depositAmount = 1;
        uint256 amountInRay = depositAmount.assetDecimalsToRay(address(highDecimalToken));

        // Verify that shares will be 0
        // shares = floor(1 * RAY / conversionRate) = floor(1e27 / 1.0000000057...e27) = 0
        uint256 expectedShares = amountInRay.rayDivDown(expectedConversionRate);
        assertEq(expectedShares, 0);

        highDecimalToken.mint(user, depositAmount);
        vm.prank(user);
        highDecimalToken.approve(address(vault), depositAmount);

        vm.prank(user);
        vm.expectRevert(Errors.InvalidAmount.selector);
        vault.deposit(user, address(highDecimalToken), depositAmount, "");
    }

    function test_deposit_reverts_ifPriceOracleRejectsPrice(uint256 amount) public {
        address user = makeAddr("testUser");
        _mockPriceTooLow(address(mockPriceOracle), address(mockAsset));
        amount = _boundAssetAmount(address(mockAsset), amount);

        mockAsset.mint(user, amount);
        vm.prank(user);
        mockAsset.forceApprove(address(stableVault), amount);
        vm.prank(user);
        vm.expectRevert(IPriceOracle.PriceTooLow.selector);
        stableVault.deposit(user, address(mockAsset), amount, "");
    }

    function test_deposit_allowsToDepositOnBehalfOfOtherUser(address user, address msgSender, uint256 amount) public {
        vm.assume(user != address(0));
        vm.assume(msgSender != address(0));
        vm.assume(user != address(mockFundsHandler));
        vm.assume(msgSender != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        _assumeNotProxyAdmin(msgSender, address(stableVault));
        amount = _boundAssetAmount(address(mockAsset), amount);

        vm.assume(stableVault.getUserBalance(user) == 0);
        vm.assume(stableVault.getUserBalance(msgSender) == 0);

        mockAsset.mint(msgSender, amount);
        vm.prank(msgSender);
        mockAsset.forceApprove(address(stableVault), amount);

        vm.assume(mockAsset.balanceOf(user) == 0);
        vm.assume(mockAsset.balanceOf(msgSender) == amount);

        vm.prank(msgSender);
        stableVault.deposit(user, address(mockAsset), amount, "");

        assertTrue(stableVault.getUserBalance(user) > 0);
        assertTrue(stableVault.getUserBalance(msgSender) == 0);

        vm.assume(mockAsset.balanceOf(user) == 0);
        vm.assume(mockAsset.balanceOf(msgSender) == 0);
    }

    function test_deposit_callsFundsHandlerToProcessDepositWithExpectedParams(address user, uint256 amount) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        amount = _boundAssetAmount(address(mockAsset), amount);

        mockAsset.mint(user, amount);

        vm.prank(user);
        mockAsset.forceApprove(address(stableVault), amount);

        vm.expectCall(
            address(mockFundsHandler),
            abi.encodeWithSelector(IFundsHandler.processDeposit.selector, address(mockAsset), amount)
        );

        vm.prank(user);
        stableVault.deposit(user, address(mockAsset), amount, "");
    }

    function test_deposit_queriesRegistryWithDepositPolicyId(address user, uint256 amount) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        amount = _boundAssetAmount(address(mockAsset), amount);

        mockAsset.mint(user, amount);

        vm.prank(user);
        mockAsset.forceApprove(address(stableVault), amount);

        vm.expectCall(
            address(policyRegistry),
            abi.encodeCall(IPolicyRegistry.getPolicy, keccak256("aave.stable-vault.StableVault.policy.deposit"))
        );

        vm.prank(user);
        stableVault.deposit(user, address(mockAsset), amount, "");
    }

    function test_deposit_emitsTransferMintEvent() public {
        address user = makeAddr("user");
        _assumeNotProxyAdmin(user, address(stableVault));

        uint256 amount = 2_000_000;
        uint256 amountRay = amount.assetDecimalsToRay(address(mockAsset));
        mockAsset.mint(user, amount);

        vm.prank(user);
        mockAsset.forceApprove(address(stableVault), amount);

        vm.expectEmit(true, true, true, true);
        emit IStableVault.Deposit(user, address(mockAsset), amount);
        vm.expectEmit(true, true, true, true);
        emit IStableVault.Transfer(address(0), user, amountRay);

        vm.prank(user);
        stableVault.deposit(user, address(mockAsset), amount, "");
    }

    function test_deposit_emitsSubVaultActivated_onFirstDeposit() public {
        address user = makeAddr("activationUser");
        _assumeNotProxyAdmin(user, address(stableVault));

        uint256 amount = 2_000_000;
        mockAsset.mint(user, amount);

        vm.prank(user);
        mockAsset.forceApprove(address(stableVault), amount);

        IStableVault.SubVaultData memory defaultSubVault = stableVault.getDefaultSubVault();

        // SubVaultActivated has 1 indexed param: subVaultId
        vm.expectEmit(true, false, false, true);
        emit IStableVault.SubVaultActivated(defaultSubVault.id);

        vm.prank(user);
        stableVault.deposit(user, address(mockAsset), amount, "");
    }

    function test_transfer_emitsSubVaultDeactivated_whenSubVaultBecomesEmpty() public {
        address user = makeAddr("deactivationUser");
        address recipient = makeAddr("deactivationRecipient");
        uint256 depositAmount = _boundAssetAmount(address(mockAsset), 1 ether);
        uint256 newPerSecondRate = _boundRate(DEFAULT_PER_SECOND_RATE + 1);
        vm.assume(newPerSecondRate != stableVault.getDefaultSubVault().perSecondRate);

        // Deposit and move user to a new subVault
        _deposit(user, depositAmount);
        _setUserRate(user, newPerSecondRate);

        uint256 userSubVaultId = stableVault.getUserSubVault(user).id;

        // Transfer all to recipient (who will be assigned to default subVault).
        // Since fromSubVaultId != toSubVaultId and user was the only occupant,
        // the user's subVault should become empty and SubVaultDeactivated should emit.
        vm.expectEmit(true, false, false, true);
        emit IStableVault.SubVaultDeactivated(userSubVaultId);

        vm.prank(user);
        stableVault.transferAll(recipient);
    }

    function test_deposit_emitsUserRateSet_onFirstDeposit() public {
        address user = makeAddr("userRateUser");
        _assumeNotProxyAdmin(user, address(stableVault));

        uint256 amount = 2_000_000;
        mockAsset.mint(user, amount * 2);

        IStableVault.SubVaultData memory defaultSubVault = stableVault.getDefaultSubVault();

        // First deposit: expect UserRateSet to fire
        vm.prank(user);
        mockAsset.forceApprove(address(stableVault), amount * 2);

        // UserRateSet has 2 indexed params: user, subVaultId
        vm.expectEmit(true, true, false, true);
        emit IStableVault.UserRateSet(user, defaultSubVault.id, defaultSubVault.perSecondRate);

        vm.prank(user);
        stableVault.deposit(user, address(mockAsset), amount, "");

        // Second deposit: UserRateSet should NOT fire (user already has a subVaultId)
        vm.recordLogs();
        vm.prank(user);
        stableVault.deposit(user, address(mockAsset), amount, "");

        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 userRateSetTopic = keccak256("UserRateSet(address,uint256,uint256)");
        bool foundUserRateSet = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics.length > 0 && logs[i].topics[0] == userRateSetTopic) {
                foundUserRateSet = true;
                break;
            }
        }
        assertFalse(foundUserRateSet, "UserRateSet should not emit on second deposit");
    }

    function test_setUserRate_skipsUserWithoutAPosition(address user, uint256 newPerSecondRate) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        vm.assume(stableVault.getUserSubVault(user).id == 0); // no prior deposits
        newPerSecondRate = _boundRate(newPerSecondRate);
        vm.assume(newPerSecondRate != stableVault.getDefaultSubVault().perSecondRate);

        vm.prank(manager);
        _setUserRate(user, DEFAULT_PER_SECOND_RATE);
    }

    function test_setUserRate_skipsUserAfterHeTransfersHisPosition() public {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");
        address user3 = makeAddr("user3");
        uint256 amount = _boundAssetAmount(address(mockAsset), 1 ether);
        uint256 newRate = _boundRate(DEFAULT_PER_SECOND_RATE + 1);
        vm.assume(newRate != stableVault.getDefaultSubVault().perSecondRate);

        // Both users deposit
        _deposit(user1, amount);
        _deposit(user2, amount);

        // user1 transfers their full position to user3, leaving user1 with no position
        vm.prank(user1);
        stableVault.transferAll(user3);

        assertEq(stableVault.getUserSubVault(user1).id, 0);

        // Batch setUserRate including user1 (no position) should not revert
        IStableVault.UserRateData[] memory userRateData = new IStableVault.UserRateData[](2);
        userRateData[0] = IStableVault.UserRateData(user1, newRate);
        userRateData[1] = IStableVault.UserRateData(user2, newRate);
        vm.prank(manager);
        stableVault.setUserRate(userRateData);

        // user2 should have been moved to the new rate
        assertEq(stableVault.getUserSubVault(user2).perSecondRate, newRate);
        // user1 should still have no position
        assertEq(stableVault.getUserSubVault(user1).id, 0);
    }

    function test_setUserRate_skipsUserAfterHeWithdrawsHisPosition() public {
        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");
        uint256 amount = _boundAssetAmount(address(mockAsset), 1 ether);
        uint256 newRate = _boundRate(DEFAULT_PER_SECOND_RATE + 1);
        vm.assume(newRate != stableVault.getDefaultSubVault().perSecondRate);

        // Both users deposit
        _deposit(user1, amount);
        _deposit(user2, amount);

        // user1 fully withdraws, leaving them with no position
        mockFundsHandler.mockAggregatedBalance(amount * 2);
        vm.prank(user1);
        stableVault.requestWithdrawal(user1, 0, "");

        assertEq(stableVault.getUserSubVault(user1).id, 0);

        // Batch setUserRate including user1 (no position) should not revert
        IStableVault.UserRateData[] memory userRateData = new IStableVault.UserRateData[](2);
        userRateData[0] = IStableVault.UserRateData(user1, newRate);
        userRateData[1] = IStableVault.UserRateData(user2, newRate);
        vm.prank(manager);
        stableVault.setUserRate(userRateData);

        // user2 should have been moved to the new rate
        assertEq(stableVault.getUserSubVault(user2).perSecondRate, newRate);
        // user1 should still have no position
        assertEq(stableVault.getUserSubVault(user1).id, 0);
    }

    function test_setUserRate_emitsSetUserRateSkipped_whenUserHasNoPosition() public {
        address user = makeAddr("noPositionUser");
        uint256 newRate = _boundRate(DEFAULT_PER_SECOND_RATE + 1);
        vm.assume(newRate != stableVault.getDefaultSubVault().perSecondRate);

        assertEq(stableVault.getUserSubVault(user).id, 0);

        IStableVault.UserRateData[] memory userRateData = new IStableVault.UserRateData[](1);
        userRateData[0] = IStableVault.UserRateData(user, newRate);

        vm.expectEmit(true, true, false, true);
        emit IStableVault.SetUserRateSkipped(user, 0, newRate);

        vm.prank(manager);
        stableVault.setUserRate(userRateData);

        assertEq(stableVault.getUserSubVault(user).id, 0, "user should still have no position");
    }

    function test_setUserRate_reverts_ifUserIsZeroAddress() public {
        vm.expectRevert(Errors.ZeroAddress.selector);
        vm.prank(manager);
        _setUserRate(address(0), DEFAULT_PER_SECOND_RATE);
    }

    function test_setUserRate_reverts_ifSettingTheSameRateHeAlreadyHas(address user, uint256 amount) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        amount = _boundAssetAmount(address(mockAsset), amount);

        mockAsset.mint(user, amount);

        vm.prank(user);
        mockAsset.forceApprove(address(stableVault), amount);

        vm.prank(user);
        stableVault.deposit(user, address(mockAsset), amount, "");

        uint256 currentRate = stableVault.getUserSubVault(user).perSecondRate;

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IStableVault.RedundantRate.selector, user, currentRate));
        _setUserRate(user, currentRate);
    }

    function test_setUserRate_reverts_ifMaxActiveSubVaultsIsReached_AtDeposit(uint256 maxActiveSubVaults) public {
        maxActiveSubVaults = bound(maxActiveSubVaults, 1, 20);
        stableVault = _deployStableVault(
            address(mockAccessManager),
            DEFAULT_MAX_PER_SECOND_RATE,
            DEFAULT_PER_SECOND_RATE,
            address(mockIouTokenManager),
            address(mockFundsHandler),
            address(mockAssetRegistry),
            address(mockTransferHelper),
            address(mockPriceOracle),
            maxActiveSubVaults,
            treasury,
            address(policyRegistry)
        );

        uint256 amountToDeposit = 10e6;
        uint256 i = 0;
        address user;
        while (i < maxActiveSubVaults) {
            user = _generateNewUser();
            _deposit(user, amountToDeposit);
            _setUserRate(user, DEFAULT_PER_SECOND_RATE + i + 1);
            i++;
        }

        user = _generateNewUser();
        mockAsset.mint(user, amountToDeposit);
        vm.prank(user);
        mockAsset.forceApprove(address(stableVault), amountToDeposit);
        vm.prank(user);

        assertEq(stableVault.getActiveSubVaults().length, maxActiveSubVaults);

        vm.expectRevert(IStableVault.TooManyActiveSubVaults.selector);
        stableVault.deposit(user, address(mockAsset), amountToDeposit, "");
    }

    function test_setUserRate_reverts_ifMaxActiveSubVaultsIsReached_AtSetUserRate(uint256 maxActiveSubVaults) public {
        maxActiveSubVaults = bound(maxActiveSubVaults, 1, 20);
        stableVault = _deployStableVault(
            address(mockAccessManager),
            DEFAULT_MAX_PER_SECOND_RATE,
            DEFAULT_PER_SECOND_RATE,
            address(mockIouTokenManager),
            address(mockFundsHandler),
            address(mockAssetRegistry),
            address(mockTransferHelper),
            address(mockPriceOracle),
            maxActiveSubVaults,
            treasury,
            address(policyRegistry)
        );

        uint256 amountToDeposit = 10e6;
        uint256 i = 0;
        address user;

        // Keep the first user in the default sub-vault
        user = _generateNewUser();
        _deposit(user, amountToDeposit);
        i++;

        assertEq(stableVault.getActiveSubVaults().length, 1);

        // Create the rest of active sub-vaults
        while (i < maxActiveSubVaults) {
            user = _generateNewUser();
            _deposit(user, amountToDeposit);
            _setUserRate(user, DEFAULT_PER_SECOND_RATE + i + 1);
            i++;
        }

        assertEq(stableVault.getActiveSubVaults().length, maxActiveSubVaults);

        user = _generateNewUser();
        // This deposit does not reach the cap, because it overlaps with the first user's position at default sub-vault
        _deposit(user, amountToDeposit);

        assertEq(stableVault.getActiveSubVaults().length, maxActiveSubVaults);

        vm.expectRevert(IStableVault.TooManyActiveSubVaults.selector);
        _setUserRate(user, DEFAULT_PER_SECOND_RATE + i + 1);
    }

    function test_setUserRate_batchMigration_succeedsWhenTransientlyOverLimit() public {
        // Deploy with maxActiveSubVaults = 2
        stableVault = _deployStableVault(
            address(mockAccessManager),
            DEFAULT_MAX_PER_SECOND_RATE,
            DEFAULT_PER_SECOND_RATE,
            address(mockIouTokenManager),
            address(mockFundsHandler),
            address(mockAssetRegistry),
            address(mockTransferHelper),
            address(mockPriceOracle),
            2, // MAX_ACTIVE_SUB_VAULTS
            treasury,
            address(policyRegistry)
        );

        // Users A, B and C all deposit into the default subvault (subvault 1).
        // A and B will co-locate in sub1 so that A's source sub-vault retains a user
        // during the over-limit iteration below.
        address userA = _generateNewUser();
        address userB = _generateNewUser();
        address userC = _generateNewUser();
        _deposit(userA, 10e6);
        _deposit(userB, 10e6);
        _deposit(userC, 10e6);

        assertEq(stableVault.getActiveSubVaults().length, 1);

        // Move User C alone to a new rate -> creates subvault 2, now at max (2 active).
        // Layout: sub1 (A, B), sub2 (C).
        uint256 newRate = DEFAULT_PER_SECOND_RATE + 1;
        _setUserRate(userC, newRate);
        assertEq(stableVault.getActiveSubVaults().length, 2);

        // Batch-migrate A and C to a third rate. With MAX = 2:
        //   Iter 1 (A, sub1 -> sub3): sub1 retains B -> NOT removed; sub3 added.
        //     Active = [sub1, sub2, sub3] (3 — transiently over the limit).
        //   Iter 2 (C, sub2 -> sub3): sub2 empties -> removed; sub3 already active.
        //     Active = [sub1, sub3] (2 — final state within the limit).
        // Before the fix, iter 1 reverted because _validateAmountOfActiveSubVaults()
        // ran inside _moveShares.
        uint256 thirdRate = DEFAULT_PER_SECOND_RATE + 2;
        IStableVault.UserRateData[] memory batch = new IStableVault.UserRateData[](2);
        batch[0] = IStableVault.UserRateData(userA, thirdRate);
        batch[1] = IStableVault.UserRateData(userC, thirdRate);
        stableVault.setUserRate(batch);

        // Final state: sub1 still has B, sub2 empty (deactivated), sub3 has A+C.
        assertEq(stableVault.getActiveSubVaults().length, 2);
    }

    function test_setUserRate_batchMigration_stillRevertsWhenFinalStateExceedsLimit() public {
        // Deploy with maxActiveSubVaults = 2
        stableVault = _deployStableVault(
            address(mockAccessManager),
            DEFAULT_MAX_PER_SECOND_RATE,
            DEFAULT_PER_SECOND_RATE,
            address(mockIouTokenManager),
            address(mockFundsHandler),
            address(mockAssetRegistry),
            address(mockTransferHelper),
            address(mockPriceOracle),
            2, // MAX_ACTIVE_SUB_VAULTS
            treasury,
            address(policyRegistry)
        );

        // 3 users deposit into default subvault
        address userA = _generateNewUser();
        address userB = _generateNewUser();
        address userC = _generateNewUser();
        _deposit(userA, 10e6);
        _deposit(userB, 10e6);
        _deposit(userC, 10e6);

        assertEq(stableVault.getActiveSubVaults().length, 1);

        // Move User A to rate 2 -> 2 active subvaults (at max)
        _setUserRate(userA, DEFAULT_PER_SECOND_RATE + 1);
        assertEq(stableVault.getActiveSubVaults().length, 2);

        // Batch: move User B to rate 3 and User C to rate 3.
        // After batch: subvault 1 still has no remaining users BUT User A is still in subvault 2.
        // Wait — User A is in subvault 2, Users B+C move to subvault 3.
        // Default subvault 1 still has... no one (all 3 moved out? No, only B and C were in subvault 1).
        // Final: subvault 1 empty (deactivated), subvault 2 has A (active), subvault 3 has B+C (active) = 2 active.
        // Fits.

        // Instead, let's create a scenario where the final state truly exceeds.
        // Move User B to rate 3 (creates subvault 3). Now: sub1 has C, sub2 has A, sub3 has B = 3 active.
        // This genuinely exceeds max=2 in final state.
        IStableVault.UserRateData[] memory batch = new IStableVault.UserRateData[](1);
        batch[0] = IStableVault.UserRateData(userB, DEFAULT_PER_SECOND_RATE + 2);
        vm.expectRevert(IStableVault.TooManyActiveSubVaults.selector);
        stableVault.setUserRate(batch);
    }

    function test_setUserRate_smallConversionRateToLargeConversionRate_skipsDustMigration() public {
        // Override stableVault with a low default sub-vault rate
        stableVault = _deployStableVault(
            address(mockAccessManager),
            DEFAULT_MAX_PER_SECOND_RATE,
            MathLib.RAY,
            address(mockIouTokenManager),
            address(mockFundsHandler),
            address(mockAssetRegistry),
            address(mockTransferHelper),
            address(mockPriceOracle),
            DEFAULT_MAX_ACTIVE_SUB_VAULTS,
            treasury,
            address(policyRegistry)
        );
        mockAsset = IMockErc20(address(new MockNonStandardErc20("Test GHO", "tGHO", 18)));

        uint256 newRate = 1000000005781378656804591713; // ~20% APY

        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");
        uint256 amount = 1;

        // Deposit from a user and move them into a new sub-vault to create the sub-vault
        mockAsset.mint(user1, amount);

        vm.prank(user1);
        mockAsset.forceApprove(address(stableVault), amount);

        vm.prank(user1);
        stableVault.deposit(user1, address(mockAsset), amount, "");

        IStableVault.UserRateData[] memory userRateData = new IStableVault.UserRateData[](1);
        userRateData[0] = IStableVault.UserRateData(user1, newRate);
        vm.prank(manager);
        stableVault.setUserRate(userRateData);

        // Warp a long time to allow the conversion rate of the new sub-vault to grow.
        vm.warp(block.timestamp + 115 * 365 days);

        // User 2 deposits and has their position migrated to the new sub-vault
        mockAsset.mint(user2, amount);
        vm.prank(user2);
        mockAsset.forceApprove(address(stableVault), amount);
        vm.prank(user2);
        stableVault.deposit(user2, address(mockAsset), amount, "");

        IStableVault.SubVaultData memory user2VaultBefore = stableVault.getUserSubVault(user2);

        uint256 newSubVaultId = stableVault.getUserSubVault(user1).id;

        vm.prank(manager);
        userRateData = new IStableVault.UserRateData[](1);
        userRateData[0] = IStableVault.UserRateData(user2, newRate);
        vm.expectEmit(true, true, false, true);
        emit IStableVault.SetUserRateSkipped(user2, newSubVaultId, newRate);

        // Migration is skipped instead of reverting when the user would end up with 0 shares in the new sub-vault.
        // The call succeeds and user2's position is left untouched.
        stableVault.setUserRate(userRateData);

        IStableVault.SubVaultData memory user2VaultAfter = stableVault.getUserSubVault(user2);
        assertEq(user2VaultAfter.id, user2VaultBefore.id, "user2 sub-vault should not change");
        assertEq(user2VaultAfter.perSecondRate, user2VaultBefore.perSecondRate, "user2 perSecondRate should not change");
    }

    function test_setUserRate_batch_skipsDustUserAndMigratesTheRest() public {
        // Override stableVault with a low default sub-vault rate so a dust position can be set up cheaply.
        stableVault = _deployStableVault(
            address(mockAccessManager),
            DEFAULT_MAX_PER_SECOND_RATE,
            MathLib.RAY,
            address(mockIouTokenManager),
            address(mockFundsHandler),
            address(mockAssetRegistry),
            address(mockTransferHelper),
            address(mockPriceOracle),
            DEFAULT_MAX_ACTIVE_SUB_VAULTS,
            treasury,
            address(policyRegistry)
        );
        mockAsset = IMockErc20(address(new MockNonStandardErc20("Test GHO", "tGHO", 18)));

        uint256 newRate = 1000000005781378656804591713; // ~20% APY

        address dustUser = makeAddr("dustUser");
        address normalUser = makeAddr("normalUser");
        address seeder = makeAddr("seeder");

        // Seed the target sub-vault and let its conversion rate grow so a dust position migrates to 0 shares.
        mockAsset.mint(seeder, 1);
        vm.prank(seeder);
        mockAsset.forceApprove(address(stableVault), 1);
        vm.prank(seeder);
        stableVault.deposit(seeder, address(mockAsset), 1, "");

        IStableVault.UserRateData[] memory seed = new IStableVault.UserRateData[](1);
        seed[0] = IStableVault.UserRateData(seeder, newRate);
        vm.prank(manager);
        stableVault.setUserRate(seed);

        vm.warp(block.timestamp + 115 * 365 days);

        // dustUser: 1 wei position that will round to 0 on migration to the high-rate sub-vault.
        mockAsset.mint(dustUser, 1);
        vm.prank(dustUser);
        mockAsset.forceApprove(address(stableVault), 1);
        vm.prank(dustUser);
        stableVault.deposit(dustUser, address(mockAsset), 1, "");

        // normalUser: large position that survives migration.
        uint256 normalAmount = _boundAssetAmount(address(mockAsset), 1_000e18);
        mockAsset.mint(normalUser, normalAmount);
        vm.prank(normalUser);
        mockAsset.forceApprove(address(stableVault), normalAmount);
        vm.prank(normalUser);
        stableVault.deposit(normalUser, address(mockAsset), normalAmount, "");

        IStableVault.SubVaultData memory dustVaultBefore = stableVault.getUserSubVault(dustUser);
        IStableVault.SubVaultData memory normalVaultBefore = stableVault.getUserSubVault(normalUser);

        IStableVault.UserRateData[] memory batch = new IStableVault.UserRateData[](2);
        batch[0] = IStableVault.UserRateData(dustUser, newRate);
        batch[1] = IStableVault.UserRateData(normalUser, newRate);

        uint256 newSubVaultId = stableVault.getUserSubVault(seeder).id;

        vm.expectEmit(true, true, false, true);
        emit IStableVault.SetUserRateSkipped(dustUser, newSubVaultId, newRate);

        vm.prank(manager);
        stableVault.setUserRate(batch);

        IStableVault.SubVaultData memory dustVaultAfter = stableVault.getUserSubVault(dustUser);
        IStableVault.SubVaultData memory normalVaultAfter = stableVault.getUserSubVault(normalUser);

        // dustUser was skipped.
        assertEq(dustVaultAfter.id, dustVaultBefore.id, "dustUser sub-vault should not change");
        assertEq(
            dustVaultAfter.perSecondRate, dustVaultBefore.perSecondRate, "dustUser perSecondRate should not change"
        );

        // normalUser was migrated.
        assertTrue(normalVaultAfter.id != normalVaultBefore.id, "normalUser should have migrated sub-vaults");
        assertEq(normalVaultAfter.perSecondRate, newRate, "normalUser perSecondRate should match target");
    }

    function test_setUserRate_batch_duplicateUser_appliesEntriesSequentially() public {
        // The batch loop does not dedupe by user address: each entry is processed independently against
        // whatever sub-vault the user is in at that moment. This locks in that behavior so a future
        // change that adds deduping or rejects duplicates is caught.
        address user = makeAddr("dupUser");
        uint256 firstRate = _boundRate(DEFAULT_PER_SECOND_RATE + 1);
        uint256 secondRate = _boundRate(DEFAULT_PER_SECOND_RATE + 2);
        vm.assume(firstRate != stableVault.getDefaultSubVault().perSecondRate);
        vm.assume(secondRate != stableVault.getDefaultSubVault().perSecondRate);
        vm.assume(firstRate != secondRate);

        uint256 amount = _boundAssetAmount(address(mockAsset), 1 ether);
        _deposit(user, amount);

        IStableVault.UserRateData[] memory batch = new IStableVault.UserRateData[](2);
        batch[0] = IStableVault.UserRateData(user, firstRate);
        batch[1] = IStableVault.UserRateData(user, secondRate);

        vm.recordLogs();
        vm.prank(manager);
        stableVault.setUserRate(batch);

        // Both entries should have emitted UserRateSet for the same user.
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 userRateSetTopic = keccak256("UserRateSet(address,uint256,uint256)");
        uint256 userRateSetCountForUser = 0;
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].topics.length > 1 && logs[i].topics[0] == userRateSetTopic
                    && logs[i].topics[1] == bytes32(uint256(uint160(user)))
            ) {
                userRateSetCountForUser++;
            }
        }
        assertEq(userRateSetCountForUser, 2, "both duplicate entries should emit UserRateSet for the user");
        assertEq(stableVault.getUserSubVault(user).perSecondRate, secondRate, "user should end at secondRate");
    }

    function test_setUserRate_twoUsersWithSameRateLandsInTheSameSubVault(
        address user1,
        address user2,
        uint256 amount1,
        uint256 amount2,
        uint256 newRate
    ) public {
        vm.assume(user1 != address(0));
        _assumeNotProxyAdmin(user1, address(stableVault));
        vm.assume(user2 != address(0));
        _assumeNotProxyAdmin(user2, address(stableVault));
        vm.assume(user1 != user2);
        amount1 = _boundAssetAmount(address(mockAsset), amount1);
        amount2 = _boundAssetAmount(address(mockAsset), amount2);
        newRate = _boundRate(newRate);
        vm.assume(newRate != stableVault.getDefaultSubVault().perSecondRate);

        mockAsset.mint(user1, amount1);
        mockAsset.mint(user2, amount2);

        vm.prank(user1);
        mockAsset.forceApprove(address(stableVault), amount1);
        vm.prank(user1);
        stableVault.deposit(user1, address(mockAsset), amount1, "");

        vm.prank(manager);
        _setUserRate(user1, newRate);

        IStableVault.SubVaultData memory user1SubVault = stableVault.getUserSubVault(user1);

        vm.prank(user2);
        mockAsset.forceApprove(address(stableVault), amount2);
        vm.prank(user2);
        stableVault.deposit(user2, address(mockAsset), amount2, "");

        IStableVault.SubVaultData memory user2SubVault = stableVault.getUserSubVault(user2);

        // SubVaults are not the same because user2 is still at the default subVault
        assertNotEq(user2SubVault.id, user1SubVault.id);
        assertNotEq(user2SubVault.perSecondRate, newRate);

        vm.prank(manager);
        _setUserRate(user2, newRate);

        // SubVaults must match after setting the same new rate as user1 for user2
        user2SubVault = stableVault.getUserSubVault(user2);
        assertEq(user2SubVault.id, user1SubVault.id);
        assertEq(user2SubVault.perSecondRate, newRate);
    }

    function test_setDefaultSubVault_setsExistingVaultIfAlreadyExistsWithGivenRate(
        address user,
        uint256 amount,
        uint256 newPerSecondRate
    ) public {
        newPerSecondRate = _boundRate(newPerSecondRate);
        vm.assume(stableVault.getDefaultSubVault().perSecondRate != newPerSecondRate);

        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        amount = _boundAssetAmount(address(mockAsset), amount);
        mockAsset.mint(user, amount);
        vm.prank(user);
        mockAsset.forceApprove(address(stableVault), amount);
        vm.prank(user);
        stableVault.deposit(user, address(mockAsset), amount, "");

        vm.prank(manager);
        _setUserRate(user, newPerSecondRate);
        uint256 expectedSubVaultId = stableVault.getSubVaultIdByRate(newPerSecondRate);

        vm.prank(manager);
        stableVault.setDefaultSubVault(newPerSecondRate);

        assertEq(stableVault.getDefaultSubVault().perSecondRate, newPerSecondRate);
        assertEq(stableVault.getSubVaultIdByRate(newPerSecondRate), expectedSubVaultId);
        assertEq(stableVault.getSubVaultRateById(expectedSubVaultId), newPerSecondRate);
    }

    function test_setDefaultSubVault_settingToSameRateAsCurrentDefaultSubVaultIsAllowedAndDoesNothing(uint256 newPerSecondRate)
        public
    {
        newPerSecondRate = _boundRate(newPerSecondRate);

        vm.prank(manager);
        stableVault.setDefaultSubVault(newPerSecondRate);

        assertEq(stableVault.getDefaultSubVault().perSecondRate, newPerSecondRate);
        assertEq(stableVault.getSubVaultIdByRate(newPerSecondRate), stableVault.getDefaultSubVault().id);
        assertEq(stableVault.getSubVaultRateById(stableVault.getDefaultSubVault().id), newPerSecondRate);

        uint256 sameDefaultSubVaultId = stableVault.getDefaultSubVault().id;

        vm.prank(manager);
        stableVault.setDefaultSubVault(newPerSecondRate);

        assertEq(stableVault.getDefaultSubVault().perSecondRate, newPerSecondRate);
        assertEq(stableVault.getSubVaultIdByRate(newPerSecondRate), sameDefaultSubVaultId);
        assertEq(stableVault.getSubVaultRateById(sameDefaultSubVaultId), newPerSecondRate);
    }

    function test_setDefaultSubVault_createsANewSubVaultIfNoSubVaultHasTheGivenRate(
        uint256 newPerSecondRate,
        uint256 anotherNewPerSecondRate
    ) public {
        newPerSecondRate = _boundRate(newPerSecondRate);
        anotherNewPerSecondRate = _boundRate(anotherNewPerSecondRate);
        vm.assume(newPerSecondRate != anotherNewPerSecondRate);
        vm.assume(stableVault.getSubVaultIdByRate(newPerSecondRate) == 0);
        vm.assume(stableVault.getSubVaultIdByRate(anotherNewPerSecondRate) == 0);

        vm.prank(manager);
        stableVault.setDefaultSubVault(newPerSecondRate);

        uint256 lastId = stableVault.getDefaultSubVault().id;

        assertEq(stableVault.getDefaultSubVault().perSecondRate, newPerSecondRate);
        assertEq(stableVault.getSubVaultIdByRate(newPerSecondRate), lastId);
        assertEq(stableVault.getSubVaultRateById(lastId), newPerSecondRate);

        uint256 expectedId = lastId + 1;

        assertEq(stableVault.getSubVaultIdByRate(anotherNewPerSecondRate), 0);
        assertEq(stableVault.getSubVaultRateById(expectedId), 0);

        vm.prank(manager);
        stableVault.setDefaultSubVault(anotherNewPerSecondRate);

        assertEq(stableVault.getDefaultSubVault().perSecondRate, anotherNewPerSecondRate);
        assertEq(stableVault.getSubVaultIdByRate(anotherNewPerSecondRate), expectedId);
        assertEq(stableVault.getSubVaultRateById(expectedId), anotherNewPerSecondRate);
    }

    function test_setDefaultSubVault_reverts_ifMsgSenderIsNotAuthorized(
        address unauthorizedMsgSender,
        uint256 newPerSecondRate
    ) public {
        vm.assume(unauthorizedMsgSender != address(0));
        _assumeNotProxyAdmin(unauthorizedMsgSender, address(stableVault));
        vm.assume(unauthorizedMsgSender != manager);
        newPerSecondRate = _boundRate(newPerSecondRate);

        mockAccessManager.mockRejectCall(
            unauthorizedMsgSender, address(stableVault), IStableVault.setDefaultSubVault.selector
        );
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedMsgSender)
        );
        vm.prank(unauthorizedMsgSender);
        stableVault.setDefaultSubVault(newPerSecondRate);
    }

    function test_setDefaultSubVault_reverts_ifNewRateIsInvalid(uint256 invalidPerSecondRate) public {
        vm.assume(invalidPerSecondRate < MathLib.RAY);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IStableVault.InvalidRate.selector));
        stableVault.setDefaultSubVault(invalidPerSecondRate);
    }

    function test_getAggregatedBalance_returnsExpectedValue(uint256 expectedAssets) public {
        expectedAssets = _boundRayAmount(expectedAssets);

        mockFundsHandler.mockAggregatedBalance(expectedAssets);
        vm.expectCall(address(mockFundsHandler), abi.encodeWithSelector(IFundsHandler.getAggregatedBalance.selector));

        uint256 actualAssets = stableVault.getAggregatedBalance();

        assertEq(actualAssets, expectedAssets);
    }

    function test_claimSurplusInterest_reverts_ifAmountIsZero() public {
        vm.expectRevert(Errors.ZeroAmount.selector);
        vm.prank(manager);
        stableVault.claimSurplusInterest(_toAddressArray(address(mockAsset)), _toUint256Array(0));
    }

    function test_claimSurplusInterest_reverts_ifMsgSenderIsNotAuthorized(
        address unauthorizedMsgSender,
        uint256 amountToClaim
    ) public {
        _assumeNotProxyAdmin(unauthorizedMsgSender, address(stableVault));
        amountToClaim = _boundAssetAmount(address(mockAsset), amountToClaim);

        mockAccessManager.mockRejectCall(
            unauthorizedMsgSender, address(stableVault), IStableVault.claimSurplusInterest.selector
        );

        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedMsgSender)
        );
        vm.prank(unauthorizedMsgSender);
        stableVault.claimSurplusInterest(_toAddressArray(address(mockAsset)), _toUint256Array(amountToClaim));
    }

    function test_claimSurplusInterest_reverts_ifObligationsExceedAssets(
        uint256 obligationsRay,
        uint256 aggregatedBalanceRay
    ) public {
        obligationsRay = _boundRayAmount(obligationsRay);
        aggregatedBalanceRay = _boundRayAmount(aggregatedBalanceRay);
        uint256 obligationsAfterConversionRay =
            obligationsRay.rayToAssetDecimals(address(mockAsset)).assetDecimalsToRay(address(mockAsset));
        vm.assume(obligationsAfterConversionRay > aggregatedBalanceRay);

        mockFundsHandler.mockAggregatedBalance(aggregatedBalanceRay);

        // Make a deposit of `obligations` to grow the obligations to that amount
        uint256 obligationsInAssetDecimals = obligationsRay.rayToAssetDecimals(address(mockAsset));

        vm.assume(obligationsInAssetDecimals > 0);

        mockAsset.mint(obligationsInAssetDecimals);
        mockAsset.forceApprove(address(stableVault), obligationsInAssetDecimals);
        stableVault.deposit(address(this), address(mockAsset), obligationsInAssetDecimals, "");

        assertGt(stableVault.getVaultObligations(), stableVault.getAggregatedBalance());

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IStableVault.SurplusInterestClaimLeadsToInsolvency.selector));
        stableVault.claimSurplusInterest(
            _toAddressArray(address(mockAsset)), _toUint256Array(obligationsInAssetDecimals)
        );
    }

    function test_claimSurplusInterest_reverts_ifPostWithdrawalBalanceDropsBelowObligations() public {
        uint256 depositAmount = 1000e6;
        mockAsset.mint(address(this), depositAmount);
        mockAsset.forceApprove(address(stableVault), depositAmount);
        stableVault.deposit(address(this), address(mockAsset), depositAmount, "");
        uint256 obligations = stableVault.getVaultObligations();

        // Simulate correlated strategy losses: post-withdrawal balance drops below obligations
        mockFundsHandler.mockAggregatedBalanceAfterWithdrawal(obligations - 1);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IStableVault.SurplusInterestClaimLeadsToInsolvency.selector));
        stableVault.claimSurplusInterest(_toAddressArray(address(mockAsset)), _toUint256Array(1e6));
    }

    /// @dev getVaultObligations() (and totalSupply()) floor the share-derived sub-vault obligations at the
    /// aggregate original deposits, so the treasury cannot claim surplus interest down past the principal that
    /// requestWithdrawal() still guarantees, even when per-user deposit rounding makes the share-ceiling undershoot.
    function test_claimSurplusInterest_obligationsFlooredAtPrincipal_blocksClaimBelowOriginalDeposits() public {
        address user = makeAddr("user");
        MockErc20 ghoToken = new MockErc20("GHO", "GHO", 18);

        uint256 highRate = 3 * MathLib.RAY;
        IStableVault highRateVault = _deployStableVault(
            address(mockAccessManager),
            highRate + 1,
            highRate,
            address(mockIouTokenManager),
            address(mockFundsHandler),
            address(mockAssetRegistry),
            address(mockTransferHelper),
            address(mockPriceOracle),
            DEFAULT_MAX_ACTIVE_SUB_VAULTS,
            treasury,
            address(policyRegistry)
        );

        vm.warp(block.timestamp + 1);

        uint256 depositAmount = 5;
        uint256 depositAmountRay = depositAmount.assetDecimalsToRay(address(ghoToken));

        ghoToken.mint(user, depositAmount);
        vm.prank(user);
        ghoToken.approve(address(highRateVault), depositAmount);
        vm.prank(user);
        highRateVault.deposit(user, address(ghoToken), depositAmount, "");

        // The share-ceiling reconstruction undershoots the principal sum by 2 wei.
        uint256 shareCeilingObligationRay = depositAmountRay.rayDivDown(highRate).rayMulUp(highRate);
        assertEq(shareCeilingObligationRay, depositAmountRay - 2);

        // Obligations and totalSupply are floored at the principal, not the lower share-ceiling value.
        assertEq(highRateVault.getGlobalOriginalDepositAmount(), depositAmountRay);
        assertEq(highRateVault.getVaultObligations(), depositAmountRay);
        assertEq(highRateVault.totalSupply(), depositAmountRay);

        // A claim that would draw the aggregated balance down to the share-ceiling value (1 wei below the principal
        // floor) is rejected; without the floor the obligations check would have permitted it.
        mockFundsHandler.mockAggregatedBalance(depositAmountRay - 1);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IStableVault.SurplusInterestClaimLeadsToInsolvency.selector));
        highRateVault.claimSurplusInterest(_toAddressArray(address(ghoToken)), _toUint256Array(1));
    }

    function test_claimSurplusInterest_reverts_ifPullingMoreFundsThanTheAvailableFeesToClaim(
        uint256 surplusRay,
        uint256 requestedAssetsToClaim
    ) public {
        requestedAssetsToClaim = _boundAssetAmount(address(mockAsset), requestedAssetsToClaim);
        surplusRay = _boundRayAmount(surplusRay);
        vm.assume(requestedAssetsToClaim.assetDecimalsToRay(address(mockAsset)) > surplusRay);

        uint256 depositAmount = 1000e6;
        mockAsset.mint(address(this), depositAmount);
        mockAsset.forceApprove(address(stableVault), depositAmount);
        stableVault.deposit(address(this), address(mockAsset), depositAmount, "");
        uint256 obligations = stableVault.getVaultObligations();

        // Post-withdrawal balance: obligations + surplus - claimed < obligations (since claimed > surplus)
        uint256 requestedRay = requestedAssetsToClaim.assetDecimalsToRay(address(mockAsset));
        uint256 postBalance = requestedRay <= obligations + surplusRay ? obligations + surplusRay - requestedRay : 0;
        mockFundsHandler.mockAggregatedBalanceAfterWithdrawal(postBalance);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IStableVault.SurplusInterestClaimLeadsToInsolvency.selector));
        stableVault.claimSurplusInterest(_toAddressArray(address(mockAsset)), _toUint256Array(requestedAssetsToClaim));
    }

    function test_claimSurplusInterest_emitExpectedEvent(
        uint256 availableFeesToClaimRay,
        uint256 requestedAssetsToClaim
    ) public {
        requestedAssetsToClaim = _boundAssetAmount(address(mockAsset), requestedAssetsToClaim);
        availableFeesToClaimRay = _boundRayAmount(availableFeesToClaimRay);
        vm.assume(requestedAssetsToClaim.assetDecimalsToRay(address(mockAsset)) <= availableFeesToClaimRay);

        mockTransferHelper.mockAsset(address(mockAsset), availableFeesToClaimRay);

        mockFundsHandler.mockAggregatedBalance(availableFeesToClaimRay);

        vm.expectEmit(true, true, true, true);
        emit IStableVault.SurplusInterestClaimed(
            _toAddressArray(address(mockAsset)), _toUint256Array(requestedAssetsToClaim)
        );

        vm.prank(manager);
        stableVault.claimSurplusInterest(_toAddressArray(address(mockAsset)), _toUint256Array(requestedAssetsToClaim));
    }

    function test_claimSurplusInterest_sendsExpectedAmountOfFeesToTreasury(
        address msgSender,
        uint256 availableFeesToClaimRay,
        uint256 requestedAssetsToClaim
    ) public {
        vm.assume(msgSender != address(0));
        _assumeNotProxyAdmin(msgSender, address(stableVault));
        requestedAssetsToClaim = _boundAssetAmount(address(mockAsset), requestedAssetsToClaim);
        availableFeesToClaimRay = _boundRayAmount(availableFeesToClaimRay);
        vm.assume(requestedAssetsToClaim.assetDecimalsToRay(address(mockAsset)) <= availableFeesToClaimRay);
        vm.assume(mockAsset.balanceOf(treasury) == 0);
        vm.assume(mockTransferHelper.getBalance(address(mockAsset)) == 0);

        mockTransferHelper.mockAsset(address(mockAsset), availableFeesToClaimRay);

        mockFundsHandler.mockAggregatedBalance(availableFeesToClaimRay);

        // The AccessManager contract we use has all calls allowed by default, only rejections needs to be explicit.
        vm.prank(msgSender);
        stableVault.claimSurplusInterest(_toAddressArray(address(mockAsset)), _toUint256Array(requestedAssetsToClaim));

        assertEq(mockAsset.balanceOf(treasury), requestedAssetsToClaim);
    }

    function test_claimSurplusInterest_reverts_ifTreasuryIsZeroAddress(
        uint256 availableFeesToClaimRay,
        uint256 requestedAssetsToClaim
    ) public {
        requestedAssetsToClaim = _boundAssetAmount(address(mockAsset), requestedAssetsToClaim);
        availableFeesToClaimRay = _boundRayAmount(availableFeesToClaimRay);
        vm.assume(requestedAssetsToClaim.assetDecimalsToRay(address(mockAsset)) <= availableFeesToClaimRay);

        mockTransferHelper.mockAsset(address(mockAsset), availableFeesToClaimRay);
        mockFundsHandler.mockAggregatedBalance(availableFeesToClaimRay);

        // Set treasury to address(0)
        vm.prank(manager);
        stableVault.setTreasury(address(0));
        assertEq(stableVault.getTreasury(), address(0));

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IStableVault.TreasuryNotSet.selector));
        stableVault.claimSurplusInterest(_toAddressArray(address(mockAsset)), _toUint256Array(requestedAssetsToClaim));
    }

    function test_setTreasury_reverts_ifMsgSenderIsNotAuthorized(address unauthorizedMsgSender, address newTreasury)
        public
    {
        _assumeNotProxyAdmin(unauthorizedMsgSender, address(stableVault));
        vm.assume(unauthorizedMsgSender != manager);

        mockAccessManager.mockRejectCall(unauthorizedMsgSender, address(stableVault), IStableVault.setTreasury.selector);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedMsgSender)
        );
        vm.prank(unauthorizedMsgSender);
        stableVault.setTreasury(newTreasury);
    }

    function test_setTreasury_setsTheExpectedTreasury(address newTreasury) public {
        vm.prank(manager);
        stableVault.setTreasury(newTreasury);

        assertEq(stableVault.getTreasury(), newTreasury);
    }

    function test_setTreasury_setsToZeroAddress(address nonZeroTreasury) public {
        vm.assume(nonZeroTreasury != address(0));

        vm.prank(manager);
        stableVault.setTreasury(nonZeroTreasury);
        assertEq(stableVault.getTreasury(), nonZeroTreasury);

        vm.prank(manager);
        stableVault.setTreasury(address(0));
        assertEq(stableVault.getTreasury(), address(0));
    }

    function test_setTreasury_emitsExpectedEvent(address newTreasury) public {
        vm.expectEmit(true, true, true, true);
        emit IStableVault.TreasurySet(newTreasury);

        vm.prank(manager);
        stableVault.setTreasury(newTreasury);
    }

    function test_getTreasury_returnsExpectedValue() public view {
        assertEq(stableVault.getTreasury(), treasury);
    }

    function test_setSubVaultRate_updatesAssociationBetweenSubVaultIdAndRateProperly(
        uint256 perSecondRate,
        uint256 newPerSecondRate
    ) public {
        perSecondRate = _boundRate(perSecondRate);
        newPerSecondRate = _boundRate(newPerSecondRate);
        vm.assume(perSecondRate != newPerSecondRate);
        vm.assume(stableVault.getSubVaultIdByRate(perSecondRate) == 0);
        vm.assume(stableVault.getSubVaultIdByRate(newPerSecondRate) == 0);

        address user = makeAddr("user");
        uint256 amount = 100e6;
        mockAsset.mint(user, amount);
        vm.prank(user);
        mockAsset.forceApprove(address(stableVault), amount);
        vm.prank(user);
        stableVault.deposit(user, address(mockAsset), amount, "");
        IStableVault.UserRateData[] memory userRateData = new IStableVault.UserRateData[](1);
        userRateData[0] = IStableVault.UserRateData(user, perSecondRate);
        vm.prank(manager);
        stableVault.setUserRate(userRateData);

        uint256 subVaultId = stableVault.getUserSubVault(user).id;

        // The association between the sub-vault ID and rate was correctly set
        assertEq(stableVault.getSubVaultRateById(subVaultId), perSecondRate);
        assertEq(stableVault.getSubVaultIdByRate(perSecondRate), subVaultId);

        vm.prank(manager);
        stableVault.setSubVaultRate(subVaultId, newPerSecondRate);

        // The association between the sub-vault ID and rate is updated
        assertEq(stableVault.getSubVaultRateById(subVaultId), newPerSecondRate);
        assertEq(stableVault.getSubVaultIdByRate(newPerSecondRate), subVaultId);

        // The old rate is no longer associated with any sub-vault ID
        assertEq(stableVault.getSubVaultIdByRate(perSecondRate), 0);
    }

    function test_setSubVaultRate_reverts_ifMsgSenderIsNotAuthorized(
        address unauthorizedMsgSender,
        uint256 subVaultId,
        uint256 newPerSecondRate
    ) public {
        _assumeNotProxyAdmin(unauthorizedMsgSender, address(stableVault));
        newPerSecondRate = _boundRate(newPerSecondRate);

        mockAccessManager.mockRejectCall(
            unauthorizedMsgSender, address(stableVault), IStableVault.setSubVaultRate.selector
        );

        vm.prank(unauthorizedMsgSender);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedMsgSender)
        );
        stableVault.setSubVaultRate(subVaultId, newPerSecondRate);
    }

    function test_setSubVaultRate_reverts_ifRateIsInvalid(uint256 subVaultId, uint256 invalidRate) public {
        vm.assume(invalidRate < MathLib.RAY || invalidRate > DEFAULT_MAX_PER_SECOND_RATE);

        vm.expectRevert(IStableVault.InvalidRate.selector);
        stableVault.setSubVaultRate(subVaultId, invalidRate);
    }

    function test_setSubVaultRate_reverts_ifAlreadyExistsAVaultWithTheGivenRate(
        uint256 subVaultId,
        uint256 existingRate
    ) public {
        existingRate = _boundRate(existingRate);

        stableVault.setDefaultSubVault(existingRate);

        vm.expectRevert(IStableVault.SubVaultAlreadyExists.selector);
        stableVault.setSubVaultRate(subVaultId, existingRate);
    }

    function test_setSubVaultRate_reverts_ifNoSubVaultExistsWithTheGivenId(uint256 subVaultId, uint256 perSecondRate)
        public
    {
        vm.assume(stableVault.getSubVaultRateById(subVaultId) == 0);

        perSecondRate = _boundRate(perSecondRate);
        vm.assume(stableVault.getSubVaultIdByRate(perSecondRate) == 0);

        vm.expectRevert(IStableVault.SubVaultDoesNotExist.selector);
        stableVault.setSubVaultRate(subVaultId, perSecondRate);
    }

    function test_setSubVaultRate_emitsExpectedEvent(uint256 newPerSecondRate) public {
        newPerSecondRate = _boundRate(newPerSecondRate);
        vm.assume(stableVault.getSubVaultIdByRate(newPerSecondRate) == 0);

        uint256 subVaultId = stableVault.getDefaultSubVault().id;

        vm.expectEmit(true, true, true, true);
        emit IStableVault.SubVaultRateSet(subVaultId, newPerSecondRate);
        vm.expectEmit(true, true, true, true);
        emit IStableVault.DefaultSubVaultSet(subVaultId, newPerSecondRate);
        vm.prank(manager);
        stableVault.setSubVaultRate(subVaultId, newPerSecondRate);
    }

    function test_setSubVaultRate_setsTheExpectedRate(uint256 newPerSecondRate) public {
        newPerSecondRate = _boundRate(newPerSecondRate);
        vm.assume(stableVault.getSubVaultIdByRate(newPerSecondRate) == 0);

        uint256 subVaultId = stableVault.getDefaultSubVault().id;
        stableVault.setSubVaultRate(subVaultId, newPerSecondRate);

        assertEq(stableVault.getSubVaultRateById(subVaultId), newPerSecondRate);
        assertEq(stableVault.getSubVaultIdByRate(newPerSecondRate), subVaultId);
    }

    function test_getActiveSubVaults_activeSubVaultIsAddedUponDeposit(address user, uint256 depositAmount) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);

        assertEq(stableVault.getActiveSubVaults().length, 0);

        _deposit(user, depositAmount);

        assertEq(stableVault.getActiveSubVaults().length, 1);
        assertEq(stableVault.getActiveSubVaults()[0].id, stableVault.getDefaultSubVault().id);
    }

    function test_getActiveSubVaults_activeSubVaultIsChangedUponSetUserRate(
        address user,
        uint256 depositAmount,
        uint256 newPerSecondRate
    ) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);

        _deposit(user, depositAmount);

        assertEq(stableVault.getActiveSubVaults().length, 1);
        assertEq(stableVault.getActiveSubVaults()[0].id, stableVault.getDefaultSubVault().id);

        newPerSecondRate = _boundRate(newPerSecondRate);
        vm.assume(stableVault.getSubVaultIdByRate(newPerSecondRate) != stableVault.getDefaultSubVault().id);

        _setUserRate(user, newPerSecondRate);

        assertEq(stableVault.getActiveSubVaults().length, 1);
        assertEq(stableVault.getActiveSubVaults()[0].id, stableVault.getSubVaultIdByRate(newPerSecondRate));
    }

    function test_getActiveSubVaults_activeSubVaultIsRemovedWhenAllLiquidityIsWithdrawnFromIt(
        address user,
        uint256 depositAmount
    ) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);
        _deposit(user, depositAmount);
        mockFundsHandler.mockAggregatedBalance(depositAmount);

        assertEq(stableVault.getActiveSubVaults().length, 1);

        vm.prank(user);
        stableVault.requestWithdrawal(user, 0, "");

        assertEq(stableVault.getActiveSubVaults().length, 0);
    }

    function test_getUserBalance_returnsZeroIfUserDoesNotHaveAPosition(address user) public view {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        vm.assume(stableVault.getUserSubVault(user).id == 0);

        assertEq(stableVault.getUserBalance(user), 0);
    }

    function test_balanceOf_returnsZeroIfUserDoesNotHaveAPosition(address user) public view {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        vm.assume(stableVault.getUserSubVault(user).id == 0);

        assertEq(stableVault.balanceOf(user), 0);
    }

    function test_balanceOf_matchesGetUserBalance(address user, uint256 depositAmount) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);

        _deposit(user, depositAmount);

        assertEq(stableVault.balanceOf(user), stableVault.getUserBalance(user));

        vm.warp(block.timestamp + 73);
        assertEq(stableVault.balanceOf(user), stableVault.getUserBalance(user));
    }

    function test_totalSupply_matchesVaultObligationsMinusIous(address user, uint256 depositAmount) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);

        _deposit(user, depositAmount);

        assertEq(stableVault.totalSupply(), stableVault.getVaultObligations() - mockIouToken.totalSupply());

        uint256 userBalance = stableVault.getUserBalance(user);
        vm.assume(userBalance >= Constants.MIN_WITHDRAWABLE_AMOUNT_RAY * 2);
        mockFundsHandler.mockAggregatedBalance(stableVault.getVaultObligations());

        vm.prank(user);
        stableVault.requestWithdrawal(user, Constants.MIN_WITHDRAWABLE_AMOUNT_RAY, "");

        assertEq(stableVault.totalSupply(), stableVault.getVaultObligations() - mockIouToken.totalSupply());
        assertGt(mockIouToken.totalSupply(), 0);
    }

    function test_requestWithdrawal_reverts_ifMsgSenderIsNotTheUser(
        address user,
        address msgSender,
        uint256 depositAmount,
        uint256 withdrawalAmountRay
    ) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        _assumeNotProxyAdmin(msgSender, address(stableVault));
        vm.assume(msgSender != user);
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);
        _deposit(user, depositAmount);
        withdrawalAmountRay = bound(withdrawalAmountRay, 0, depositAmount.assetDecimalsToRay(address(mockAsset)));

        vm.expectRevert(IStableVault.OnlyUser.selector);
        vm.prank(msgSender);
        stableVault.requestWithdrawal(user, withdrawalAmountRay, "");
    }

    function test_requestWithdrawal_reverts_userDoesNotHaveAPosition(address user, uint256 withdrawalAmountRay) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        withdrawalAmountRay = _boundRayAmount(withdrawalAmountRay);

        vm.expectRevert(IStableVault.NonExistentPosition.selector);
        vm.prank(user);
        stableVault.requestWithdrawal(user, withdrawalAmountRay, "");
    }

    function test_requestWithdrawal_passingZeroWorksAsFullWithdrawalAmountWildcard(address user, uint256 depositAmount)
        public
    {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);
        _deposit(user, depositAmount);

        uint256 userBalanceRay = stableVault.getUserBalance(user);

        vm.prank(user);
        uint256 actualWithdrawalAmountRay = stableVault.requestWithdrawal(user, 0, "");

        assertEq(actualWithdrawalAmountRay, userBalanceRay);
    }

    function test_requestWithdrawal_queriesRegistryWithWithdrawalRequestPolicyId(address user, uint256 depositAmount)
        public
    {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);
        _deposit(user, depositAmount);

        vm.expectCall(
            address(policyRegistry),
            abi.encodeCall(
                IPolicyRegistry.getPolicy, keccak256("aave.stable-vault.StableVault.policy.withdrawal-request")
            )
        );

        vm.prank(user);
        stableVault.requestWithdrawal(user, 0, "");
    }

    // Couldn't reproduce the case where the withdrawal amount is zero due to conversion rounding loss.
    //   └────── It should never happen. We added an `assert` instead of a `require`. We can remove it
    //           later or keep it as a safe guard.
    function test_requestWithdrawal_DoesNotHaveRoundingLoss(address user) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        uint256 depositAmount = 1;

        uint256 depositAmountInRay = depositAmount.assetDecimalsToRay(address(mockAsset));
        _deposit(user, depositAmount);

        vm.warp(block.timestamp + 1);
        mockFundsHandler.mockAggregatedBalance(10e27);

        vm.prank(user);
        stableVault.requestWithdrawal(user, depositAmountInRay, "");

        vm.prank(user);
        stableVault.requestWithdrawal(user, 0, "");
    }

    function test_requestWithdrawal_WithReallySmallInterest(address user) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        uint256 depositAmount = 1000000;

        uint256 depositAmountInRay = depositAmount.assetDecimalsToRay(address(mockAsset));
        _deposit(user, depositAmount);

        uint256 smallestGrowingRate = 1000000000000000000000000001;
        _setUserRate(user, smallestGrowingRate);

        vm.warp(block.timestamp + 1);
        mockFundsHandler.mockAggregatedBalance(10e27);

        vm.prank(user);
        stableVault.requestWithdrawal(user, depositAmountInRay - 1, "");

        // A partial withdrawal that would leave unwithdrawable dust triggers an auto-full-withdrawal which deletes the
        // position. Only request the remainder if the position still exists.
        if (stableVault.getUserSubVault(user).id != 0) {
            vm.prank(user);
            stableVault.requestWithdrawal(user, 0, "");
        }
    }

    function test_requestWithdrawal_autoFullWithdrawalWhenDustWouldRemain(
        address user,
        uint256 depositAmount,
        uint256 timeElapsed,
        uint256 perSecondRate,
        uint256 dustRemainderShares
    ) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));

        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);
        timeElapsed = bound(timeElapsed, 1, 365 days * 50);
        perSecondRate = _boundRate(perSecondRate);

        // Ensure the user's position accrues at the fuzzed vault APY.
        vm.prank(manager);
        stableVault.setDefaultSubVault(perSecondRate);
        _deposit(user, depositAmount);
        uint256 originalDepositRay = depositAmount.assetDecimalsToRay(address(mockAsset));
        // Because the deposit happens without any accrual (`conversionRate == RAY` before vm.warp), the user gets:
        // shares = depositRay / RAY = depositRay.
        uint256 userShares = originalDepositRay;
        assertEq(stableVault.getGlobalOriginalDepositAmount(), originalDepositRay);
        assertEq(stableVault.getUserBalance(user), originalDepositRay);
        assertEq(stableVault.getUserSubVault(user).perSecondRate, perSecondRate);
        assertEq(stableVault.getUserSubVault(user).id, stableVault.getDefaultSubVault().id);

        vm.warp(block.timestamp + timeElapsed);

        uint256 requestedAmountRay;
        uint256 expectedFullWithdrawalRay;
        {
            // This matches the contract's `_accrueSubVaultConversionRate` rounding down, starting from
            // `conversionRate = RAY`.
            uint256 conversionRate = MathLib.RAY.rayMulDown(perSecondRate.rpow(timeElapsed));
            uint256 minSharesToRedeemOneWei = uint256(Constants.MIN_WITHDRAWABLE_AMOUNT_RAY).rayDivUp(conversionRate);
            assertTrue(minSharesToRedeemOneWei > 1);
            dustRemainderShares = bound(dustRemainderShares, 1, minSharesToRedeemOneWei - 1);

            // Pick a non-zero partial withdrawal that would leave `dustRemainderShares` in shares, which is below the
            // dust threshold and should trigger an auto-full-withdrawal.
            assertTrue(userShares > dustRemainderShares);
            uint256 sharesToRedeem = userShares - dustRemainderShares;
            requestedAmountRay = sharesToRedeem.rayMulDown(conversionRate);

            // Prove (pre-call) that the request would leave exactly `dustRemainderShares` after the contract's
            // `rayDivUp`-based share redemption computation.
            uint256 expectedRedeemedShares = requestedAmountRay.rayDivUp(conversionRate);
            assertEq(expectedRedeemedShares, sharesToRedeem);
            assertEq(userShares - expectedRedeemedShares, dustRemainderShares);
            assertTrue(dustRemainderShares < minSharesToRedeemOneWei);

            // Ensure there's enough assets in the vault to satisfy the full withdrawal.
            expectedFullWithdrawalRay = userShares.rayMulDown(conversionRate);
            if (expectedFullWithdrawalRay < originalDepositRay) {
                expectedFullWithdrawalRay = originalDepositRay;
            }
        }
        mockFundsHandler.mockAggregatedBalance(expectedFullWithdrawalRay);

        vm.prank(user);
        uint256 actualAmountRay = stableVault.requestWithdrawal(user, requestedAmountRay, "");

        assertEq(actualAmountRay, expectedFullWithdrawalRay);
        assertEq(mockIouToken.balanceOf(user), actualAmountRay);
        assertTrue(actualAmountRay > requestedAmountRay);
        assertTrue(actualAmountRay >= originalDepositRay);
        assertEq(stableVault.getUserSubVault(user).id, 0);
        assertEq(stableVault.getGlobalOriginalDepositAmount(), 0);
    }

    function test_requestWithdrawal_neverLeavesRemainingSharesBelowMinSharesToRedeemOneWei(
        address user,
        uint256 depositAmount,
        uint256 timeElapsed,
        uint256 perSecondRate,
        uint256 requestedAmountRay
    ) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));

        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);
        timeElapsed = bound(timeElapsed, 1, 365 days * 50);
        perSecondRate = _boundRate(perSecondRate);

        // Ensure the user's position accrues at the fuzzed vault APY.
        vm.prank(manager);
        stableVault.setDefaultSubVault(perSecondRate);
        _deposit(user, depositAmount);
        uint256 originalDepositRay = depositAmount.assetDecimalsToRay(address(mockAsset));
        // Because the deposit happens without any accrual (`conversionRate == RAY` before vm.warp), the user gets:
        // shares = depositRay / RAY = depositRay.
        uint256 userShares = originalDepositRay;

        vm.warp(block.timestamp + timeElapsed);

        uint256 maxWithdrawRay;
        uint256 minSharesToRedeemOneWei;
        uint256 expectedRemainingShares;
        uint256 conversionRate;
        {
            // Matches the contract's `_accrueSubVaultConversionRate` rounding down, starting from `conversionRate =
            // RAY`.
            conversionRate = MathLib.RAY.rayMulDown(perSecondRate.rpow(timeElapsed));
            minSharesToRedeemOneWei = uint256(Constants.MIN_WITHDRAWABLE_AMOUNT_RAY).rayDivUp(conversionRate);
            maxWithdrawRay = userShares.rayMulDown(conversionRate);

            requestedAmountRay = bound(requestedAmountRay, 0, maxWithdrawRay);

            // What the user would have left after a partial withdrawal; if it falls into dust, the vault switches to a
            // full withdrawal, leaving 0 shares instead.
            if (requestedAmountRay == 0) {
                expectedRemainingShares = 0;
            } else {
                expectedRemainingShares = userShares - requestedAmountRay.rayDivUp(conversionRate);
                if (expectedRemainingShares != 0 && expectedRemainingShares < minSharesToRedeemOneWei) {
                    expectedRemainingShares = 0;
                }
            }
        }

        // Ensure there's enough assets in the vault to satisfy even a full withdrawal.
        mockFundsHandler.mockAggregatedBalance(maxWithdrawRay);

        vm.prank(user);
        stableVault.requestWithdrawal(user, requestedAmountRay, "");

        if (expectedRemainingShares == 0) {
            assertEq(stableVault.getUserSubVault(user).id, 0);
            assertEq(stableVault.getUserBalance(user), 0);
        } else {
            // Property: if a position remains, it is never left with unwithdrawable dust shares.
            assertTrue(expectedRemainingShares >= minSharesToRedeemOneWei);
            assertEq(stableVault.getUserSubVault(user).id, stableVault.getDefaultSubVault().id);
            assertEq(stableVault.getUserSubVault(user).perSecondRate, perSecondRate);
            assertEq(stableVault.getUserBalance(user), expectedRemainingShares.rayMulDown(conversionRate));
        }
    }

    function test_requestWithdrawal_tinyAmountWorksAsExpected(address user) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        uint256 depositAmount = 1;

        IMockErc20 asset = IMockErc20(address(new MockErc20("GHO", "GHO", 18)));
        asset.mint(user, depositAmount);
        vm.prank(user);
        asset.forceApprove(address(stableVault), depositAmount);
        vm.prank(user);
        stableVault.deposit(user, address(asset), depositAmount, "");

        uint256 withdrawalAmountRay = depositAmount.assetDecimalsToRay(address(asset));

        vm.assume(asset.balanceOf(user) == 0);

        vm.prank(user);
        stableVault.requestWithdrawal(user, withdrawalAmountRay, "");

        assertEq(mockIouToken.balanceOf(user), withdrawalAmountRay);
    }

    function test_requestWithdrawal_reverts_ifWithdrawalAmountIsGreaterThanUserBalance(
        address user,
        uint256 userBalance,
        uint256 withdrawalAmountRay
    ) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        userBalance = _boundAssetAmount(address(mockAsset), userBalance);
        _deposit(user, userBalance);
        uint256 userBalanceRay = userBalance.assetDecimalsToRay(address(mockAsset));
        withdrawalAmountRay = _boundRayAmount(withdrawalAmountRay);
        vm.assume(withdrawalAmountRay > userBalanceRay);

        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(user);
        stableVault.requestWithdrawal(user, withdrawalAmountRay, "");
    }

    function test_requestWithdrawal_reverts_ifInterestToWithdrawIsGreaterThanAvailableInterest(
        address user,
        uint256 depositAmount,
        uint256 timeElapsed
    ) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);
        _deposit(user, depositAmount);

        timeElapsed = bound(timeElapsed, 5 minutes, 30 * 365 days);
        vm.warp(block.timestamp + timeElapsed);

        uint256 withdrawalAmountRay = stableVault.getUserBalance(user);

        mockFundsHandler.mockAggregatedBalance(depositAmount.assetDecimalsToRay(address(mockAsset)));

        vm.expectRevert(
            abi.encodeWithSelector(
                IStableVault.InsufficientAssets.selector,
                user,
                withdrawalAmountRay,
                depositAmount.assetDecimalsToRay(address(mockAsset))
            )
        );
        vm.prank(user);
        stableVault.requestWithdrawal(user, withdrawalAmountRay, "");
    }

    function test_requestWithdrawal_mintsExpectedAmountOfIouTokens(
        address user,
        uint256 depositAmount,
        uint256 withdrawalAmountRay
    ) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);
        _deposit(user, depositAmount);
        vm.assume(withdrawalAmountRay < depositAmount.assetDecimalsToRay(address(mockAsset)));
        vm.assume(mockIouToken.balanceOf(user) == 0);

        mockFundsHandler.mockAggregatedBalance(depositAmount);

        uint256 expectedIouTokens;
        if (withdrawalAmountRay == 0) {
            expectedIouTokens = stableVault.getUserBalance(user);
        } else {
            uint256 remainingBalance = stableVault.getUserBalance(user) - withdrawalAmountRay;
            // If remaining shares after partial withdrawal are not redeemable for at least 1 wei of 18-decimal asset,
            // a full withdrawal is performed instead, avoiding leaving non-redeemable dust shares.
            if (remainingBalance < Constants.MIN_WITHDRAWABLE_AMOUNT_RAY) {
                expectedIouTokens = stableVault.getUserBalance(user);
            } else {
                expectedIouTokens = withdrawalAmountRay;
            }
        }

        vm.prank(user);
        uint256 actualWithdrawalAmountRay = stableVault.requestWithdrawal(user, withdrawalAmountRay, "");

        assertEq(mockIouToken.balanceOf(user), expectedIouTokens);
        assertEq(actualWithdrawalAmountRay, expectedIouTokens);
    }

    function test_requestWithdrawal_emitsExpectedEvent(address user, uint256 depositAmount, uint256 withdrawalAmountRay)
        public
    {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);
        _deposit(user, depositAmount);
        vm.assume(withdrawalAmountRay < depositAmount.assetDecimalsToRay(address(mockAsset)));

        mockFundsHandler.mockAggregatedBalance(depositAmount);

        uint256 actualWithdrawalAmount =
            withdrawalAmountRay == 0 ? stableVault.getUserBalance(user) : withdrawalAmountRay;

        vm.expectEmit(true, true, true, true);
        emit IStableVault.WithdrawalRequested(user, 1, actualWithdrawalAmount, actualWithdrawalAmount);

        vm.prank(user);
        stableVault.requestWithdrawal(user, withdrawalAmountRay, "");
    }

    function test_requestWithdrawal_emitsTransferBurnEvent() public {
        address user = makeAddr("user");
        _assumeNotProxyAdmin(user, address(stableVault));

        uint256 depositAmount = 2_000_000;
        uint256 withdrawalAmountRay = Constants.MIN_WITHDRAWABLE_AMOUNT_RAY;
        _deposit(user, depositAmount);

        uint256 depositAmountRay = depositAmount.assetDecimalsToRay(address(mockAsset));
        mockFundsHandler.mockAggregatedBalance(depositAmountRay);

        vm.expectEmit(true, true, true, true);
        emit IStableVault.WithdrawalRequested(
            user, stableVault.getUserSubVault(user).id, withdrawalAmountRay, withdrawalAmountRay
        );
        vm.expectEmit(true, true, true, true);
        emit IStableVault.Transfer(user, address(0), withdrawalAmountRay);

        vm.prank(user);
        stableVault.requestWithdrawal(user, withdrawalAmountRay, "");
    }

    function test_requestWithdrawal_returnsExpectedAmount(
        address user,
        uint256 depositAmount,
        uint256 withdrawalAmountRay
    ) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);
        _deposit(user, depositAmount);
        uint256 userBalanceRay = depositAmount.assetDecimalsToRay(address(mockAsset));
        vm.assume(withdrawalAmountRay < userBalanceRay);
        // Ensure remaining shares are redeemable (not dust) to avoid full-withdrawal rounding
        vm.assume(
            withdrawalAmountRay == 0 || userBalanceRay - withdrawalAmountRay >= Constants.MIN_WITHDRAWABLE_AMOUNT_RAY
        );

        mockFundsHandler.mockAggregatedBalance(depositAmount);

        uint256 expectedReturnValue = withdrawalAmountRay == 0 ? stableVault.getUserBalance(user) : withdrawalAmountRay;

        vm.prank(user);
        uint256 actualReturnValue = stableVault.requestWithdrawal(user, withdrawalAmountRay, "");

        assertEq(actualReturnValue, expectedReturnValue);
    }

    function test_requestWithdrawal_reducesUserBalanceByExpectedAmount(
        address user,
        uint256 depositAmount,
        uint256 withdrawalAmountRay
    ) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);
        _deposit(user, depositAmount);
        uint256 userBalanceBefore = stableVault.getUserBalance(user);
        uint256 userBalanceRay = depositAmount.assetDecimalsToRay(address(mockAsset));
        vm.assume(withdrawalAmountRay < userBalanceRay);
        // Ensure remaining shares are redeemable (not dust) to avoid full-withdrawal rounding
        vm.assume(
            withdrawalAmountRay == 0 || userBalanceRay - withdrawalAmountRay >= Constants.MIN_WITHDRAWABLE_AMOUNT_RAY
        );

        mockFundsHandler.mockAggregatedBalance(depositAmount);

        uint256 actualWithdrawalAmountRay =
            withdrawalAmountRay == 0 ? stableVault.getUserBalance(user) : withdrawalAmountRay;

        vm.prank(user);
        uint256 actualReturnValue = stableVault.requestWithdrawal(user, withdrawalAmountRay, "");

        assertEq(actualReturnValue, actualWithdrawalAmountRay);
        assertEq(stableVault.getUserBalance(user), userBalanceBefore - actualWithdrawalAmountRay);
    }

    function test_requestWithdrawal_depositAndImmediatelyFullWithdraw_IOUsNeverUnderOriginalDeposit(
        uint256 amount,
        uint256 timeBetweenDeposits
    ) public {
        address user1 = makeAddr("USER1");
        address user2 = makeAddr("USER2");
        amount = _boundAssetAmount(address(mockAsset), amount);
        timeBetweenDeposits = bound(timeBetweenDeposits, 5 minutes, 30 * 365 days);

        // Deposit 1
        mockAsset.mint(user1, amount);
        vm.prank(user1);
        mockAsset.forceApprove(address(stableVault), amount);
        vm.prank(user1);
        stableVault.deposit(user1, address(mockAsset), amount, "");
        vm.warp(block.timestamp + timeBetweenDeposits);

        // Deposit 2
        mockAsset.mint(user2, amount);
        vm.prank(user2);
        mockAsset.forceApprove(address(stableVault), amount);
        vm.prank(user2);
        stableVault.deposit(user2, address(mockAsset), amount, "");

        // Request Full Withdrawal
        vm.prank(user2);
        uint256 iouTokenAmount = stableVault.requestWithdrawal(user2, 0, "");

        // After removing the assertion and replacing it with the code below from _fullWithdrawalRequest() we expect the
        // IOU quantity to be at least original deposit normalized to RAY decimals:
        //      if (actualAmountOfWithdrawalRay < originalDepositRay) {
        //         actualAmountOfWithdrawalRay = originalDepositRay;
        //      }
        assertGe(iouTokenAmount, amount.assetDecimalsToRay(address(mockAsset)));
    }

    function test_requestWithdrawal_depositAfterConversionRateGrownALot_IOUsNeverUnderOriginalDeposit() public {
        address user = makeAddr("testUser");

        MockErc20 ghoToken = new MockErc20("GHO", "GHO", 18);

        // Create a new vault with a rate that causes non-exact division
        // Using 1.5 * RAY (50% per second) for demonstration
        // This rate causes rounding when deposit amounts don't divide evenly
        uint256 highRate = (3 * MathLib.RAY) / 2; // 1.5 * RAY = 50% per second
        IStableVault highRateVault = _deployStableVault(
            address(mockAccessManager),
            highRate + 1, // max rate slightly higher
            highRate,
            address(mockIouTokenManager),
            address(mockFundsHandler),
            address(mockAssetRegistry),
            address(mockTransferHelper),
            address(mockPriceOracle),
            DEFAULT_MAX_ACTIVE_SUB_VAULTS,
            treasury,
            address(policyRegistry)
        );

        vm.warp(block.timestamp + 1);

        // Deposit exactly 1 unit (1e18 wei for 18-decimal token = 1e27 in Ray)
        // With conversionRate = 1.5 * RAY = 1.5e27:
        // shares = floor(1e27 * 1e27 / 1.5e27) = floor(0.666...e27) ≈ 6.66e26
        // actualAmount = floor(6.66e26 * 1.5e27 / 1e27) ≈ 0.999...e27
        // originalDeposit = 1e27
        // => 0.999e27 < 1e27
        uint256 depositAmount = 1e18; // 1 token with 18 decimals = 1e27 in Ray

        ghoToken.mint(user, depositAmount);

        vm.prank(user);
        ghoToken.approve(address(highRateVault), depositAmount);

        vm.prank(user);
        highRateVault.deposit(user, address(ghoToken), depositAmount, "");

        // Mock the aggregated balance to allow withdrawal (high enough to cover any interest)
        mockFundsHandler.mockAggregatedBalance(depositAmount.assetDecimalsToRay(address(ghoToken)) * 10);

        // We expect the IOU quantity to be at least original deposit normalized to RAY decimals:
        //      if (actualAmountOfWithdrawalRay < originalDepositRay) {
        //         actualAmountOfWithdrawalRay = originalDepositRay;
        //      }
        vm.prank(user);
        uint256 iouTokenAmount = highRateVault.requestWithdrawal(user, 0, "");
        assertEq(iouTokenAmount, depositAmount.assetDecimalsToRay(address(ghoToken)));
    }

    function test_transfer_reverts_ifRecipientIsZero(address user, uint256 depositAmount) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);

        _deposit(user, depositAmount);
        uint256 amountRay = depositAmount.assetDecimalsToRay(address(mockAsset));

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(user);
        assertFalse(stableVault.transfer(address(0), amountRay));
    }

    function test_transfer_reverts_ifAmountBelowMinimum(address user, address recipient, uint256 depositAmount) public {
        vm.assume(user != address(0));
        vm.assume(recipient != address(0));
        vm.assume(user != recipient);
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        _assumeNotProxyAdmin(recipient, address(stableVault));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);

        _deposit(user, depositAmount);
        uint256 amountRay = Constants.MIN_WITHDRAWABLE_AMOUNT_RAY - 1;

        vm.expectRevert(Errors.InvalidAmount.selector);
        vm.prank(user);
        assertFalse(stableVault.transfer(recipient, amountRay));
    }

    function test_transfer_reverts_ifUserDoesNotHaveAPosition(address user, address recipient) public {
        vm.assume(user != address(0));
        vm.assume(recipient != address(0));
        vm.assume(user != recipient);
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        _assumeNotProxyAdmin(recipient, address(stableVault));

        vm.expectRevert(IStableVault.NonExistentPosition.selector);
        vm.prank(user);
        assertFalse(stableVault.transfer(recipient, Constants.MIN_WITHDRAWABLE_AMOUNT_RAY));
    }

    function test_transfer_reverts_ifAmountExceedsBalance(address user, address recipient, uint256 depositAmount)
        public
    {
        vm.assume(user != address(0));
        vm.assume(recipient != address(0));
        vm.assume(user != recipient);
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        _assumeNotProxyAdmin(recipient, address(stableVault));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);

        _deposit(user, depositAmount);
        uint256 fullAmountRay = stableVault.getUserBalance(user);
        uint256 amountRay = fullAmountRay + Constants.MIN_WITHDRAWABLE_AMOUNT_RAY;

        vm.expectRevert(Errors.InsufficientFunds.selector);
        vm.prank(user);
        assertFalse(stableVault.transfer(recipient, amountRay));
    }

    function test_transfer_doesNotChangeGlobalOriginalDepositOrIous(
        address user,
        address recipient,
        uint256 depositAmount
    ) public {
        vm.assume(user != address(0));
        vm.assume(recipient != address(0));
        vm.assume(user != recipient);
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        _assumeNotProxyAdmin(recipient, address(stableVault));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);

        _deposit(user, depositAmount);
        uint256 amountRay = stableVault.getUserBalance(user) / 2;
        vm.assume(amountRay >= Constants.MIN_WITHDRAWABLE_AMOUNT_RAY);

        uint256 globalOriginalBefore = stableVault.getGlobalOriginalDepositAmount();
        uint256 iouSupplyBefore = mockIouToken.totalSupply();
        uint256 iouSenderBefore = mockIouToken.balanceOf(user);
        uint256 iouRecipientBefore = mockIouToken.balanceOf(recipient);

        vm.prank(user);
        assertTrue(stableVault.transfer(recipient, amountRay));

        assertEq(stableVault.getGlobalOriginalDepositAmount(), globalOriginalBefore);
        assertEq(mockIouToken.totalSupply(), iouSupplyBefore);
        assertEq(mockIouToken.balanceOf(user), iouSenderBefore);
        assertEq(mockIouToken.balanceOf(recipient), iouRecipientBefore);
    }

    function test_transfer_sameSubVault_transfersExpectedBalances(
        address user,
        address recipient,
        uint256 depositAmount
    ) public {
        vm.assume(user != address(0));
        vm.assume(recipient != address(0));
        vm.assume(user != recipient);
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        _assumeNotProxyAdmin(recipient, address(stableVault));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);

        _deposit(user, depositAmount);
        uint256 amountRay = depositAmount.assetDecimalsToRay(address(mockAsset)) / 3;
        vm.assume(amountRay >= Constants.MIN_WITHDRAWABLE_AMOUNT_RAY);

        uint256 senderBalanceBefore = stableVault.getUserBalance(user);
        uint256 recipientBalanceBefore = stableVault.getUserBalance(recipient);

        vm.prank(user);
        assertTrue(stableVault.transfer(recipient, amountRay));

        assertEq(stableVault.getUserBalance(user), senderBalanceBefore - amountRay);
        assertEq(stableVault.getUserBalance(recipient), recipientBalanceBefore + amountRay);
        assertEq(stableVault.getUserSubVault(user).id, stableVault.getDefaultSubVault().id);
        assertEq(stableVault.getUserSubVault(recipient).id, stableVault.getDefaultSubVault().id);
    }

    function test_transfer_sameSubVault_doesNotChangeTotalSupply(address user, address recipient, uint256 depositAmount)
        public
    {
        vm.assume(user != address(0));
        vm.assume(recipient != address(0));
        vm.assume(user != recipient);
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        _assumeNotProxyAdmin(recipient, address(stableVault));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);

        _deposit(user, depositAmount);
        uint256 amountRay = depositAmount.assetDecimalsToRay(address(mockAsset)) / 3;
        vm.assume(amountRay >= Constants.MIN_WITHDRAWABLE_AMOUNT_RAY);

        uint256 totalSupplyBefore = stableVault.totalSupply();

        vm.prank(user);
        assertTrue(stableVault.transfer(recipient, amountRay));

        // Same sub-vault transfers pass shares directly, so no shares are lost to double rounding
        // and the total supply remains unchanged.
        assertEq(stableVault.totalSupply(), totalSupplyBefore);
    }

    function test_transfer_crossSubVault_transfersExpectedBalances(
        address user,
        address recipient,
        uint256 depositAmount,
        uint256 newPerSecondRate
    ) public {
        vm.assume(user != address(0));
        vm.assume(recipient != address(0));
        vm.assume(user != recipient);
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        _assumeNotProxyAdmin(recipient, address(stableVault));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);
        newPerSecondRate = _boundRate(newPerSecondRate);
        vm.assume(newPerSecondRate != stableVault.getDefaultSubVault().perSecondRate);

        _deposit(user, depositAmount);
        _deposit(recipient, depositAmount);

        _setUserRate(recipient, newPerSecondRate);
        uint256 newSubVaultId = stableVault.getSubVaultIdByRate(newPerSecondRate);

        uint256 amountRay = stableVault.getUserBalance(user) / 4;
        vm.assume(amountRay >= Constants.MIN_WITHDRAWABLE_AMOUNT_RAY);

        uint256 senderBalanceBefore = stableVault.getUserBalance(user);
        uint256 recipientBalanceBefore = stableVault.getUserBalance(recipient);

        vm.prank(user);
        assertTrue(stableVault.transfer(recipient, amountRay));

        assertEq(stableVault.getUserBalance(user), senderBalanceBefore - amountRay);
        assertEq(stableVault.getUserBalance(recipient), recipientBalanceBefore + amountRay);
        assertEq(stableVault.getUserSubVault(recipient).id, newSubVaultId);
    }

    function test_transfer_revertsWhenDustWouldRemain() public {
        address user = makeAddr("user");
        address recipient = makeAddr("recipient");
        uint256 depositAmount = 1_000_000;
        _deposit(user, depositAmount);

        uint256 fullAmountRay = stableVault.getUserBalance(user);
        // Trying to transfer an amount that would leave dust (< MIN_WITHDRAWABLE_AMOUNT_RAY)
        uint256 amountRay = fullAmountRay - (Constants.MIN_WITHDRAWABLE_AMOUNT_RAY - 1);

        vm.prank(user);
        vm.expectRevert(Errors.InvalidAmount.selector);
        assertFalse(stableVault.transfer(recipient, amountRay));

        // User should use transferAll() instead
        vm.prank(user);
        assertTrue(stableVault.transferAll(recipient));

        assertEq(stableVault.getUserSubVault(user).id, 0);
        assertEq(stableVault.getUserBalance(user), 0);
        assertEq(stableVault.getUserBalance(recipient), fullAmountRay);
    }

    function test_transfer_sameSubVault_allowsMinimumAmount_noRoundingLoss() public {
        address user = makeAddr("user");
        address recipient = makeAddr("recipient");
        uint256 newPerSecondRate = MathLib.RAY + 1;

        vm.prank(manager);
        stableVault.setDefaultSubVault(newPerSecondRate);

        _deposit(user, 2_000_000);
        vm.warp(block.timestamp + 1);

        uint256 amountRay = Constants.MIN_WITHDRAWABLE_AMOUNT_RAY;

        vm.prank(user);
        assertTrue(stableVault.transfer(recipient, amountRay));

        // Same sub-vault transfers pass shares directly, so no rounding loss occurs.
        assertEq(stableVault.getUserBalance(recipient), amountRay);
    }

    function test_transfer_crossSubVault_allowsMinimumAmount_evenWhenRoundingWouldBeBelowMinShares() public {
        address user = makeAddr("user");
        address recipient = makeAddr("recipient");

        vm.prank(manager);
        stableVault.setDefaultSubVault(MathLib.RAY + 1);

        _deposit(user, 2_000_000);

        // Change default so recipient gets a different sub-vault.
        vm.prank(manager);
        stableVault.setDefaultSubVault(MathLib.RAY + 2);

        vm.warp(block.timestamp + 1);

        uint256 amountRay = Constants.MIN_WITHDRAWABLE_AMOUNT_RAY;

        vm.prank(user);
        assertTrue(stableVault.transfer(recipient, amountRay));

        // Cross sub-vault transfers recalculate shares via rayDivDown, so the share-backed value rounds down below
        // the transferred amount; the recipient inherits the moved principal, so balanceOf is floored back up to it.
        assertEq(stableVault.getUserBalance(recipient), amountRay);
    }

    function test_transfer_allowsNearMinimumAmounts_evenWhenRoundingIsUnfavorable(uint256 amountRayDelta) public {
        address user = makeAddr("user");
        address recipient = makeAddr("recipient");
        uint256 newPerSecondRate = MathLib.RAY + 1;

        amountRayDelta = bound(amountRayDelta, 0, 2);

        vm.prank(manager);
        stableVault.setDefaultSubVault(newPerSecondRate);

        _deposit(user, 2_000_000);
        vm.warp(block.timestamp + 1);

        uint256 amountRay = Constants.MIN_WITHDRAWABLE_AMOUNT_RAY + amountRayDelta;

        vm.prank(user);
        assertTrue(stableVault.transfer(recipient, amountRay));
    }

    function test_transfer_succeeds_whenRecipientHasDustAndCrossesThreshold() public {
        address user = makeAddr("user");
        address recipient = makeAddr("recipient");
        IMockErc20 mockAsset18dp = IMockErc20(address(new MockNonStandardErc20("Test GHO", "tGHO", 18)));

        // Create the higher-rate subVault, then return default to base rate.
        vm.prank(manager);
        stableVault.setDefaultSubVault(MathLib.RAY);
        vm.prank(manager);
        stableVault.setDefaultSubVault(MathLib.RAY + 1);
        vm.prank(manager);
        stableVault.setDefaultSubVault(MathLib.RAY);

        mockAsset18dp.mint(recipient, 1);
        vm.prank(recipient);
        mockAsset18dp.forceApprove(address(stableVault), 1);
        vm.prank(recipient);
        stableVault.deposit(recipient, address(mockAsset18dp), 1, "");

        vm.warp(block.timestamp + 1);
        vm.prank(manager);
        _setUserRate(recipient, MathLib.RAY + 1);

        _deposit(user, 2_000_000);
        uint256 amountRay = Constants.MIN_WITHDRAWABLE_AMOUNT_RAY;

        vm.prank(user);
        assertTrue(stableVault.transfer(recipient, amountRay));
    }

    function test_transferAll_transfersFullBalanceAndKeepsOriginalDeposit(
        address user,
        address recipient,
        uint256 depositAmount
    ) public {
        vm.assume(user != address(0));
        vm.assume(recipient != address(0));
        vm.assume(user != recipient);
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        _assumeNotProxyAdmin(recipient, address(stableVault));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);

        _deposit(user, depositAmount);
        uint256 fullAmountRay = stableVault.getUserBalance(user);
        uint256 globalOriginalBefore = stableVault.getGlobalOriginalDepositAmount();
        uint256 iouSupplyBefore = mockIouToken.totalSupply();

        vm.prank(user);
        assertTrue(stableVault.transferAll(recipient));

        assertEq(stableVault.getGlobalOriginalDepositAmount(), globalOriginalBefore);
        assertEq(mockIouToken.totalSupply(), iouSupplyBefore);
        assertEq(stableVault.getUserBalance(user), 0);
        assertEq(stableVault.getUserBalance(recipient), fullAmountRay);
    }

    function test_transfer_sameSubVault_usesPrincipalFirst_noRoundingLoss() public {
        address user = makeAddr("user");
        address recipient = makeAddr("recipient");
        uint256 newPerSecondRate = MathLib.RAY + 1;

        vm.prank(manager);
        stableVault.setDefaultSubVault(newPerSecondRate);

        _deposit(user, 2_000_000);
        vm.warp(block.timestamp + 1);

        uint256 amountRay = Constants.MIN_WITHDRAWABLE_AMOUNT_RAY + 1;

        vm.prank(user);
        assertTrue(stableVault.transfer(recipient, amountRay));

        // Same sub-vault transfers pass shares directly, so no rounding loss occurs.
        assertEq(stableVault.getUserBalance(recipient), amountRay);

        mockFundsHandler.mockAggregatedBalance(stableVault.getGlobalOriginalDepositAmount());
        vm.prank(recipient);
        uint256 withdrawnRay = stableVault.requestWithdrawal(recipient, 0, "");

        assertGe(withdrawnRay, amountRay);
    }

    function test_transfer_crossSubVault_usesPrincipalFirstWhenRoundingDown() public {
        address user = makeAddr("user");
        address recipient = makeAddr("recipient");

        vm.prank(manager);
        stableVault.setDefaultSubVault(MathLib.RAY + 1);

        _deposit(user, 2_000_000);

        // Change default so recipient gets a different sub-vault.
        vm.prank(manager);
        stableVault.setDefaultSubVault(MathLib.RAY + 2);

        vm.warp(block.timestamp + 1);

        uint256 amountRay = Constants.MIN_WITHDRAWABLE_AMOUNT_RAY + 1;

        vm.prank(user);
        assertTrue(stableVault.transfer(recipient, amountRay));

        // Cross sub-vault transfers recalculate shares via rayDivDown, so the share-backed value rounds down below
        // the transferred amount; the recipient inherits the moved principal, so balanceOf is floored back up to it.
        assertEq(stableVault.getUserBalance(recipient), amountRay);

        mockFundsHandler.mockAggregatedBalance(stableVault.getGlobalOriginalDepositAmount());
        vm.prank(recipient);
        uint256 withdrawnRay = stableVault.requestWithdrawal(recipient, 0, "");

        // Principal protection still ensures the withdrawal covers at least the transferred amount.
        assertGe(withdrawnRay, amountRay);
    }

    function test_transfer_reverts_ifRecipientIsSender(address user, uint256 depositAmount) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);

        _deposit(user, depositAmount);
        uint256 amountRay = stableVault.getUserBalance(user) / 2;
        vm.assume(amountRay >= Constants.MIN_WITHDRAWABLE_AMOUNT_RAY);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(user);
        assertFalse(stableVault.transfer(user, amountRay));
    }

    function test_transfer_handlesLargeConversionRateDifferential() public {
        // Test that transfers work correctly even with significant conversion rate differences
        // between sender and recipient subVaults
        address user = makeAddr("user");
        address recipient = makeAddr("recipient");

        // Use max valid rate (~20% APY) for recipient's subVault
        uint256 highRate = DEFAULT_MAX_PER_SECOND_RATE;
        vm.prank(manager);
        stableVault.setDefaultSubVault(highRate);

        // Deposit for recipient first so they get assigned to high rate subVault
        _deposit(recipient, 1_000_000);

        // Warp time to grow the conversion rate (1 year at 20% APY)
        vm.warp(block.timestamp + 365 days);

        // Change default to base rate (1x, no interest) for sender
        vm.prank(manager);
        stableVault.setDefaultSubVault(MathLib.RAY);

        // Deposit for sender
        _deposit(user, 1_000_000);

        uint256 userBalanceBefore = stableVault.getUserBalance(user);
        uint256 recipientBalanceBefore = stableVault.getUserBalance(recipient);
        uint256 amountRay = userBalanceBefore / 2;
        vm.assume(amountRay >= Constants.MIN_WITHDRAWABLE_AMOUNT_RAY);

        vm.prank(user);
        assertTrue(stableVault.transfer(recipient, amountRay));

        // Recipient's balance increased
        assertGt(stableVault.getUserBalance(recipient), recipientBalanceBefore);
        // User's balance decreased
        assertLt(stableVault.getUserBalance(user), userBalanceBefore);
    }

    function test_transfer_reverts_ifRecipientGetsZeroShares() public {
        // Setup: Create a scenario where the recipient would get 0 shares due to rounding
        // This requires a very high conversion rate in recipient's subVault such that:
        // toUserShares = amountRay.rayDivDown(toConversionRate) = 0
        // For MIN_WITHDRAWABLE_AMOUNT_RAY (1e9): need toConversionRate > 1e9 * 1e27 = 1e36
        // At 20% APY for ~115 years: 1.2^115 ≈ 1e9, so conversionRate ≈ 1e27 * 1e9 = 1e36
        address user = makeAddr("user");
        address recipient = makeAddr("recipient");

        // Use max valid rate (~20% APY) for recipient's subVault
        uint256 highRate = DEFAULT_MAX_PER_SECOND_RATE;
        vm.prank(manager);
        stableVault.setDefaultSubVault(highRate);

        // Deposit for recipient first so they get assigned to high rate subVault
        _deposit(recipient, 1_000_000);

        // Warp time significantly to grow the conversion rate (200 years at 20% APY)
        // This creates a conversion rate high enough that MIN_WITHDRAWABLE_AMOUNT_RAY results in 0 shares
        vm.warp(block.timestamp + 365 days * 200);

        // Change default to base rate (1x, no interest) for sender
        vm.prank(manager);
        stableVault.setDefaultSubVault(MathLib.RAY);

        // Deposit for sender with enough to have a valid transfer amount
        _deposit(user, 100_000_000);

        // Try to transfer the minimum amount - with extreme conversion rate, this results in 0 shares for recipient
        uint256 amountRay = Constants.MIN_WITHDRAWABLE_AMOUNT_RAY;

        vm.prank(user);
        vm.expectRevert(Errors.InvalidAmount.selector);
        assertFalse(stableVault.transfer(recipient, amountRay));
    }

    function test_transfer_emitsTransferEvent(address user, address recipient, uint256 depositAmount) public {
        vm.assume(user != address(0));
        vm.assume(recipient != address(0));
        vm.assume(user != recipient);
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        _assumeNotProxyAdmin(recipient, address(stableVault));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);

        _deposit(user, depositAmount);
        uint256 amountRay = stableVault.getUserBalance(user) / 2;
        vm.assume(amountRay >= Constants.MIN_WITHDRAWABLE_AMOUNT_RAY);

        vm.expectEmit(true, true, true, true);
        emit IStableVault.Transfer(user, recipient, amountRay);

        vm.prank(user);
        assertTrue(stableVault.transfer(recipient, amountRay));
    }

    /// @dev A full-balance `transfer` is not supported: burning the whole position leaves no redeemable
    /// remainder, so it reverts and the balance must move via `transferAll`. Transfers up to (but below)
    /// the share-backed value are covered by the partial-transfer tests.
    function test_transfer_fullBalance_revertsAndMovesViaTransferAll(
        address user,
        address recipient,
        uint256 depositAmount
    ) public {
        vm.assume(user != address(0));
        vm.assume(recipient != address(0));
        vm.assume(user != recipient);
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        _assumeNotProxyAdmin(recipient, address(stableVault));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);

        _deposit(user, depositAmount);
        uint256 fullAmountRay = stableVault.getUserBalance(user);

        vm.prank(user);
        vm.expectRevert(Errors.InvalidAmount.selector);
        assertFalse(stableVault.transfer(recipient, fullAmountRay));

        vm.prank(user);
        assertTrue(stableVault.transferAll(recipient));

        assertEq(stableVault.getUserBalance(user), 0);
        assertEq(stableVault.getUserSubVault(user).id, 0);
        assertEq(stableVault.getUserBalance(recipient), fullAmountRay);
    }

    function test_transfer_revertsWithInsufficientFunds_whenPartialTransferFallsIntoGuaranteedPrincipalDeadZone()
        public
    {
        address user = makeAddr("user");
        address recipient = makeAddr("recipient");
        MockErc20 ghoToken = new MockErc20("GHO", "GHO", 18);

        uint256 highRate = 3 * MathLib.RAY;
        IStableVault highRateVault = _deployStableVault(
            address(mockAccessManager),
            highRate + 1,
            highRate,
            address(mockIouTokenManager),
            address(mockFundsHandler),
            address(mockAssetRegistry),
            address(mockTransferHelper),
            address(mockPriceOracle),
            DEFAULT_MAX_ACTIVE_SUB_VAULTS,
            treasury,
            address(policyRegistry)
        );

        vm.warp(block.timestamp + 1);

        uint256 depositAmount = 5;
        uint256 fullTransferAmountRay = depositAmount.assetDecimalsToRay(address(ghoToken));
        uint256 partialTransferAmountRay = fullTransferAmountRay - 1;

        ghoToken.mint(user, depositAmount);
        vm.prank(user);
        ghoToken.approve(address(highRateVault), depositAmount);
        vm.prank(user);
        highRateVault.deposit(user, address(ghoToken), depositAmount, "");

        // The raw share-backed value rounds below the partial amount, so this amount sits in the gap between
        // the share-backed value and the principal floor.
        uint256 shareBackedBalanceRay = fullTransferAmountRay.rayDivDown(highRate).rayMulDown(highRate);
        assertEq(shareBackedBalanceRay, fullTransferAmountRay - 2);
        assertLt(shareBackedBalanceRay, partialTransferAmountRay);
        assertEq(highRateVault.getUserBalance(user), fullTransferAmountRay);

        // transfer() caps the amount at the share-backed value, so an amount above it reverts with
        // InsufficientFunds (the full position moves via transferAll()).
        vm.prank(user);
        vm.expectRevert(Errors.InsufficientFunds.selector);
        assertFalse(highRateVault.transfer(recipient, partialTransferAmountRay));
    }

    function test_transfer_allowsLargestPartialTransfer_beforeGuaranteedPrincipalDeadZone() public {
        address user = makeAddr("user");
        address recipient = makeAddr("recipient");
        MockErc20 ghoToken = new MockErc20("GHO", "GHO", 18);

        uint256 highRate = 3 * MathLib.RAY;
        IStableVault highRateVault = _deployStableVault(
            address(mockAccessManager),
            highRate + 1,
            highRate,
            address(mockIouTokenManager),
            address(mockFundsHandler),
            address(mockAssetRegistry),
            address(mockTransferHelper),
            address(mockPriceOracle),
            DEFAULT_MAX_ACTIVE_SUB_VAULTS,
            treasury,
            address(policyRegistry)
        );

        vm.warp(block.timestamp + 1);

        uint256 depositAmount = 5;
        uint256 fullTransferAmountRay = depositAmount.assetDecimalsToRay(address(ghoToken));
        uint256 shares = fullTransferAmountRay.rayDivDown(highRate);
        uint256 minSharesToRedeemOneWei = Constants.MIN_WITHDRAWABLE_AMOUNT_RAY.rayDivUp(highRate);
        uint256 maxPartialTransferAmountRay = (shares - minSharesToRedeemOneWei).rayMulDown(highRate);

        ghoToken.mint(user, depositAmount);
        vm.prank(user);
        ghoToken.approve(address(highRateVault), depositAmount);
        vm.prank(user);
        highRateVault.deposit(user, address(ghoToken), depositAmount, "");

        vm.prank(user);
        assertTrue(highRateVault.transfer(recipient, maxPartialTransferAmountRay));

        assertEq(highRateVault.getUserBalance(recipient), maxPartialTransferAmountRay);
        // The sender keeps the principal not moved to the recipient; balanceOf is floored to that remaining principal,
        // which sits just above the share-backed remainder of minSharesToRedeemOneWei.rayMulDown(highRate).
        assertEq(highRateVault.getUserBalance(user), fullTransferAmountRay - maxPartialTransferAmountRay);
    }

    function test_transfer_revertsWithInvalidAmount_atFirstAmountInsideGuaranteedPrincipalDeadZone() public {
        address user = makeAddr("user");
        address recipient = makeAddr("recipient");
        MockErc20 ghoToken = new MockErc20("GHO", "GHO", 18);

        uint256 highRate = 3 * MathLib.RAY;
        IStableVault highRateVault = _deployStableVault(
            address(mockAccessManager),
            highRate + 1,
            highRate,
            address(mockIouTokenManager),
            address(mockFundsHandler),
            address(mockAssetRegistry),
            address(mockTransferHelper),
            address(mockPriceOracle),
            DEFAULT_MAX_ACTIVE_SUB_VAULTS,
            treasury,
            address(policyRegistry)
        );

        vm.warp(block.timestamp + 1);

        uint256 depositAmount = 5;
        uint256 fullTransferAmountRay = depositAmount.assetDecimalsToRay(address(ghoToken));
        uint256 shares = fullTransferAmountRay.rayDivDown(highRate);
        uint256 minSharesToRedeemOneWei = Constants.MIN_WITHDRAWABLE_AMOUNT_RAY.rayDivUp(highRate);
        uint256 firstInvalidPartialTransferAmountRay = (shares - minSharesToRedeemOneWei).rayMulDown(highRate) + 1;

        ghoToken.mint(user, depositAmount);
        vm.prank(user);
        ghoToken.approve(address(highRateVault), depositAmount);
        vm.prank(user);
        highRateVault.deposit(user, address(ghoToken), depositAmount, "");

        vm.prank(user);
        vm.expectRevert(Errors.InvalidAmount.selector);
        assertFalse(highRateVault.transfer(recipient, firstInvalidPartialTransferAmountRay));
    }

    function test_transfer_fullAmountPreservesGuaranteedPrincipal_whenShareBackedBalanceIsLower() public {
        address user = makeAddr("user");
        address recipient = makeAddr("recipient");
        MockErc20 ghoToken = new MockErc20("GHO", "GHO", 18);

        uint256 highRate = 3 * MathLib.RAY;
        IStableVault highRateVault = _deployStableVault(
            address(mockAccessManager),
            highRate + 1,
            highRate,
            address(mockIouTokenManager),
            address(mockFundsHandler),
            address(mockAssetRegistry),
            address(mockTransferHelper),
            address(mockPriceOracle),
            DEFAULT_MAX_ACTIVE_SUB_VAULTS,
            treasury,
            address(policyRegistry)
        );

        vm.warp(block.timestamp + 1);

        uint256 depositAmount = 5;
        uint256 fullTransferAmountRay = depositAmount.assetDecimalsToRay(address(ghoToken));

        ghoToken.mint(user, depositAmount);
        vm.prank(user);
        ghoToken.approve(address(highRateVault), depositAmount);
        vm.prank(user);
        highRateVault.deposit(user, address(ghoToken), depositAmount, "");

        // The raw share-backed value is strictly below the original deposit due to deposit rounding; balanceOf now
        // surfaces the principal floor instead, so it reports the full amount.
        uint256 senderShareBackedBalanceRay = fullTransferAmountRay.rayDivDown(highRate).rayMulDown(highRate);
        assertEq(senderShareBackedBalanceRay, fullTransferAmountRay - 2);
        assertEq(highRateVault.getUserBalance(user), fullTransferAmountRay);

        // A `transfer` of the floored balance is rejected because the amount exceeds the share-backed value;
        // the full position, principal floor included, moves through transferAll() instead.
        vm.prank(user);
        vm.expectRevert(Errors.InsufficientFunds.selector);
        assertFalse(highRateVault.transfer(recipient, fullTransferAmountRay));

        vm.prank(user);
        assertTrue(highRateVault.transferAll(recipient));

        assertEq(highRateVault.getUserBalance(user), 0);
        // The recipient inherits the guaranteed principal, so their balance is floored to the full amount.
        assertEq(highRateVault.getUserBalance(recipient), fullTransferAmountRay);

        mockFundsHandler.mockAggregatedBalance(fullTransferAmountRay);

        vm.prank(recipient);
        uint256 iouTokenAmount = highRateVault.requestWithdrawal(recipient, 0, "");
        assertEq(iouTokenAmount, fullTransferAmountRay);
    }

    /// @dev balanceOf() floors at the user's original deposit. When deposit rounding leaves the share-backed
    /// balance below the principal, that floored balance exceeds the share-backed value, so a transfer of it
    /// reverts; the full position moves via transferAll() instead.
    function test_transfer_usingBalanceOf_reverts_whenShareBackedBalanceBelowPrincipal() public {
        address user = makeAddr("user");
        address recipient = makeAddr("recipient");
        MockErc20 ghoToken = new MockErc20("GHO", "GHO", 18);

        uint256 highRate = 3 * MathLib.RAY;
        IStableVault highRateVault = _deployStableVault(
            address(mockAccessManager),
            highRate + 1,
            highRate,
            address(mockIouTokenManager),
            address(mockFundsHandler),
            address(mockAssetRegistry),
            address(mockTransferHelper),
            address(mockPriceOracle),
            DEFAULT_MAX_ACTIVE_SUB_VAULTS,
            treasury,
            address(policyRegistry)
        );

        vm.warp(block.timestamp + 1);

        uint256 depositAmount = 5;
        uint256 depositAmountRay = depositAmount.assetDecimalsToRay(address(ghoToken));

        ghoToken.mint(user, depositAmount);
        vm.prank(user);
        ghoToken.approve(address(highRateVault), depositAmount);
        vm.prank(user);
        highRateVault.deposit(user, address(ghoToken), depositAmount, "");

        // The raw share-backed balance rounds 2 wei below the original deposit, while balanceOf surfaces the floor.
        assertEq(depositAmountRay.rayDivDown(highRate).rayMulDown(highRate), depositAmountRay - 2);
        uint256 balance = highRateVault.balanceOf(user);
        assertEq(balance, depositAmountRay);

        // balanceOf exceeds the share-backed value, so transfer() rejects it; the full position moves via
        // transferAll().
        vm.prank(user);
        vm.expectRevert(Errors.InsufficientFunds.selector);
        assertFalse(highRateVault.transfer(recipient, balance));

        vm.prank(user);
        assertTrue(highRateVault.transferAll(recipient));

        assertEq(highRateVault.balanceOf(user), 0);
        assertEq(highRateVault.getUserSubVault(user).id, 0);
        assertEq(highRateVault.balanceOf(recipient), depositAmountRay);
    }

    function test_transfer_toRecipientWithExistingPositionInDifferentSubVault(
        address user,
        address recipient,
        uint256 depositAmount,
        uint256 newPerSecondRate
    ) public {
        vm.assume(user != address(0));
        vm.assume(recipient != address(0));
        vm.assume(user != recipient);
        vm.assume(user != address(mockFundsHandler));
        vm.assume(recipient != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        _assumeNotProxyAdmin(recipient, address(stableVault));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);
        newPerSecondRate = _boundRate(newPerSecondRate);
        vm.assume(newPerSecondRate != stableVault.getDefaultSubVault().perSecondRate);

        // Both users deposit
        _deposit(user, depositAmount);
        _deposit(recipient, depositAmount);

        // Move recipient to different subVault
        _setUserRate(recipient, newPerSecondRate);
        uint256 recipientSubVaultId = stableVault.getUserSubVault(recipient).id;

        uint256 amountRay = stableVault.getUserBalance(user) / 4;
        vm.assume(amountRay >= Constants.MIN_WITHDRAWABLE_AMOUNT_RAY);

        uint256 recipientBalanceBefore = stableVault.getUserBalance(recipient);

        vm.prank(user);
        assertTrue(stableVault.transfer(recipient, amountRay));

        // Recipient stays in their original subVault
        assertEq(stableVault.getUserSubVault(recipient).id, recipientSubVaultId);
        // Recipient's balance increased by the transfer amount
        assertEq(stableVault.getUserBalance(recipient), recipientBalanceBefore + amountRay);
    }

    function test_transferAll_reverts_ifRecipientIsZero(address user, uint256 depositAmount) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);

        _deposit(user, depositAmount);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(user);
        stableVault.transferAll(address(0));
    }

    function test_transferAll_reverts_ifRecipientIsSender(address user, uint256 depositAmount) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);

        _deposit(user, depositAmount);

        vm.expectRevert(Errors.InvalidParameter.selector);
        vm.prank(user);
        stableVault.transferAll(user);
    }

    function test_transferAll_reverts_ifUserDoesNotHaveAPosition(address user, address recipient) public {
        vm.assume(user != address(0));
        vm.assume(recipient != address(0));
        vm.assume(user != recipient);
        _assumeNotProxyAdmin(user, address(stableVault));
        _assumeNotProxyAdmin(recipient, address(stableVault));

        vm.expectRevert(IStableVault.NonExistentPosition.selector);
        vm.prank(user);
        stableVault.transferAll(recipient);
    }

    function test_transferAll_allowsMinimumAmount() public {
        address user = makeAddr("user");
        address recipient = makeAddr("recipient");
        vm.assume(user != address(0));
        vm.assume(recipient != address(0));
        vm.assume(user != recipient);
        _assumeNotProxyAdmin(user, address(stableVault));
        _assumeNotProxyAdmin(recipient, address(stableVault));

        IMockErc20 mockAsset18dp = IMockErc20(address(new MockNonStandardErc20("Test GHO", "tGHO", 18)));
        uint256 amount = 1;
        mockAsset18dp.mint(user, amount);
        vm.prank(user);
        mockAsset18dp.forceApprove(address(stableVault), amount);
        vm.prank(user);
        stableVault.deposit(user, address(mockAsset18dp), amount, "");

        vm.prank(user);
        assertTrue(stableVault.transferAll(recipient));
    }

    function test_transferAll_allowsFullBalanceBelowMinimum() public {
        // Goal: create a sender whose full withdrawable amount is < MIN_WITHDRAWABLE_AMOUNT_RAY,
        // then confirm transferAll() still succeeds.
        //
        // We do this by:
        // 1) Making a donor with originalDepositRay == 0 (withdraw principal, keep only interest shares),
        // 2) Transferring exactly MIN_WITHDRAWABLE_AMOUNT_RAY from the donor to a new user in a vault where
        //    rayDivDown/rayMulDown produces MIN-1 value,
        // 3) Calling transferAll() from that user and asserting it succeeds.

        address donor = makeAddr("donor");
        address dustSender = makeAddr("dustSender");
        address recipient = makeAddr("recipient");
        _assumeNotProxyAdmin(donor, address(stableVault));
        _assumeNotProxyAdmin(dustSender, address(stableVault));
        _assumeNotProxyAdmin(recipient, address(stableVault));

        uint256 depositAmount = 2_000_000;
        uint256 depositRay = depositAmount.assetDecimalsToRay(address(mockAsset));

        // Put the donor into a higher-rate vault so we can withdraw principal and still keep
        // enough interest shares remaining (so the position is not auto-closed).
        vm.prank(manager);
        stableVault.setDefaultSubVault(DEFAULT_MAX_PER_SECOND_RATE);

        _deposit(donor, depositAmount);
        mockFundsHandler.mockAggregatedBalance(10e27);
        vm.warp(block.timestamp + 365 days);

        // Withdraw exactly the original deposit amount, leaving only interest shares => originalDepositRay becomes 0.
        vm.prank(donor);
        stableVault.requestWithdrawal(donor, depositRay, "");

        // Now assign the dust receiver to a slightly-growing default subVault so we can deterministically
        // hit the MIN-1 rounding case on `amountRay.rayDivDown(conversionRate)`.
        vm.prank(manager);
        stableVault.setDefaultSubVault(MathLib.RAY + 1);
        vm.warp(block.timestamp + 1);

        // Transfer MIN from an interest-only donor (so guaranteedAmountRay == 0 for the receiver).
        vm.prank(donor);
        assertTrue(stableVault.transfer(dustSender, Constants.MIN_WITHDRAWABLE_AMOUNT_RAY));

        uint256 dustSenderBalanceRay = stableVault.getUserBalance(dustSender);
        assertLt(dustSenderBalanceRay, Constants.MIN_WITHDRAWABLE_AMOUNT_RAY);
        assertEq(dustSenderBalanceRay, Constants.MIN_WITHDRAWABLE_AMOUNT_RAY - 1);

        vm.prank(dustSender);
        assertTrue(stableVault.transferAll(recipient));

        assertEq(stableVault.getUserBalance(dustSender), 0);
        assertEq(stableVault.getUserSubVault(dustSender).id, 0);
        assertEq(stableVault.getUserBalance(recipient), dustSenderBalanceRay);
    }

    function test_transferAll_reverts_ifRecipientGetsZeroShares() public {
        // Override stableVault with a low default sub-vault rate (RAY = no interest)
        // and use an 18-decimal asset so 1 wei deposit = 1e9 RAY = MIN_WITHDRAWABLE_AMOUNT_RAY
        stableVault = _deployStableVault(
            address(mockAccessManager),
            DEFAULT_MAX_PER_SECOND_RATE,
            MathLib.RAY,
            address(mockIouTokenManager),
            address(mockFundsHandler),
            address(mockAssetRegistry),
            address(mockTransferHelper),
            address(mockPriceOracle),
            DEFAULT_MAX_ACTIVE_SUB_VAULTS,
            treasury,
            address(policyRegistry)
        );
        mockAsset = IMockErc20(address(new MockNonStandardErc20("Test GHO", "tGHO", 18)));

        uint256 highRate = DEFAULT_MAX_PER_SECOND_RATE;

        address user = makeAddr("user");
        address recipient = makeAddr("recipient");
        uint256 amount = 1;

        // Deposit for recipient and move them to high rate subVault
        mockAsset.mint(recipient, amount);
        vm.prank(recipient);
        mockAsset.forceApprove(address(stableVault), amount);
        vm.prank(recipient);
        stableVault.deposit(recipient, address(mockAsset), amount, "");

        IStableVault.UserRateData[] memory userRateData = new IStableVault.UserRateData[](1);
        userRateData[0] = IStableVault.UserRateData(recipient, highRate);
        vm.prank(manager);
        stableVault.setUserRate(userRateData);

        // Warp time to grow recipient's subVault conversion rate
        // At 20% APY for 115 years: 1.2^115 ≈ 1e9, so conversionRate ≈ 1e36
        vm.warp(block.timestamp + 115 * 365 days);

        // Deposit for sender at base rate (RAY)
        mockAsset.mint(user, amount);
        vm.prank(user);
        mockAsset.forceApprove(address(stableVault), amount);
        vm.prank(user);
        stableVault.deposit(user, address(mockAsset), amount, "");

        // User has ~1e9 shares (deposited 1e9 RAY at conversionRate = RAY)
        // Recipient's subVault has conversionRate ≈ 1e36
        // toUserShares = fromUserShares * fromConversionRate / RAY / toConversionRate
        //              = 1e9 * 1e27 / 1e27 / 1e36 = 1e9 / 1e36 ≈ 0
        vm.prank(user);
        vm.expectRevert(Errors.InvalidAmount.selector);
        stableVault.transferAll(recipient);
    }

    function test_transferAll_allowsMinimumAmount_evenWhenRoundingWouldBeBelowMinShares() public {
        address user = makeAddr("user");
        address recipient = makeAddr("recipient");
        IMockErc20 mockAsset18dp = IMockErc20(address(new MockNonStandardErc20("Test GHO", "tGHO", 18)));

        // Create the higher-rate subVault, then return default to base rate.
        vm.prank(manager);
        stableVault.setDefaultSubVault(MathLib.RAY);
        vm.prank(manager);
        stableVault.setDefaultSubVault(MathLib.RAY + 1);
        vm.prank(manager);
        stableVault.setDefaultSubVault(MathLib.RAY);

        mockAsset18dp.mint(user, 1);
        vm.prank(user);
        mockAsset18dp.forceApprove(address(stableVault), 1);
        vm.prank(user);
        stableVault.deposit(user, address(mockAsset18dp), 1, "");

        vm.warp(block.timestamp + 1);
        vm.prank(manager);
        _setUserRate(user, MathLib.RAY + 1);

        vm.prank(user);
        assertTrue(stableVault.transferAll(recipient));
    }

    function test_transferAll_allowsSmallAmounts_evenWhenRoundingIsUnfavorable(uint256 amountDelta) public {
        address user = makeAddr("user");
        address recipient = makeAddr("recipient");
        IMockErc20 mockAsset18dp = IMockErc20(address(new MockNonStandardErc20("Test GHO", "tGHO", 18)));

        amountDelta = bound(amountDelta, 0, 3);

        vm.prank(manager);
        stableVault.setDefaultSubVault(MathLib.RAY + 1);
        vm.warp(block.timestamp + 1);

        uint256 amount = 1 + amountDelta;
        mockAsset18dp.mint(user, amount);
        vm.prank(user);
        mockAsset18dp.forceApprove(address(stableVault), amount);
        vm.prank(user);
        stableVault.deposit(user, address(mockAsset18dp), amount, "");

        vm.prank(user);
        assertTrue(stableVault.transferAll(recipient));
    }

    function test_transferAll_succeeds_whenDustSenderAndRecipientCombine() public {
        address user = makeAddr("user");
        address recipient = makeAddr("recipient");
        IMockErc20 mockAsset18dp = IMockErc20(address(new MockNonStandardErc20("Test GHO", "tGHO", 18)));

        // Create the higher-rate subVault, then return default to base rate.
        vm.prank(manager);
        stableVault.setDefaultSubVault(MathLib.RAY);
        vm.prank(manager);
        stableVault.setDefaultSubVault(MathLib.RAY + 1);
        vm.prank(manager);
        stableVault.setDefaultSubVault(MathLib.RAY);

        mockAsset18dp.mint(user, 1);
        vm.prank(user);
        mockAsset18dp.forceApprove(address(stableVault), 1);
        vm.prank(user);
        stableVault.deposit(user, address(mockAsset18dp), 1, "");

        mockAsset18dp.mint(recipient, 1);
        vm.prank(recipient);
        mockAsset18dp.forceApprove(address(stableVault), 1);
        vm.prank(recipient);
        stableVault.deposit(recipient, address(mockAsset18dp), 1, "");

        vm.warp(block.timestamp + 1);
        vm.prank(manager);
        _setUserRate(user, MathLib.RAY + 1);
        vm.prank(manager);
        _setUserRate(recipient, MathLib.RAY + 1);

        vm.prank(user);
        assertTrue(stableVault.transferAll(recipient));
    }

    function test_transferAll_emitsTransferEvent(address user, address recipient, uint256 depositAmount) public {
        vm.assume(user != address(0));
        vm.assume(recipient != address(0));
        vm.assume(user != recipient);
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        _assumeNotProxyAdmin(recipient, address(stableVault));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);

        _deposit(user, depositAmount);
        uint256 fullAmountRay = stableVault.getUserBalance(user);

        vm.expectEmit(true, true, true, true);
        emit IStableVault.Transfer(user, recipient, fullAmountRay);

        vm.prank(user);
        stableVault.transferAll(recipient);
    }

    function test_transferAll_crossSubVault(
        address user,
        address recipient,
        uint256 depositAmount,
        uint256 newPerSecondRate
    ) public {
        vm.assume(user != address(0));
        vm.assume(recipient != address(0));
        vm.assume(user != recipient);
        vm.assume(user != address(mockFundsHandler));
        vm.assume(recipient != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        _assumeNotProxyAdmin(recipient, address(stableVault));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);
        newPerSecondRate = _boundRate(newPerSecondRate);
        vm.assume(newPerSecondRate != stableVault.getDefaultSubVault().perSecondRate);

        // Deposit for both users
        _deposit(user, depositAmount);
        _deposit(recipient, depositAmount);

        // Move recipient to different subVault
        _setUserRate(recipient, newPerSecondRate);
        uint256 recipientSubVaultId = stableVault.getUserSubVault(recipient).id;

        uint256 userFullAmount = stableVault.getUserBalance(user);
        uint256 recipientBalanceBefore = stableVault.getUserBalance(recipient);

        vm.prank(user);
        assertTrue(stableVault.transferAll(recipient));

        // User's position is deleted
        assertEq(stableVault.getUserBalance(user), 0);
        assertEq(stableVault.getUserSubVault(user).id, 0);

        // Recipient stays in their subVault with increased balance
        assertEq(stableVault.getUserSubVault(recipient).id, recipientSubVaultId);
        assertEq(stableVault.getUserBalance(recipient), recipientBalanceBefore + userFullAmount);
    }

    function test_transferAll_toNewRecipientAssignsDefaultSubVault(
        address user,
        address recipient,
        uint256 depositAmount
    ) public {
        vm.assume(user != address(0));
        vm.assume(recipient != address(0));
        vm.assume(user != recipient);
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        _assumeNotProxyAdmin(recipient, address(stableVault));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);

        _deposit(user, depositAmount);
        uint256 fullAmountRay = stableVault.getUserBalance(user);

        // Recipient has no position
        assertEq(stableVault.getUserSubVault(recipient).id, 0);

        vm.prank(user);
        assertTrue(stableVault.transferAll(recipient));

        // Recipient is assigned the default subVault
        assertEq(stableVault.getUserSubVault(recipient).id, stableVault.getDefaultSubVault().id);
        assertEq(stableVault.getUserBalance(recipient), fullAmountRay);
    }

    function test_transferAll_sameSubVaultOptimizesAccrual(address user, address recipient, uint256 depositAmount)
        public
    {
        vm.assume(user != address(0));
        vm.assume(recipient != address(0));
        vm.assume(user != recipient);
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        _assumeNotProxyAdmin(recipient, address(stableVault));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);

        // Both users in same subVault (default)
        _deposit(user, depositAmount);
        _deposit(recipient, depositAmount);

        uint256 userFullAmount = stableVault.getUserBalance(user);
        uint256 recipientBalanceBefore = stableVault.getUserBalance(recipient);

        // Warp time to accumulate interest
        vm.warp(block.timestamp + 100);

        vm.prank(user);
        assertTrue(stableVault.transferAll(recipient));

        assertEq(stableVault.getUserBalance(user), 0);
        // Both were in same subVault, so transfer is 1:1 in shares (converted to value)
        assertGe(stableVault.getUserBalance(recipient), recipientBalanceBefore + userFullAmount);
    }

    function test_moveShares_reverts_ifSameUserAndPositionNotFullyMigrated(uint256 partialSharesToMove) public {
        StableVaultHarness stableVaultHarness = _deployStableVaultHarness(
            address(mockAccessManager),
            DEFAULT_MAX_PER_SECOND_RATE,
            DEFAULT_PER_SECOND_RATE,
            address(mockIouTokenManager),
            address(mockFundsHandler),
            address(mockAssetRegistry),
            address(mockTransferHelper),
            address(mockPriceOracle),
            DEFAULT_MAX_ACTIVE_SUB_VAULTS,
            treasury,
            address(policyRegistry)
        );

        address user = makeAddr("user");
        uint256 depositAmount = 2_000_000;
        mockAsset.mint(user, depositAmount);
        vm.prank(user);
        mockAsset.forceApprove(address(stableVaultHarness), depositAmount);
        vm.prank(user);
        stableVaultHarness.deposit(user, address(mockAsset), depositAmount, "");

        uint256 userSubVaultId = stableVaultHarness.getUserSubVault(user).id;
        uint256 fullShares = stableVaultHarness.previewFullWithdrawalSharesHarness(user);
        assertGt(fullShares, 1);
        partialSharesToMove = bound(partialSharesToMove, 1, fullShares - 1);

        vm.expectRevert(Errors.InvalidAmount.selector);
        stableVaultHarness.moveSharesHarness({
            from: user,
            to: user,
            fromSubVaultId: userSubVaultId,
            toSubVaultId: userSubVaultId,
            sharesToBurn: partialSharesToMove,
            sharesToMint: partialSharesToMove,
            guaranteedAmountToMoveRay: 0
        });
    }

    function test_moveShares_reverts_ifSameUserAndGuaranteedAmountIsNonZero(uint256 guaranteedAmountToMoveRay) public {
        StableVaultHarness stableVaultHarness = _deployStableVaultHarness(
            address(mockAccessManager),
            DEFAULT_MAX_PER_SECOND_RATE,
            DEFAULT_PER_SECOND_RATE,
            address(mockIouTokenManager),
            address(mockFundsHandler),
            address(mockAssetRegistry),
            address(mockTransferHelper),
            address(mockPriceOracle),
            DEFAULT_MAX_ACTIVE_SUB_VAULTS,
            treasury,
            address(policyRegistry)
        );

        address user = makeAddr("user");
        uint256 depositAmount = 2_000_000;
        mockAsset.mint(user, depositAmount);
        vm.prank(user);
        mockAsset.forceApprove(address(stableVaultHarness), depositAmount);
        vm.prank(user);
        stableVaultHarness.deposit(user, address(mockAsset), depositAmount, "");

        uint256 userSubVaultId = stableVaultHarness.getUserSubVault(user).id;
        uint256 fullShares = stableVaultHarness.previewFullWithdrawalSharesHarness(user);
        assertGt(fullShares, 0);
        guaranteedAmountToMoveRay = bound(guaranteedAmountToMoveRay, 1, depositAmount);

        vm.expectRevert(Errors.InvalidAmount.selector);
        stableVaultHarness.moveSharesHarness({
            from: user,
            to: user,
            fromSubVaultId: userSubVaultId,
            toSubVaultId: userSubVaultId,
            sharesToBurn: fullShares,
            sharesToMint: fullShares,
            guaranteedAmountToMoveRay: guaranteedAmountToMoveRay
        });
    }

    function test_transfer_reverts_ifMaxActiveSubVaultsReachedWhenActivatingDefaultSubVault() public {
        uint256 maxActiveSubVaults = 2;
        stableVault = _deployStableVault(
            address(mockAccessManager),
            DEFAULT_MAX_PER_SECOND_RATE,
            MathLib.RAY,
            address(mockIouTokenManager),
            address(mockFundsHandler),
            address(mockAssetRegistry),
            address(mockTransferHelper),
            address(mockPriceOracle),
            maxActiveSubVaults,
            treasury,
            address(policyRegistry)
        );

        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");
        address recipient = makeAddr("recipient");
        uint256 amount = 1_000_000;

        // Create two active non-default subVaults while keeping default empty/inactive.
        _deposit(user1, amount);
        vm.prank(manager);
        _setUserRate(user1, MathLib.RAY + 1);

        _deposit(user2, amount);
        vm.prank(manager);
        _setUserRate(user2, MathLib.RAY + 2);

        assertEq(stableVault.getActiveSubVaults().length, maxActiveSubVaults);

        uint256 amountRay = Constants.MIN_WITHDRAWABLE_AMOUNT_RAY;
        vm.expectRevert(IStableVault.TooManyActiveSubVaults.selector);
        vm.prank(user1);
        assertFalse(stableVault.transfer(recipient, amountRay));
    }

    function test_transferAll_reverts_ifMaxActiveSubVaultsReachedWhenActivatingDefaultSubVault() public {
        uint256 maxActiveSubVaults = 2;
        stableVault = _deployStableVault(
            address(mockAccessManager),
            DEFAULT_MAX_PER_SECOND_RATE,
            MathLib.RAY,
            address(mockIouTokenManager),
            address(mockFundsHandler),
            address(mockAssetRegistry),
            address(mockTransferHelper),
            address(mockPriceOracle),
            maxActiveSubVaults,
            treasury,
            address(policyRegistry)
        );

        address user1 = makeAddr("user1");
        address user2 = makeAddr("user2");
        address user3 = makeAddr("user3");
        address recipient = makeAddr("recipient");
        uint256 amount = 1_000_000;

        // Create two active non-default subVaults while keeping default empty/inactive.
        _deposit(user1, amount);
        vm.prank(manager);
        _setUserRate(user1, MathLib.RAY + 1);

        _deposit(user3, amount);
        vm.prank(manager);
        _setUserRate(user3, MathLib.RAY + 1);

        _deposit(user2, amount);
        vm.prank(manager);
        _setUserRate(user2, MathLib.RAY + 2);

        assertEq(stableVault.getActiveSubVaults().length, maxActiveSubVaults);

        vm.expectRevert(IStableVault.TooManyActiveSubVaults.selector);
        vm.prank(user1);
        assertFalse(stableVault.transferAll(recipient));
    }

    function test_transfer_partialTransferUpdatesOriginalDeposit(address user, address recipient, uint256 depositAmount)
        public
    {
        vm.assume(user != address(0));
        vm.assume(recipient != address(0));
        vm.assume(user != recipient);
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        _assumeNotProxyAdmin(recipient, address(stableVault));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);

        _deposit(user, depositAmount);
        uint256 amountRay = stableVault.getUserBalance(user) / 3;
        vm.assume(amountRay >= Constants.MIN_WITHDRAWABLE_AMOUNT_RAY);

        uint256 globalOriginalBefore = stableVault.getGlobalOriginalDepositAmount();

        vm.prank(user);
        assertTrue(stableVault.transfer(recipient, amountRay));

        // Global original deposit should remain unchanged (just moved between users)
        assertEq(stableVault.getGlobalOriginalDepositAmount(), globalOriginalBefore);
    }

    function test_transfer_afterTimePassedWithInterest(
        address user,
        address recipient,
        uint256 depositAmount,
        uint256 timePassed
    ) public {
        vm.assume(user != address(0));
        vm.assume(recipient != address(0));
        vm.assume(user != recipient);
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        _assumeNotProxyAdmin(recipient, address(stableVault));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);
        timePassed = bound(timePassed, 1, 365 days);

        _deposit(user, depositAmount);

        // Warp time to accumulate interest
        vm.warp(block.timestamp + timePassed);

        uint256 userBalanceWithInterest = stableVault.getUserBalance(user);
        uint256 amountRay = userBalanceWithInterest / 2;
        vm.assume(amountRay >= Constants.MIN_WITHDRAWABLE_AMOUNT_RAY);

        uint256 userBalanceBefore = stableVault.getUserBalance(user);

        vm.prank(user);
        assertTrue(stableVault.transfer(recipient, amountRay));

        // User's balance decreased by approximately the transfer amount
        // Due to rounding in share calculations, the actual decrease may differ by a few wei
        uint256 userBalanceAfter = stableVault.getUserBalance(user);
        uint256 expectedUserBalance = userBalanceBefore - amountRay;
        assertLe(userBalanceAfter, expectedUserBalance + 2, "User balance should decrease by ~amountRay");
        assertGe(
            userBalanceAfter, expectedUserBalance > 2 ? expectedUserBalance - 2 : 0, "User balance decreased too much"
        );

        // Recipient received approximately the transfer amount (may be slightly less due to rayDivDown rounding)
        uint256 recipientBalance = stableVault.getUserBalance(recipient);
        assertLe(recipientBalance, amountRay, "Recipient shouldn't receive more than requested");
        assertGe(recipientBalance, amountRay > 2 ? amountRay - 2 : 0, "Recipient received too little");
    }

    function test_transfer_multipleTransfersFromSameUser(address user, uint256 depositAmount) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);
        vm.assume(depositAmount >= 1_000_000); // Ensure enough for multiple transfers

        address recipient1 = makeAddr("recipient1");
        address recipient2 = makeAddr("recipient2");
        address recipient3 = makeAddr("recipient3");

        _deposit(user, depositAmount);
        uint256 initialBalance = stableVault.getUserBalance(user);
        uint256 transferAmount = initialBalance / 5;
        vm.assume(transferAmount >= Constants.MIN_WITHDRAWABLE_AMOUNT_RAY);

        vm.prank(user);
        assertTrue(stableVault.transfer(recipient1, transferAmount));

        vm.prank(user);
        assertTrue(stableVault.transfer(recipient2, transferAmount));

        vm.prank(user);
        assertTrue(stableVault.transfer(recipient3, transferAmount));

        assertEq(stableVault.getUserBalance(recipient1), transferAmount);
        assertEq(stableVault.getUserBalance(recipient2), transferAmount);
        assertEq(stableVault.getUserBalance(recipient3), transferAmount);
        assertEq(stableVault.getUserBalance(user), initialBalance - (transferAmount * 3));
    }

    function test_transfer_chainedTransfers(uint256 depositAmount) public {
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);

        address alice = makeAddr("alice");
        address bob = makeAddr("bob");
        address charlie = makeAddr("charlie");

        _deposit(alice, depositAmount);
        uint256 initialAmount = stableVault.getUserBalance(alice);

        // Alice -> Bob (full)
        vm.prank(alice);
        assertTrue(stableVault.transferAll(bob));

        assertEq(stableVault.getUserBalance(alice), 0);
        assertEq(stableVault.getUserBalance(bob), initialAmount);

        // Bob -> Charlie (full)
        vm.prank(bob);
        assertTrue(stableVault.transferAll(charlie));

        assertEq(stableVault.getUserBalance(bob), 0);
        assertEq(stableVault.getUserBalance(charlie), initialAmount);
    }

    function test_transfer_removesSubVaultFromActiveWhenEmpty(uint256 depositAmount, uint256 newPerSecondRate) public {
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);
        newPerSecondRate = _boundRate(newPerSecondRate);
        vm.assume(newPerSecondRate != stableVault.getDefaultSubVault().perSecondRate);

        address user = makeAddr("user");
        address recipient = makeAddr("recipient");

        _deposit(user, depositAmount);

        // Move user to a new subVault
        _setUserRate(user, newPerSecondRate);
        uint256 userSubVaultId = stableVault.getUserSubVault(user).id;

        // Verify the subVault is active
        IStableVault.SubVaultData[] memory activeSubVaultsBefore = stableVault.getActiveSubVaults();
        bool foundBefore = false;
        for (uint256 i = 0; i < activeSubVaultsBefore.length; i++) {
            if (activeSubVaultsBefore[i].id == userSubVaultId) {
                foundBefore = true;
                break;
            }
        }
        assertTrue(foundBefore, "SubVault should be active before transfer");

        // Transfer all to recipient (who will be in default subVault)
        vm.prank(user);
        assertTrue(stableVault.transferAll(recipient));

        // The user's original subVault should no longer be active (if it was only user)
        IStableVault.SubVaultData[] memory activeSubVaultsAfter = stableVault.getActiveSubVaults();
        bool foundAfter = false;
        for (uint256 i = 0; i < activeSubVaultsAfter.length; i++) {
            if (activeSubVaultsAfter[i].id == userSubVaultId) {
                foundAfter = true;
                break;
            }
        }
        assertFalse(foundAfter, "SubVault should be inactive after transferring all funds out");
    }

    function test_executeWithdrawal_reverts_ifIouAmountIsZero(address user) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));

        vm.expectRevert(Errors.ZeroAmount.selector);
        vm.prank(user);
        stableVault.executeWithdrawal(user, address(mockAsset), 0, 0, "");
    }

    function test_executeWithdrawal_reverts_ifMsgSenderIsNotTheUser(
        address user,
        address msgSender,
        uint256 iouAmountRay
    ) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        _assumeNotProxyAdmin(msgSender, address(stableVault));
        vm.assume(msgSender != user);
        iouAmountRay = bound(_boundRayAmount(iouAmountRay), 1, type(uint128).max - 1);
        mockIouToken.mint(user, iouAmountRay);

        vm.expectRevert(IStableVault.OnlyUser.selector);
        vm.prank(msgSender);
        stableVault.executeWithdrawal(user, address(mockAsset), 0, iouAmountRay, "");
    }

    function test_executeWithdrawal_reverts_ifAssetIsNotAllowedToWithdrawFromAllocator(
        address user,
        address msgSender,
        uint256 iouAmountRay
    ) public {
        // Context: user requests to withdraw shares of a strategy - this should revert since the strategy is not a
        // registered asset.
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        _assumeNotProxyAdmin(msgSender, address(stableVault));
        vm.assume(msgSender != user);
        iouAmountRay = bound(_boundRayAmount(iouAmountRay), 1, type(uint128).max - 1);
        vm.assume(iouAmountRay.rayToAssetDecimals(address(mockAsset)) > 0);
        mockIouToken.mint(user, iouAmountRay);

        vm.mockCall(
            address(mockWithdrawalExecutionPolicy),
            abi.encodeWithSelector(
                IWithdrawalExecutionPolicy.applyWithdrawalExecutionPolicy.selector, address(mockAsset), iouAmountRay
            ),
            abi.encode(iouAmountRay)
        );

        vm.mockCallRevert(
            address(mockFundsHandler),
            abi.encodeWithSelector(
                IFundsHandler.processWithdrawal.selector,
                address(mockAsset),
                iouAmountRay.rayToAssetDecimals(address(mockAsset))
            ),
            abi.encodeWithSelector(Errors.UnsupportedAsset.selector, address(mockAsset))
        );

        vm.expectRevert(abi.encodeWithSelector(Errors.UnsupportedAsset.selector, address(mockAsset)));
        vm.prank(user);
        stableVault.executeWithdrawal(user, address(mockAsset), 0, iouAmountRay, "");
    }

    function test_executeWithdrawal_reverts_ifIouAmountIsGreaterThanUserBalance(
        address user,
        uint256 userIouBalance,
        uint256 iouAmountRay
    ) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        userIouBalance = _boundRayAmountAllowingZero(userIouBalance);
        iouAmountRay = bound(_boundRayAmount(iouAmountRay), 1, type(uint128).max - 1);
        vm.assume(iouAmountRay > userIouBalance);
        mockIouToken.mint(user, userIouBalance);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user, userIouBalance, iouAmountRay)
        );
        vm.prank(user);
        stableVault.executeWithdrawal(user, address(mockAsset), 0, iouAmountRay, "");
    }

    function test_executeWithdrawal_reverts_ifAmountOutIsLessThanMinAmountOut(
        address user,
        uint256 userIouBalance,
        uint256 iouAmountRay,
        uint256 minAmountOut
    ) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        userIouBalance = _boundRayAmountAllowingZero(userIouBalance);
        iouAmountRay = bound(_boundRayAmount(iouAmountRay), 1, type(uint128).max - 1);
        vm.assume(iouAmountRay <= userIouBalance);
        mockIouToken.mint(user, userIouBalance);
        assertEq(mockIouToken.balanceOf(user), userIouBalance);
        vm.assume(iouAmountRay.rayToAssetDecimals(address(mockAsset)) > 0);
        uint256 actualWithdrawnAssets = iouAmountRay.rayToAssetDecimals(address(mockAsset));
        minAmountOut = bound(minAmountOut, actualWithdrawnAssets + 1, type(uint256).max);

        mockTransferHelper.mockAsset(address(mockAsset), actualWithdrawnAssets);

        vm.prank(user);
        vm.expectRevert(Errors.InsufficientAmountOut.selector);
        stableVault.executeWithdrawal(user, address(mockAsset), minAmountOut, iouAmountRay, "");
    }

    function test_executeWithdrawal_reverts_ifAssetAmountIsZero_fromWithdrawalFee(
        address user,
        uint256 userIouBalance,
        uint256 iouAmountRay
    ) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        userIouBalance = _boundRayAmountAllowingZero(userIouBalance);
        iouAmountRay = bound(_boundRayAmount(iouAmountRay), 1, type(uint128).max - 1);
        vm.assume(iouAmountRay <= userIouBalance);
        mockIouToken.mint(user, userIouBalance);
        assertEq(mockIouToken.balanceOf(user), userIouBalance);
        vm.assume(iouAmountRay.rayToAssetDecimals(address(mockAsset)) > 0);

        vm.mockCall(
            address(mockWithdrawalExecutionPolicy),
            abi.encodeWithSelector(IWithdrawalExecutionPolicy.applyWithdrawalExecutionPolicy.selector),
            abi.encode(uint256(0)) // amountOutRay = 0, simulating 100% fee
        );

        uint256 actualWithdrawnAssets = iouAmountRay.rayToAssetDecimals(address(mockAsset));
        mockTransferHelper.mockAsset(address(mockAsset), actualWithdrawnAssets);

        vm.prank(user);
        vm.expectRevert(Errors.InsufficientAmountOut.selector);
        stableVault.executeWithdrawal(user, address(mockAsset), 0, iouAmountRay, "");
    }

    function test_executeWithdrawal_emitsExpectedEvent(address user, uint256 iouAmountRay) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        iouAmountRay = bound(_boundRayAmount(iouAmountRay), 1, type(uint128).max - 1);
        mockIouToken.mint(user, iouAmountRay);

        uint256 actualWithdrawnAssets = iouAmountRay.rayToAssetDecimals(address(mockAsset));
        vm.assume(actualWithdrawnAssets > 0);
        mockTransferHelper.mockAsset(address(mockAsset), actualWithdrawnAssets);

        vm.expectEmit(true, true, true, true);
        emit IStableVault.WithdrawalExecuted(user, address(mockAsset), actualWithdrawnAssets);

        vm.prank(user);
        stableVault.executeWithdrawal(user, address(mockAsset), 0, iouAmountRay, "");
    }

    function test_executeWithdrawal_burnsExpectedAmountOfIouTokens(
        address user,
        uint256 userIouBalance,
        uint256 iouAmountRay
    ) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        userIouBalance = _boundRayAmountAllowingZero(userIouBalance);
        iouAmountRay = bound(_boundRayAmount(iouAmountRay), 1, type(uint128).max - 1);
        vm.assume(iouAmountRay <= userIouBalance);
        mockIouToken.mint(user, userIouBalance);
        assertEq(mockIouToken.balanceOf(user), userIouBalance);
        vm.assume(iouAmountRay.rayToAssetDecimals(address(mockAsset)) > 0);

        uint256 actualWithdrawnAssets = iouAmountRay.rayToAssetDecimals(address(mockAsset));
        mockTransferHelper.mockAsset(address(mockAsset), actualWithdrawnAssets);

        vm.prank(user);
        stableVault.executeWithdrawal(user, address(mockAsset), 0, iouAmountRay, "");

        assertEq(mockIouToken.balanceOf(user), userIouBalance - iouAmountRay);
    }

    function test_executeWithdrawal_transfersExpectedAmountOfAssetsToUser(address user, uint256 iouAmountRay) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        iouAmountRay = bound(_boundRayAmount(iouAmountRay), 1, type(uint128).max - 1);
        mockIouToken.mint(user, iouAmountRay);
        vm.assume(iouAmountRay.rayToAssetDecimals(address(mockAsset)) > 0);
        vm.assume(mockAsset.balanceOf(user) == 0);

        uint256 actualWithdrawnAssets = iouAmountRay.rayToAssetDecimals(address(mockAsset));
        mockTransferHelper.mockAsset(address(mockAsset), actualWithdrawnAssets);

        vm.prank(user);
        stableVault.executeWithdrawal(user, address(mockAsset), 0, iouAmountRay, "");

        assertEq(mockAsset.balanceOf(user), actualWithdrawnAssets);
    }

    /// @dev Defense-in-depth: the policy is expected to deduct a fee, so the post-fee amount must be `<= iouAmountRay`.
    /// A misconfigured or compromised policy returning more would otherwise inflate the withdrawal.
    function test_executeWithdrawal_reverts_ifPolicyReturnsMoreThanIouAmount(
        address user,
        uint256 iouAmountRay,
        uint256 policyReturnedAmountRay
    ) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        iouAmountRay = bound(_boundRayAmount(iouAmountRay), 1, type(uint128).max - 1);
        vm.assume(iouAmountRay < type(uint256).max);
        policyReturnedAmountRay = bound(policyReturnedAmountRay, iouAmountRay + 1, type(uint256).max);
        mockIouToken.mint(user, iouAmountRay);

        vm.mockCall(
            address(mockWithdrawalExecutionPolicy),
            abi.encodeWithSelector(IWithdrawalExecutionPolicy.applyWithdrawalExecutionPolicy.selector),
            abi.encode(policyReturnedAmountRay)
        );

        vm.prank(user);
        vm.expectRevert(Errors.InvalidAmount.selector);
        stableVault.executeWithdrawal(user, address(mockAsset), 0, iouAmountRay, "");
    }

    /// @dev When the withdrawal-execution policy is unregistered, the vault skips the policy call and treats the IOU
    /// amount as the post-fee amount, so the user withdraws the full `iouAmountRay` truncated to asset decimals.
    function test_executeWithdrawal_withdrawsFullIouAmountIfNoPolicyRegistered(address user, uint256 iouAmountRay)
        public
    {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(stableVault));
        iouAmountRay = bound(_boundRayAmount(iouAmountRay), 1, type(uint128).max - 1);
        mockIouToken.mint(user, iouAmountRay);
        uint256 expectedWithdrawnAssets = iouAmountRay.rayToAssetDecimals(address(mockAsset));
        vm.assume(expectedWithdrawnAssets > 0);
        vm.assume(mockAsset.balanceOf(user) == 0);
        mockTransferHelper.mockAsset(address(mockAsset), expectedWithdrawnAssets);

        policyRegistry.setPolicy(
            keccak256(bytes("aave.stable-vault.StableVault.policy.withdrawal-execution")), address(0)
        );

        vm.expectCall(
            address(mockWithdrawalExecutionPolicy),
            abi.encodeWithSelector(IWithdrawalExecutionPolicy.applyWithdrawalExecutionPolicy.selector),
            0
        );

        vm.prank(user);
        stableVault.executeWithdrawal(user, address(mockAsset), 0, iouAmountRay, "");

        assertEq(mockAsset.balanceOf(user), expectedWithdrawnAssets);
    }

    function test_rescueTokens_reverts_ifMsgSenderIsNotAuthorized(
        address unauthorizedMsgSender,
        uint256 stableVaultAssetBalance,
        uint256 assetAmountToRescue
    ) public {
        vm.assume(unauthorizedMsgSender != address(0));
        _assumeNotProxyAdmin(unauthorizedMsgSender, address(stableVault));
        vm.assume(unauthorizedMsgSender != manager);
        stableVaultAssetBalance = _boundAssetAmount(address(mockAsset), stableVaultAssetBalance);
        assetAmountToRescue = _boundAssetAmount(address(mockAsset), assetAmountToRescue);
        vm.assume(stableVaultAssetBalance >= assetAmountToRescue);
        mockAsset.mint(address(stableVault), stableVaultAssetBalance);

        mockAccessManager.mockRejectCall(
            unauthorizedMsgSender, address(stableVault), IRescuableToken.rescueTokens.selector
        );
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedMsgSender)
        );
        vm.prank(unauthorizedMsgSender);
        IRescuableToken(address(stableVault)).rescueTokens(address(mockAsset), assetAmountToRescue);
    }

    function test_rescueTokens_getsExpectedAmountOfAssetsToMsgSender(
        address msgSender,
        uint256 stableVaultAssetBalance,
        uint256 assetAmountToRescue
    ) public {
        vm.assume(msgSender != address(0));
        _assumeNotProxyAdmin(msgSender, address(stableVault));

        stableVaultAssetBalance = _boundAssetAmount(address(mockAsset), stableVaultAssetBalance);
        assetAmountToRescue = _boundAssetAmount(address(mockAsset), assetAmountToRescue);
        vm.assume(stableVaultAssetBalance >= assetAmountToRescue);
        mockAsset.mint(address(stableVault), stableVaultAssetBalance);
        assertEq(mockAsset.balanceOf(address(stableVault)), stableVaultAssetBalance);
        vm.assume(mockAsset.balanceOf(msgSender) == 0);

        vm.expectEmit(true, true, true, true);
        emit IRescuableToken.TokensRescued(address(mockAsset), msgSender, assetAmountToRescue);
        vm.prank(msgSender);
        IRescuableToken(address(stableVault)).rescueTokens(address(mockAsset), assetAmountToRescue);

        assertEq(mockAsset.balanceOf(msgSender), assetAmountToRescue);
        assertEq(mockAsset.balanceOf(address(stableVault)), stableVaultAssetBalance - assetAmountToRescue);
    }

    function test_executeWithdrawal_reentrancyNotAllowedOnRequestWithdrawal() public {
        address attacker = makeAddr("attacker");

        MockReentrantErc20 reentrantAsset = new MockReentrantErc20("Reentrant Token", "REENT", 18);

        // Attacker deposits the reentrant asset
        uint256 depositAmount = 1000e18;
        reentrantAsset.mint(attacker, depositAmount);

        vm.startPrank(attacker);
        reentrantAsset.approve(address(stableVault), depositAmount);
        stableVault.deposit(attacker, address(reentrantAsset), depositAmount, "");
        vm.stopPrank();

        // Request withdrawal to get IOUs
        uint256 depositAmountRay = depositAmount.assetDecimalsToRay(address(reentrantAsset));
        mockFundsHandler.mockAggregatedBalance(depositAmountRay);

        vm.prank(attacker);
        stableVault.requestWithdrawal(attacker, 0, "");

        uint256 iouBalance = mockIouToken.balanceOf(attacker);
        assertEq(iouBalance, depositAmountRay);

        // Setup the reentrant callback: when transfer() is called, re-enter requestWithdrawal
        // This simulates the attack where during executeWithdrawal:
        // 1. IOUs are burned (liabilities reduced)
        // 2. processWithdrawal is called
        // 3. transfer() is called on the reentrant token -> attacker re-enters requestWithdrawal
        // 4. At this point, liabilities are reduced but assets haven't left yet
        reentrantAsset.setReentrantCall(
            address(stableVault), abi.encodeCall(IStableVault.requestWithdrawal, (attacker, 0, ""))
        );

        // Mock the asset balance in transfer helper for the withdrawal
        mockTransferHelper.mockAssetBalance(address(reentrantAsset), depositAmount);

        // Execute withdrawal - should revert with ReentrancyGuardReentrantCall when trying to re-enter
        vm.prank(attacker);
        vm.expectRevert(ReentrancyGuardTransientUpgradeable.ReentrancyGuardReentrantCall.selector);
        stableVault.executeWithdrawal(attacker, address(reentrantAsset), 0, iouBalance, "");
    }

    function test_executeWithdrawal_reentrancyNotAllowedOnDeposit() public {
        address attacker = makeAddr("attacker");

        MockReentrantErc20 reentrantAsset = new MockReentrantErc20("Reentrant Token", "REENT", 18);

        // Attacker deposits the reentrant asset
        uint256 depositAmount = 1000e18;
        reentrantAsset.mint(attacker, depositAmount * 2); // Extra for potential reentrant deposit

        vm.startPrank(attacker);
        reentrantAsset.approve(address(stableVault), type(uint256).max);
        stableVault.deposit(attacker, address(reentrantAsset), depositAmount, "");
        vm.stopPrank();

        // Request withdrawal to get IOUs
        uint256 depositAmountRay = depositAmount.assetDecimalsToRay(address(reentrantAsset));
        mockFundsHandler.mockAggregatedBalance(depositAmountRay);

        vm.prank(attacker);
        stableVault.requestWithdrawal(attacker, 0, "");

        uint256 iouBalance = mockIouToken.balanceOf(attacker);

        // Setup the reentrant callback to deposit during transfer
        reentrantAsset.setReentrantCall(
            address(stableVault),
            abi.encodeCall(IStableVault.deposit, (attacker, address(reentrantAsset), depositAmount, ""))
        );

        // Mock the asset balance in transfer helper for the withdrawal
        mockTransferHelper.mockAssetBalance(address(reentrantAsset), depositAmount);

        // Execute withdrawal - should revert with ReentrancyGuardReentrantCall
        vm.prank(attacker);
        vm.expectRevert(ReentrancyGuardTransientUpgradeable.ReentrancyGuardReentrantCall.selector);
        stableVault.executeWithdrawal(attacker, address(reentrantAsset), 0, iouBalance, "");
    }

    function test_executeWithdrawal_reentrancyNotAllowedOnExecuteWithdrawal() public {
        address attacker = makeAddr("attacker");

        MockReentrantErc20 reentrantAsset = new MockReentrantErc20("Reentrant Token", "REENT", 18);

        // Attacker deposits the reentrant asset
        uint256 depositAmount = 1000e18;
        reentrantAsset.mint(attacker, depositAmount);

        vm.startPrank(attacker);
        reentrantAsset.approve(address(stableVault), depositAmount);
        stableVault.deposit(attacker, address(reentrantAsset), depositAmount, "");
        vm.stopPrank();

        // Request withdrawal to get IOUs
        uint256 depositAmountRay = depositAmount.assetDecimalsToRay(address(reentrantAsset));
        mockFundsHandler.mockAggregatedBalance(depositAmountRay);

        vm.prank(attacker);
        stableVault.requestWithdrawal(attacker, 0, "");

        uint256 iouBalance = mockIouToken.balanceOf(attacker);
        uint256 halfIou = iouBalance / 2;

        // Mint extra IOUs for the reentrant call attempt
        mockIouToken.mint(attacker, halfIou);

        // Setup the reentrant callback to executeWithdrawal during transfer
        reentrantAsset.setReentrantCall(
            address(stableVault),
            abi.encodeCall(IStableVault.executeWithdrawal, (attacker, address(reentrantAsset), 0, halfIou, ""))
        );

        // Mock the asset balance in transfer helper for the withdrawal
        mockTransferHelper.mockAssetBalance(address(reentrantAsset), depositAmount);

        // Execute withdrawal - should revert with ReentrancyGuardReentrantCall
        vm.prank(attacker);
        vm.expectRevert(ReentrancyGuardTransientUpgradeable.ReentrancyGuardReentrantCall.selector);
        stableVault.executeWithdrawal(attacker, address(reentrantAsset), 0, halfIou, "");
    }

    function test_deposit_reentrancyNotAllowedOnDeposit() public {
        address attacker = makeAddr("attacker");

        MockReentrantErc20 reentrantAsset = new MockReentrantErc20("Reentrant Token", "REENT", 18);

        uint256 depositAmount = 1000e18;
        reentrantAsset.mint(attacker, depositAmount * 2);

        vm.startPrank(attacker);
        reentrantAsset.approve(address(stableVault), type(uint256).max);
        vm.stopPrank();

        // Setup the reentrant callback to deposit during transferFrom
        reentrantAsset.setReentrantCall(
            address(stableVault),
            abi.encodeCall(IStableVault.deposit, (attacker, address(reentrantAsset), depositAmount, ""))
        );
        reentrantAsset.setReentrancyOnTransferFrom(true);

        // Deposit - should revert with ReentrancyGuardReentrantCall when trying to re-enter
        vm.prank(attacker);
        vm.expectRevert(ReentrancyGuardTransientUpgradeable.ReentrancyGuardReentrantCall.selector);
        stableVault.deposit(attacker, address(reentrantAsset), depositAmount, "");
    }

    function test_rescueNative_reverts_ifMsgSenderIsNotAuthorized(
        address unauthorizedMsgSender,
        uint256 stableVaultAssetBalance,
        uint256 assetAmountToRescue
    ) public {
        vm.assume(unauthorizedMsgSender != address(0));
        _assumeNotProxyAdmin(unauthorizedMsgSender, address(stableVault));
        vm.assume(unauthorizedMsgSender != manager);
        stableVaultAssetBalance = _boundNativeAmount(stableVaultAssetBalance);
        assetAmountToRescue = _boundNativeAmount(assetAmountToRescue);
        vm.assume(stableVaultAssetBalance >= assetAmountToRescue);
        vm.deal(address(stableVault), stableVaultAssetBalance);

        mockAccessManager.mockRejectCall(
            unauthorizedMsgSender, address(stableVault), IRescuableNative.rescueNative.selector
        );
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedMsgSender)
        );
        vm.prank(unauthorizedMsgSender);
        IRescuableNative(address(stableVault)).rescueNative(assetAmountToRescue);
    }

    function test_rescueNative_getsExpectedAmountOfNativeToMsgSender(
        uint256 stableVaultAssetBalance,
        uint256 assetAmountToRescue
    ) public {
        // Avoid fuzzing the msgSender address to avoid .call on precompiles and zero address.
        address msgSender = makeAddr("msgSender");

        stableVaultAssetBalance = _boundNativeAmount(stableVaultAssetBalance);
        assetAmountToRescue = _boundNativeAmount(assetAmountToRescue);
        vm.assume(stableVaultAssetBalance >= assetAmountToRescue);

        vm.deal(address(stableVault), stableVaultAssetBalance);
        vm.assume(address(msgSender).balance == 0);

        vm.expectEmit(true, true, true, true);
        emit IRescuableNative.NativeRescued(msgSender, assetAmountToRescue);
        vm.prank(msgSender);
        IRescuableNative(address(stableVault)).rescueNative(assetAmountToRescue);

        assertEq(address(msgSender).balance, assetAmountToRescue);
        assertEq(address(stableVault).balance, stableVaultAssetBalance - assetAmountToRescue);
    }

    ////////////////////////////// HELPERS ///////////////////////////////

    function _deposit(address user, uint256 amount) public {
        mockAsset.mint(user, amount);
        vm.prank(user);
        mockAsset.forceApprove(address(stableVault), amount);
        vm.prank(user);
        stableVault.deposit(user, address(mockAsset), amount, "");
    }

    function _setUserRate(address user, uint256 newPerSecondRate) public {
        IStableVault.UserRateData[] memory userRateData = new IStableVault.UserRateData[](1);
        userRateData[0] = IStableVault.UserRateData(user, newPerSecondRate);
        stableVault.setUserRate(userRateData);
    }

    function _generateNewUser() internal returns (address) {
        return _generateUser(userSeed++);
    }

    function _generateUser(uint256 seed) internal returns (address) {
        return makeAddr(string.concat("USER[", Strings.toString(seed), "]"));
    }
}

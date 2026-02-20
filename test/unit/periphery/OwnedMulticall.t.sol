// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Allocator} from "src/core/Allocator.sol";
import {IAllocator} from "src/interfaces/IAllocator.sol";
import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {OwnedMulticall} from "src/periphery/OwnedMulticall.sol";
import {Swapper} from "src/periphery/Swapper.sol";

import {PriceOracle} from "src/oracles/price/PriceOracle.sol";
import {TestWithHelpers} from "test/helpers/TestWithHelpers.sol";
import {MockAccessManager} from "test/mocks/MockAccessManager.sol";
import {MockAssetRegistry} from "test/mocks/MockAssetRegistry.sol";
import {IMockDex, MockDex} from "test/mocks/MockDex.sol";
import {IMockErc20} from "test/mocks/MockErc20.sol";
import {MockNonStandardErc20} from "test/mocks/MockNonStandardErc20.sol";
import {MockTransferHelper} from "test/mocks/MockTransferHelper.sol";
import {TestErc4626} from "test/mocks/TestErc4626.sol";

contract OwnedMulticallTest is TestWithHelpers {
    using MathLib for uint256;
    using AssetLib for uint256;
    using SafeERC20 for IERC20;

    uint8 constant STRATEGY_MAX_SLIPPAGE_AMOUNT = 10;

    address admin = makeAddr("ADMIN");
    address everyRoleAccount = makeAddr("EVERY_ROLE_ACCOUNT");
    address depositor = makeAddr("DEPOSITOR");
    address withdrawer = makeAddr("WITHDRAWER");
    address unauthorizedCaller = makeAddr("UNAUTHORIZED_CALLER");

    uint8 constant MAX_STRATEGIES_PER_ASSET = 15;

    MockAssetRegistry internal _mockAssetRegistry;
    MockAccessManager internal _mockAccessManager;
    IMockErc20 internal _mockUsdt;
    IMockErc20 internal _mockGho;
    TestErc4626 internal _defaultUsdtStrategy;
    TestErc4626 internal _extraUsdtStrategy;
    TestErc4626 internal _defaultGhoStrategy;
    TestErc4626 internal _extraGhoStrategy;
    MockDex internal _mockDex;
    PriceOracle internal _priceOracle;
    MockTransferHelper internal _mockTransferHelper;

    Allocator internal _allocator;
    Swapper internal _swapper;
    OwnedMulticall internal _ownedMulticall;

    function setUp() public {
        _mockAssetRegistry = new MockAssetRegistry();

        _mockUsdt = IMockErc20(address(new MockNonStandardErc20("Test USDT", "tUSDT", 6)));
        _mockAssetRegistry.mockRegisteredAsset(address(_mockUsdt));
        _mockGho = IMockErc20(address(new MockNonStandardErc20("Test GHO", "tGHO", 18)));
        _mockAssetRegistry.mockRegisteredAsset(address(_mockGho));

        _defaultUsdtStrategy = new TestErc4626(_mockUsdt);
        _extraUsdtStrategy = new TestErc4626(_mockUsdt);
        _defaultGhoStrategy = new TestErc4626(_mockGho);
        _extraGhoStrategy = new TestErc4626(_mockGho);

        _mockAccessManager = new MockAccessManager(admin);
        _mockDex = new MockDex();
        _priceOracle = _deployPriceOracle(address(_mockAccessManager), 9_995e23);
        _mockTransferHelper = new MockTransferHelper();

        _mockAssetPrice(address(_priceOracle), address(_mockUsdt), MathLib.RAY);
        _mockAssetPrice(address(_priceOracle), address(_mockGho), MathLib.RAY);
        _mockValidatePriceForAll(address(_priceOracle));

        vm.prank(admin);
        _mockAssetRegistry.setAssetConfig(
            address(_mockUsdt),
            IAssetRegistry.AssetConfig({
                depositFromUserAllowed: true,
                depositIntoAllocatorAllowed: true,
                swapInputTokenAllowed: true,
                swapOutputTokenAllowed: true
            })
        );
        vm.prank(admin);
        _mockAssetRegistry.setAssetConfig(
            address(_mockGho),
            IAssetRegistry.AssetConfig({
                depositFromUserAllowed: true,
                depositIntoAllocatorAllowed: true,
                swapInputTokenAllowed: true,
                swapOutputTokenAllowed: true
            })
        );

        _allocator = _deployAllocator(
            _mockAccessManager,
            address(_mockAssetRegistry),
            address(_priceOracle),
            address(_mockTransferHelper),
            MAX_STRATEGIES_PER_ASSET
        );

        // Deploy OwnedMulticall owned by everyRoleAccount
        // Call flow: everyRoleAccount -> OwnedMulticall -> Allocator.rebalance
        _ownedMulticall = new OwnedMulticall(everyRoleAccount);

        // Deploy Swapper owned by the Allocator
        _swapper = new Swapper(address(_allocator));

        // Set up strategy vaults
        vm.prank(admin);
        _allocator.addStrategy(address(_mockUsdt), address(_defaultUsdtStrategy), STRATEGY_MAX_SLIPPAGE_AMOUNT);
        vm.prank(admin);
        _allocator.addStrategy(address(_mockUsdt), address(_extraUsdtStrategy), STRATEGY_MAX_SLIPPAGE_AMOUNT);
        vm.prank(admin);
        _allocator.addStrategy(address(_mockGho), address(_defaultGhoStrategy), STRATEGY_MAX_SLIPPAGE_AMOUNT);
        vm.prank(admin);
        _allocator.addStrategy(address(_mockGho), address(_extraGhoStrategy), STRATEGY_MAX_SLIPPAGE_AMOUNT);

        vm.prank(everyRoleAccount);
        _allocator.setDefaultStrategy(address(_mockUsdt), address(_defaultUsdtStrategy));
        vm.prank(everyRoleAccount);
        _allocator.setDefaultStrategy(address(_mockGho), address(_defaultGhoStrategy));

        // Grant ONLY the OwnedMulticall the right to call Allocator.rebalance
        _mockAccessManager.mockAllowCall(address(_ownedMulticall), address(_allocator), IAllocator.rebalance.selector);
        // Explicitly reject everyRoleAccount from calling Allocator.rebalance directly
        _mockAccessManager.mockRejectCall(everyRoleAccount, address(_allocator), IAllocator.rebalance.selector);
    }

    function _deployAllocator(
        MockAccessManager mockAccessManager,
        address assetRegistry,
        address priceOracle,
        address transferHelper,
        uint8 maxStrategiesPerAsset
    ) internal returns (Allocator) {
        address allocatorImpl = address(
            new Allocator(assetRegistry, depositor, withdrawer, priceOracle, transferHelper, maxStrategiesPerAsset)
        );
        Allocator allocator = Allocator(
            address(
                new TransparentUpgradeableProxy(
                    allocatorImpl, address(this), abi.encodeCall(Allocator.initialize, (address(mockAccessManager)))
                )
            )
        );
        return allocator;
    }

    function test_constructor_setsOwner() public view {
        assertEq(_ownedMulticall.owner(), everyRoleAccount);
    }

    function test_constructor_reverts_ifZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableInvalidOwner.selector, address(0)));
        new OwnedMulticall(address(0));
    }

    function test_renounceOwnership_reverts_ifNotOwner() public {
        vm.prank(unauthorizedCaller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorizedCaller));
        _ownedMulticall.renounceOwnership();
    }

    function test_renounceOwnership_reverts_ifOwner() public {
        vm.prank(everyRoleAccount);
        vm.expectRevert(abi.encodeWithSelector(OwnedMulticall.RenounceOwnershipNotAllowed.selector));
        _ownedMulticall.renounceOwnership();
    }

    function test_aggregate_reverts_ifNotOwner() public {
        OwnedMulticall.Call[] memory calls = new OwnedMulticall.Call[](0);
        vm.prank(unauthorizedCaller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorizedCaller));
        _ownedMulticall.aggregate(calls);
    }

    function test_tryAggregate_reverts_ifNotOwner() public {
        OwnedMulticall.Call[] memory calls = new OwnedMulticall.Call[](0);
        vm.prank(unauthorizedCaller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorizedCaller));
        _ownedMulticall.tryAggregate(true, calls);
    }

    function test_aggregate3_reverts_ifNotOwner() public {
        OwnedMulticall.Call3[] memory calls = new OwnedMulticall.Call3[](0);
        vm.prank(unauthorizedCaller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorizedCaller));
        _ownedMulticall.aggregate3(calls);
    }

    function test_aggregate3Value_reverts_ifNotOwner() public {
        OwnedMulticall.Call3Value[] memory calls = new OwnedMulticall.Call3Value[](0);
        vm.prank(unauthorizedCaller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorizedCaller));
        _ownedMulticall.aggregate3Value(calls);
    }

    function test_blockAndAggregate_reverts_ifNotOwner() public {
        OwnedMulticall.Call[] memory calls = new OwnedMulticall.Call[](0);
        vm.prank(unauthorizedCaller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorizedCaller));
        _ownedMulticall.blockAndAggregate(calls);
    }

    function test_tryBlockAndAggregate_reverts_ifNotOwner() public {
        OwnedMulticall.Call[] memory calls = new OwnedMulticall.Call[](0);
        vm.prank(unauthorizedCaller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorizedCaller));
        _ownedMulticall.tryBlockAndAggregate(true, calls);
    }

    function test_everyRoleAccount_cannotCallRebalanceDirectly() public {
        IAllocator.RebalanceParams[] memory rebalanceParams = new IAllocator.RebalanceParams[](1);
        rebalanceParams[0] = IAllocator.RebalanceParams({
            deallocations: new IAllocator.DeallocationParams[](0),
            swaps: new IAllocator.SwapParams[](0),
            allocations: new IAllocator.AllocationParams[](0)
        });

        vm.prank(everyRoleAccount);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, everyRoleAccount));
        _allocator.rebalance(rebalanceParams);
    }

    function test_rebalance_viaOwnedMulticall_deallocateAndAllocate(uint256 depositAmount) public {
        depositAmount = _boundAssetAmount(address(_mockGho), depositAmount);

        // Deposit GHO into the default strategy on behalf of the Allocator
        _mockGho.mint(depositor, depositAmount);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockGho)).approve(address(_defaultGhoStrategy), depositAmount);
        vm.prank(depositor);
        _defaultGhoStrategy.deposit(depositAmount, address(_allocator));

        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), depositAmount);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), 0);

        // Build rebalance params: deallocate from default, allocate to extra
        IAllocator.DeallocationParams[] memory deallocations = new IAllocator.DeallocationParams[](1);
        deallocations[0] = IAllocator.DeallocationParams({
            asset: address(_mockGho), strategy: address(_defaultGhoStrategy), amount: depositAmount
        });

        IAllocator.AllocationParams[] memory allocations = new IAllocator.AllocationParams[](1);
        allocations[0] = IAllocator.AllocationParams({
            asset: address(_mockGho), strategy: address(_extraGhoStrategy), amount: depositAmount
        });

        IAllocator.RebalanceParams[] memory rebalanceParams = new IAllocator.RebalanceParams[](1);
        rebalanceParams[0] = IAllocator.RebalanceParams({
            deallocations: deallocations, swaps: new IAllocator.SwapParams[](0), allocations: allocations
        });

        // Build OwnedMulticall call: everyRoleAccount -> OwnedMulticall -> Allocator.rebalance
        OwnedMulticall.Call3[] memory calls = new OwnedMulticall.Call3[](1);
        calls[0] = OwnedMulticall.Call3({
            target: address(_allocator),
            allowFailure: false,
            callData: abi.encodeCall(IAllocator.rebalance, (rebalanceParams))
        });

        vm.prank(everyRoleAccount);
        _ownedMulticall.aggregate3(calls);

        // Verify the rebalance moved GHO from default to extra strategy
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_extraGhoStrategy)), depositAmount);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), depositAmount);
    }

    function test_rebalance_viaOwnedMulticall_swapWithSlippageCoverage(uint256 amountIn, uint16 slippageToleranceBps)
        public
    {
        // Context: we are swapping USDT -> GHO with slippage coverage from OwnedMulticall
        vm.assume(slippageToleranceBps <= 10_000);
        amountIn = _boundAssetAmount(address(_mockUsdt), amountIn);
        uint256 amountOutIfNoSlippage = amountIn.convertAssetDecimals(address(_mockUsdt), address(_mockGho));
        uint256 minAmountOut = amountOutIfNoSlippage * (10_000 - slippageToleranceBps) / 10_000;
        vm.assume(minAmountOut > 0);
        vm.assume(amountOutIfNoSlippage > 0);

        uint256 slippageAmount = amountOutIfNoSlippage - minAmountOut;

        // Deposit USDT into the default strategy on behalf of the Allocator
        _mockUsdt.mint(depositor, amountIn);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_defaultUsdtStrategy), amountIn);
        vm.prank(depositor);
        _defaultUsdtStrategy.deposit(amountIn, address(_allocator));

        // Seed mock DEX with minAmountOut of GHO (simulating slippage)
        _mockGho.mint(address(_mockDex), minAmountOut);
        _mockDex.setSlippageBps(slippageToleranceBps);

        // Mint slippage coverage tokens to the OwnedMulticall
        _mockGho.mint(address(_ownedMulticall), slippageAmount);

        // Build swap data that encodes the DEX call + slippage params with OwnedMulticall as slippageCoverageSource
        bytes memory swapData =
            _buildSwapData(address(_mockUsdt), address(_mockGho), amountIn, minAmountOut, slippageToleranceBps);

        // Build rebalance params: deallocate USDT, swap USDT->GHO, allocate GHO
        IAllocator.RebalanceParams[] memory rebalanceParams = _buildEntireFlowRebalanceParams(
            address(_mockUsdt), address(_mockGho), amountIn, amountOutIfNoSlippage, swapData
        );

        // Batch approve + rebalance into a single aggregate3 call:
        // everyRoleAccount -> OwnedMulticall -> [approve slippage tokens, rebalance]
        uint256 numCalls = slippageAmount > 0 ? 2 : 1;
        OwnedMulticall.Call3[] memory multicallCalls = new OwnedMulticall.Call3[](numCalls);
        uint256 idx = 0;
        if (slippageAmount > 0) {
            multicallCalls[idx] = OwnedMulticall.Call3({
                target: address(_mockGho),
                allowFailure: false,
                callData: abi.encodeCall(IERC20.approve, (address(_swapper), slippageAmount))
            });
            idx++;
        }
        multicallCalls[idx] = OwnedMulticall.Call3({
            target: address(_allocator),
            allowFailure: false,
            callData: abi.encodeCall(IAllocator.rebalance, (rebalanceParams))
        });

        vm.prank(everyRoleAccount);
        _ownedMulticall.aggregate3(multicallCalls);

        // Verify: USDT fully deallocated, GHO allocated at 1:1 (slippage covered)
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), amountOutIfNoSlippage);
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), 0);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), amountOutIfNoSlippage);
        // OwnedMulticall slippage tokens should have been consumed
        assertEq(IERC20(address(_mockGho)).balanceOf(address(_ownedMulticall)), 0);
    }

    function test_rebalance_viaOwnedMulticall_entireFlow(uint256 amountIn) public {
        amountIn = _boundAssetAmount(address(_mockUsdt), amountIn);
        uint256 amountOut = amountIn.convertAssetDecimals(address(_mockUsdt), address(_mockGho));
        vm.assume(amountOut > 0);

        // Deposit USDT into strategy on behalf of the Allocator
        _mockUsdt.mint(depositor, amountIn);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_defaultUsdtStrategy), amountIn);
        vm.prank(depositor);
        _defaultUsdtStrategy.deposit(amountIn, address(_allocator));

        // Seed mock DEX with output tokens (no slippage)
        _mockGho.mint(address(_mockDex), amountOut);
        _mockDex.setSlippageBps(0);

        bytes memory swapData = _buildSwapData(address(_mockUsdt), address(_mockGho), amountIn, amountOut, 0);
        OwnedMulticall.Call3[] memory multicallCalls = _wrapRebalanceInMulticall(
            _buildEntireFlowRebalanceParams(address(_mockUsdt), address(_mockGho), amountIn, amountOut, swapData)
        );

        // Execute: everyRoleAccount -> OwnedMulticall -> Allocator.rebalance
        vm.prank(everyRoleAccount);
        _ownedMulticall.aggregate3(multicallCalls);

        // Verify final state
        assertEq(_allocator.getAssetBalance(address(_mockUsdt)), 0);
        assertEq(_allocator.getAssetBalance(address(_mockGho)), amountOut);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultUsdtStrategy)), 0);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), amountOut);
    }

    function test_rebalance_viaOwnedMulticall_reverts_ifCallerIsNotOwner() public {
        IAllocator.RebalanceParams[] memory rebalanceParams = new IAllocator.RebalanceParams[](1);
        rebalanceParams[0] = IAllocator.RebalanceParams({
            deallocations: new IAllocator.DeallocationParams[](0),
            swaps: new IAllocator.SwapParams[](0),
            allocations: new IAllocator.AllocationParams[](0)
        });

        OwnedMulticall.Call3[] memory calls = new OwnedMulticall.Call3[](1);
        calls[0] = OwnedMulticall.Call3({
            target: address(_allocator),
            allowFailure: false,
            callData: abi.encodeCall(IAllocator.rebalance, (rebalanceParams))
        });

        vm.prank(unauthorizedCaller);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorizedCaller));
        _ownedMulticall.aggregate3(calls);
    }

    function test_viewFunctions_areAccessible() public view {
        _ownedMulticall.getBlockNumber();
        _ownedMulticall.getCurrentBlockTimestamp();
        _ownedMulticall.getChainId();
        _ownedMulticall.getCurrentBlockGasLimit();
        _ownedMulticall.getBasefee();
    }

    function test_aggregate_viaOwner_succeeds() public {
        uint256 amount = 1000 ether;
        _mockGho.mint(address(_allocator), amount);

        // Build rebalance to deposit idle GHO into the default strategy
        IAllocator.AllocationParams[] memory allocations = new IAllocator.AllocationParams[](1);
        allocations[0] = IAllocator.AllocationParams({
            asset: address(_mockGho),
            strategy: address(_defaultGhoStrategy),
            // 0 = allocate all idle
            amount: 0
        });

        IAllocator.RebalanceParams[] memory rebalanceParams = new IAllocator.RebalanceParams[](1);
        rebalanceParams[0] = IAllocator.RebalanceParams({
            deallocations: new IAllocator.DeallocationParams[](0),
            swaps: new IAllocator.SwapParams[](0),
            allocations: allocations
        });

        OwnedMulticall.Call[] memory calls = new OwnedMulticall.Call[](1);
        calls[0] = OwnedMulticall.Call({
            target: address(_allocator), callData: abi.encodeCall(IAllocator.rebalance, (rebalanceParams))
        });

        vm.prank(everyRoleAccount);
        (, bytes[] memory returnData) = _ownedMulticall.aggregate(calls);
        assertEq(returnData.length, 1);
        assertEq(_allocator.getAssetBalanceInStrategy(address(_defaultGhoStrategy)), amount);
    }

    function test_aggregate_reverts_whenDexReverts(uint256 amountIn) public {
        amountIn = _boundAssetAmount(address(_mockUsdt), amountIn);
        uint256 amountOut = amountIn.convertAssetDecimals(address(_mockUsdt), address(_mockGho));
        vm.assume(amountOut > 0);

        // Deposit USDT into strategy on behalf of the Allocator
        _mockUsdt.mint(depositor, amountIn);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_defaultUsdtStrategy), amountIn);
        vm.prank(depositor);
        _defaultUsdtStrategy.deposit(amountIn, address(_allocator));

        // Do NOT seed the DEX with output tokens so it reverts with InsufficientLiquidity
        bytes memory swapData = _buildSwapData(address(_mockUsdt), address(_mockGho), amountIn, amountOut, 0);
        IAllocator.RebalanceParams[] memory rebalanceParams =
            _buildEntireFlowRebalanceParams(address(_mockUsdt), address(_mockGho), amountIn, amountOut, swapData);

        OwnedMulticall.Call[] memory calls = new OwnedMulticall.Call[](1);
        calls[0] = OwnedMulticall.Call({
            target: address(_allocator), callData: abi.encodeCall(IAllocator.rebalance, (rebalanceParams))
        });

        vm.prank(everyRoleAccount);
        vm.expectRevert("Multicall3: call failed");
        _ownedMulticall.aggregate(calls);
    }

    function test_aggregate3_reverts_whenDexReverts(uint256 amountIn) public {
        amountIn = _boundAssetAmount(address(_mockUsdt), amountIn);
        uint256 amountOut = amountIn.convertAssetDecimals(address(_mockUsdt), address(_mockGho));
        vm.assume(amountOut > 0);

        // Deposit USDT into strategy on behalf of the Allocator
        _mockUsdt.mint(depositor, amountIn);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_defaultUsdtStrategy), amountIn);
        vm.prank(depositor);
        _defaultUsdtStrategy.deposit(amountIn, address(_allocator));

        // Do NOT seed the DEX with output tokens so it reverts with InsufficientLiquidity
        bytes memory swapData = _buildSwapData(address(_mockUsdt), address(_mockGho), amountIn, amountOut, 0);
        OwnedMulticall.Call3[] memory multicallCalls = _wrapRebalanceInMulticall(
            _buildEntireFlowRebalanceParams(address(_mockUsdt), address(_mockGho), amountIn, amountOut, swapData)
        );

        vm.prank(everyRoleAccount);
        vm.expectRevert("Multicall3: call failed");
        _ownedMulticall.aggregate3(multicallCalls);
    }

    function test_aggregate3_allowFailure_capturesDexRevert(uint256 amountIn) public {
        amountIn = _boundAssetAmount(address(_mockUsdt), amountIn);
        uint256 amountOut = amountIn.convertAssetDecimals(address(_mockUsdt), address(_mockGho));
        vm.assume(amountOut > 0);

        // Deposit USDT into strategy on behalf of the Allocator
        _mockUsdt.mint(depositor, amountIn);
        vm.prank(depositor);
        MockNonStandardErc20(address(_mockUsdt)).approve(address(_defaultUsdtStrategy), amountIn);
        vm.prank(depositor);
        _defaultUsdtStrategy.deposit(amountIn, address(_allocator));

        // Do NOT seed the DEX with output tokens so it reverts with InsufficientLiquidity
        bytes memory swapData = _buildSwapData(address(_mockUsdt), address(_mockGho), amountIn, amountOut, 0);
        IAllocator.RebalanceParams[] memory rebalanceParams =
            _buildEntireFlowRebalanceParams(address(_mockUsdt), address(_mockGho), amountIn, amountOut, swapData);

        // allowFailure = true: the call should not revert, but report failure in the result
        OwnedMulticall.Call3[] memory multicallCalls = new OwnedMulticall.Call3[](1);
        multicallCalls[0] = OwnedMulticall.Call3({
            target: address(_allocator),
            allowFailure: true,
            callData: abi.encodeCall(IAllocator.rebalance, (rebalanceParams))
        });

        vm.prank(everyRoleAccount);
        OwnedMulticall.Result[] memory results = _ownedMulticall.aggregate3(multicallCalls);

        assertEq(results.length, 1);
        assertFalse(results[0].success);
        // returnData should contain the encoded revert reason from the downstream call chain
        assertTrue(results[0].returnData.length > 0);
    }

    function _buildSwapData(
        address assetIn,
        address assetOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint16 slippageToleranceBps
    ) internal view returns (bytes memory) {
        Swapper.SlippageParams memory slippageParams = Swapper.SlippageParams({
            slippageToleranceBps: slippageToleranceBps, slippageCoverageSource: address(_ownedMulticall)
        });
        address[] memory targets = new address[](2);
        targets[0] = assetIn;
        targets[1] = address(_mockDex);
        bytes[] memory callDatas = new bytes[](2);
        callDatas[0] = abi.encodeWithSelector(IERC20.approve.selector, address(_mockDex), amountIn);
        callDatas[1] =
            abi.encodeWithSelector(IMockDex.swapExactInput.selector, assetIn, assetOut, amountIn, minAmountOut);
        return abi.encode(targets, callDatas, slippageParams);
    }

    function _buildEntireFlowRebalanceParams(
        address assetIn,
        address assetOut,
        uint256 amountIn,
        uint256 amountOut,
        bytes memory swapData
    ) internal view returns (IAllocator.RebalanceParams[] memory) {
        IAllocator.DeallocationParams[] memory deallocations = new IAllocator.DeallocationParams[](1);
        deallocations[0] = IAllocator.DeallocationParams({
            asset: assetIn, strategy: _allocator.getDefaultStrategy(assetIn), amount: amountIn
        });

        IAllocator.SwapParams[] memory swaps = new IAllocator.SwapParams[](1);
        swaps[0] = IAllocator.SwapParams({
            assetIn: assetIn, amountIn: amountIn, assetOut: assetOut, swapper: address(_swapper), data: swapData
        });

        IAllocator.AllocationParams[] memory allocations = new IAllocator.AllocationParams[](1);
        allocations[0] = IAllocator.AllocationParams({
            asset: assetOut, strategy: _allocator.getDefaultStrategy(assetOut), amount: amountOut
        });

        IAllocator.RebalanceParams[] memory rebalanceParams = new IAllocator.RebalanceParams[](1);
        rebalanceParams[0] =
            IAllocator.RebalanceParams({deallocations: deallocations, swaps: swaps, allocations: allocations});
        return rebalanceParams;
    }

    function _wrapRebalanceInMulticall(IAllocator.RebalanceParams[] memory rebalanceParams)
        internal
        view
        returns (OwnedMulticall.Call3[] memory)
    {
        OwnedMulticall.Call3[] memory calls = new OwnedMulticall.Call3[](1);
        calls[0] = OwnedMulticall.Call3({
            target: address(_allocator),
            allowFailure: false,
            callData: abi.encodeCall(IAllocator.rebalance, (rebalanceParams))
        });
        return calls;
    }
}

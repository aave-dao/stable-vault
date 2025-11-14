// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Swapper} from "../src/common/Swapper.sol";
import {AssetLib} from "../src/libraries/AssetLib.sol";
import {TestWithHelpers} from "./helpers/TestWithHelpers.sol";
import {IMockDex, MockDex} from "./mocks/MockDex.sol";
import {IMockErc20} from "./mocks/MockErc20.sol";
import {MockNonStandardErc20} from "./mocks/MockNonStandardErc20.sol";

// TODO: remove comments
// execute swap with slippage (need to approve self for DEX to pull funds)
// execute swap without slippage (need to approve self for DEX to pull funds)
// execute 1:1 with funds idle in the swapper
// execute swap where slippage tolerance from input data is breached (expect revert)
// execute swap where pulling from slippage coverage source fails (expect revert)

contract SwapperTest is TestWithHelpers {
    using AssetLib for uint256;
    using SafeERC20 for IERC20;

    MockDex internal _mockDex;
    IMockErc20 internal _mockUsdt;
    IMockErc20 internal _mockGho;

    // Allocator is the owner of the Swapper
    address allocator = makeAddr("ALLOCATOR");
    address slippageCoverageSource = makeAddr("SLIPPAGE_COVERAGE_SOURCE");

    Swapper internal _swapper;

    function setUp() public {
        _mockDex = new MockDex();
        _mockUsdt = IMockErc20(address(new MockNonStandardErc20("Test USDT", "tUSDT", 6)));
        _mockGho = IMockErc20(address(new MockNonStandardErc20("Test GHO", "tGHO", 18)));

        _swapper = new Swapper(allocator);
    }

    function test_executeSwap_6decimalsInput_18decimalsOutput_noSlippage(uint256 amountIn) public {
        amountIn = _boundAssetAmount(address(_mockUsdt), amountIn);
        uint256 minAmountOut = amountIn.convertAssetDecimals(address(_mockUsdt), address(_mockGho));
        vm.assume(minAmountOut > 0);

        _mockTransferIntoSwapper(_mockUsdt, amountIn);
        _seedOutputToken(_mockGho, minAmountOut);
        _setSlippageBps(0);
        _prepareSlippageAndFeeCoverage(_mockGho, 0);

        uint16 slippageToleranceBps = 0;
        bytes memory data = _encodeDexSwapExactInputData(
            address(_mockUsdt), address(_mockGho), amountIn, minAmountOut, slippageToleranceBps
        );
        vm.prank(allocator);
        _swapper.executeSwap(address(_mockUsdt), address(_mockGho), amountIn, data);

        assertEq(IERC20(_mockUsdt).balanceOf(address(_swapper)), 0);
        assertEq(IERC20(_mockGho).balanceOf(address(_swapper)), minAmountOut);

        // Check that the Swapper approved msg.sender to pull the output token
        vm.prank(allocator);
        IERC20(_mockGho).safeTransferFrom(address(_swapper), address(this), minAmountOut);
    }

    function test_executeSwap_18decimalsInput_6decimalsOutput_noSlippage(uint256 amountIn) public {
        amountIn = _boundAssetAmount(address(_mockGho), amountIn);
        uint256 minAmountOut = amountIn.convertAssetDecimals(address(_mockGho), address(_mockUsdt));
        vm.assume(minAmountOut > 0);

        _mockTransferIntoSwapper(_mockGho, amountIn);
        _seedOutputToken(_mockUsdt, minAmountOut);
        _setSlippageBps(0);
        _prepareSlippageAndFeeCoverage(_mockUsdt, 0);

        uint16 slippageToleranceBps = 0;
        bytes memory data = _encodeDexSwapExactInputData(
            address(_mockGho), address(_mockUsdt), amountIn, minAmountOut, slippageToleranceBps
        );
        vm.prank(allocator);
        _swapper.executeSwap(address(_mockGho), address(_mockUsdt), amountIn, data);

        assertEq(IERC20(_mockGho).balanceOf(address(_swapper)), 0);
        assertEq(IERC20(_mockUsdt).balanceOf(address(_swapper)), minAmountOut);

        // Check that the Swapper approved msg.sender to pull the output token
        vm.prank(allocator);
        IERC20(_mockUsdt).safeTransferFrom(address(_swapper), address(this), minAmountOut);
    }

    function test_executeSwap_18decimalsInput_6decimalsOutput_slippage(uint256 amountIn, uint16 slippageToleranceBps)
        public
    {
        vm.assume(slippageToleranceBps <= 10_000);
        amountIn = _boundAssetAmount(address(_mockUsdt), amountIn);
        uint256 amountOutIfNoSlippage = amountIn.convertAssetDecimals(address(_mockUsdt), address(_mockGho));
        uint256 minAmountOut = amountOutIfNoSlippage * (10_000 - slippageToleranceBps) / 10_000;
        vm.assume(minAmountOut > 0);

        uint256 amountNeededFromSlippageCoverageSource = amountOutIfNoSlippage - minAmountOut;
        vm.assume(amountNeededFromSlippageCoverageSource > 0);

        _mockTransferIntoSwapper(_mockUsdt, amountIn);
        _seedOutputToken(_mockGho, minAmountOut);
        _setSlippageBps(slippageToleranceBps);
        _prepareSlippageAndFeeCoverage(_mockGho, amountNeededFromSlippageCoverageSource);

        assertEq(_mockGho.balanceOf(address(slippageCoverageSource)), amountNeededFromSlippageCoverageSource);

        bytes memory data = _encodeDexSwapExactInputData(
            address(_mockUsdt), address(_mockGho), amountIn, minAmountOut, slippageToleranceBps
        );
        vm.prank(allocator);
        _swapper.executeSwap(address(_mockUsdt), address(_mockGho), amountIn, data);

        assertEq(IERC20(_mockUsdt).balanceOf(address(_swapper)), 0);
        assertEq(IERC20(_mockGho).balanceOf(address(_swapper)), amountOutIfNoSlippage);
        assertEq(_mockGho.balanceOf(address(slippageCoverageSource)), 0);

        // Check that the Swapper approved msg.sender to pull the output token
        vm.prank(allocator);
        IERC20(_mockGho).safeTransferFrom(address(_swapper), address(this), amountOutIfNoSlippage);
    }

    function test_executeSwap_6decimalsInput_18decimalsOutput_slippage(uint256 amountIn, uint16 slippageToleranceBps)
        public
    {
        vm.assume(slippageToleranceBps <= 10_000);
        amountIn = _boundAssetAmount(address(_mockGho), amountIn);
        uint256 amountOutIfNoSlippage = amountIn.convertAssetDecimals(address(_mockGho), address(_mockUsdt));
        uint256 minAmountOut = amountOutIfNoSlippage * (10_000 - slippageToleranceBps) / 10_000;
        vm.assume(minAmountOut > 0);

        uint256 amountNeededFromSlippageCoverageSource = amountOutIfNoSlippage - minAmountOut;
        vm.assume(amountNeededFromSlippageCoverageSource > 0);

        _mockTransferIntoSwapper(_mockGho, amountIn);
        _seedOutputToken(_mockUsdt, minAmountOut);
        _setSlippageBps(slippageToleranceBps);
        _prepareSlippageAndFeeCoverage(_mockUsdt, amountNeededFromSlippageCoverageSource);

        assertEq(_mockUsdt.balanceOf(address(slippageCoverageSource)), amountNeededFromSlippageCoverageSource);

        bytes memory data = _encodeDexSwapExactInputData(
            address(_mockGho), address(_mockUsdt), amountIn, minAmountOut, slippageToleranceBps
        );
        vm.prank(allocator);
        _swapper.executeSwap(address(_mockGho), address(_mockUsdt), amountIn, data);

        assertEq(IERC20(_mockGho).balanceOf(address(_swapper)), 0);
        assertEq(IERC20(_mockUsdt).balanceOf(address(_swapper)), amountOutIfNoSlippage);
        assertEq(_mockGho.balanceOf(address(slippageCoverageSource)), 0);

        // Check that the Swapper approved msg.sender to pull the output token
        vm.prank(allocator);
        IERC20(_mockUsdt).safeTransferFrom(address(_swapper), address(this), amountOutIfNoSlippage);
    }

    function test_executeSwap_reverts_ifNotOwner(address caller) public {
        vm.assume(caller != allocator);
        uint256 amountIn = 100;
        bytes memory data = abi.encode(keccak256("test"));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller));
        vm.prank(caller);
        _swapper.executeSwap(address(_mockUsdt), address(_mockGho), amountIn, data);
    }

    /// @dev Allocator transfer input token into the Swapper before invoking the swap
    function _mockTransferIntoSwapper(IMockErc20 token, uint256 amount) internal {
        MockNonStandardErc20(address(token)).mint(address(_swapper), amount);
    }

    function _seedOutputToken(IMockErc20 token, uint256 amount) internal {
        token.mint(address(_mockDex), amount);
    }

    function _setSlippageBps(uint16 slippageBps) internal {
        _mockDex.setSlippageBps(slippageBps);
    }

    function _prepareSlippageAndFeeCoverage(IMockErc20 assetOut, uint256 amount) internal {
        assetOut.mint(slippageCoverageSource, amount);
        vm.prank(slippageCoverageSource);
        MockNonStandardErc20(address(assetOut)).approve(address(_swapper), amount);
    }

    function _encodeDexSwapExactInputData(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint16 slippageToleranceBps
    ) internal view returns (bytes memory) {
        Swapper.SlippageParams memory slippageParams = Swapper.SlippageParams({
            slippageToleranceBps: slippageToleranceBps, slippageCoverageSource: slippageCoverageSource
        });
        bytes memory approveDexData = abi.encodeWithSelector(IERC20.approve.selector, address(_mockDex), amountIn);
        bytes memory dexData =
            abi.encodeWithSelector(IMockDex.swapExactInput.selector, tokenIn, tokenOut, amountIn, minAmountOut);

        address[] memory targets = new address[](2);
        targets[0] = tokenIn;
        targets[1] = address(_mockDex);
        bytes[] memory callDatas = new bytes[](2);
        callDatas[0] = approveDexData;
        callDatas[1] = dexData;
        return abi.encode(targets, callDatas, slippageParams);
    }
}

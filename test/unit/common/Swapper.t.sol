// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {Swapper} from "../../../src/common/Swapper.sol";
import {ISwapper} from "../../../src/interfaces/ISwapper.sol";
import {AssetLib} from "../../../src/libraries/AssetLib.sol";
import {TestWithHelpers} from "../../helpers/TestWithHelpers.sol";
import {IMockDex, MockDex} from "../../mocks/MockDex.sol";
import {IMockErc20} from "../../mocks/MockErc20.sol";
import {MockNonStandardErc20} from "../../mocks/MockNonStandardErc20.sol";

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
        uint256 actualAmountOut = _swapper.executeSwap(address(_mockUsdt), address(_mockGho), amountIn, data);

        assertEq(IERC20(_mockUsdt).balanceOf(address(_swapper)), 0);
        assertEq(IERC20(_mockGho).balanceOf(address(_swapper)), minAmountOut);

        // Check that the Swapper approved msg.sender to pull the output token
        vm.prank(allocator);
        IERC20(_mockGho).safeTransferFrom(address(_swapper), address(this), actualAmountOut);
        assertEq(IERC20(_mockGho).balanceOf(address(_swapper)), 0);
    }

    function test_executeSwap_18decimalsInput_6decimalsOutput_noSlippage(uint256 amountIn) public {
        amountIn = _boundAssetAmount(address(_mockGho), amountIn);
        uint256 divisor = 10 ** (AssetLib.getDecimals(address(_mockGho)) - AssetLib.getDecimals(address(_mockUsdt)));
        amountIn = amountIn / divisor * divisor;
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
        uint256 actualAmountOut = _swapper.executeSwap(address(_mockGho), address(_mockUsdt), amountIn, data);

        assertEq(IERC20(_mockGho).balanceOf(address(_swapper)), 0);
        assertEq(IERC20(_mockUsdt).balanceOf(address(_swapper)), minAmountOut);

        // Check that the Swapper approved msg.sender to pull the output token
        vm.prank(allocator);
        IERC20(_mockUsdt).safeTransferFrom(address(_swapper), address(this), actualAmountOut);
        assertEq(IERC20(_mockUsdt).balanceOf(address(_swapper)), 0);
    }

    function test_executeSwap_6decimalsInput_18decimalsOutput_slippage(uint256 amountIn, uint16 slippageToleranceBps)
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
        uint256 actualAmountOut = _swapper.executeSwap(address(_mockUsdt), address(_mockGho), amountIn, data);

        assertEq(IERC20(_mockUsdt).balanceOf(address(_swapper)), 0);
        assertEq(IERC20(_mockGho).balanceOf(address(_swapper)), amountOutIfNoSlippage);
        assertEq(_mockGho.balanceOf(address(slippageCoverageSource)), 0);

        // Check that the Swapper approved msg.sender to pull the output token
        vm.prank(allocator);
        IERC20(_mockGho).safeTransferFrom(address(_swapper), address(this), actualAmountOut);
        assertEq(IERC20(_mockGho).balanceOf(address(_swapper)), 0);
    }

    function test_executeSwap_18decimalsInput_6decimalsOutput_slippage(uint256 amountIn, uint16 slippageToleranceBps)
        public
    {
        vm.assume(slippageToleranceBps <= 10_000);
        amountIn = _boundAssetAmount(address(_mockGho), amountIn);
        uint256 divisor = 10 ** (AssetLib.getDecimals(address(_mockGho)) - AssetLib.getDecimals(address(_mockUsdt)));
        amountIn = amountIn / divisor * divisor;
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
        uint256 actualAmountOut = _swapper.executeSwap(address(_mockGho), address(_mockUsdt), amountIn, data);

        assertEq(IERC20(_mockGho).balanceOf(address(_swapper)), 0);
        assertEq(IERC20(_mockUsdt).balanceOf(address(_swapper)), amountOutIfNoSlippage);
        assertEq(_mockGho.balanceOf(address(slippageCoverageSource)), 0);

        // Check that the Swapper approved msg.sender to pull the output token
        vm.prank(allocator);
        IERC20(_mockUsdt).safeTransferFrom(address(_swapper), address(this), actualAmountOut);
        assertEq(IERC20(_mockUsdt).balanceOf(address(_swapper)), 0);
    }

    function test_executeSwap_pullFromSlippageCoverageSourceWhenNeeded(uint256 amountIn, uint256 amountOut) public {
        // Assume we allow coverage source to cover entire swap
        uint16 slippageToleranceBps = 10_000;
        amountIn = _boundAssetAmount(address(_mockUsdt), amountIn);
        amountOut = _boundAssetAmountAllowingZero(address(_mockGho), amountOut);

        _mockTransferIntoSwapper(_mockUsdt, amountIn);
        if (amountOut > 0) {
            _seedOutputToken(_mockGho, amountOut);
        }
        _setSlippageBps(slippageToleranceBps);

        uint256 expectedAmountOut = amountIn.convertAssetDecimals(address(_mockUsdt), address(_mockGho));
        uint256 amountNeededFromSlippageCoverageSource;
        if (amountOut < expectedAmountOut) {
            amountNeededFromSlippageCoverageSource = expectedAmountOut - amountOut;
        }
        // We need slippage coverage to cover the difference to get to 1:1.
        // Seed the coverage source with full amount to make sure that the swapper takes only what is needed.
        _prepareSlippageAndFeeCoverage(_mockGho, expectedAmountOut);

        // Check slippage coverage source has the amount needed to cover a potential full slippage.
        assertEq(_mockGho.balanceOf(address(slippageCoverageSource)), expectedAmountOut);

        bytes memory data =
            _encodeDexSwapExactInputData(address(_mockUsdt), address(_mockGho), amountIn, 0, slippageToleranceBps);
        vm.prank(allocator);
        uint256 actualAmountOut = _swapper.executeSwap(address(_mockUsdt), address(_mockGho), amountIn, data);

        // Check that the slippage coverage source has no balance left because it was used to cover slippage.
        assertEq(
            _mockGho.balanceOf(address(slippageCoverageSource)),
            expectedAmountOut - amountNeededFromSlippageCoverageSource
        );

        // Check that the actualAmountOut is the amountOut and can be pulled by the Allocator.
        vm.prank(allocator);
        IERC20(_mockGho).safeTransferFrom(address(_swapper), address(this), actualAmountOut);
        assertEq(IERC20(_mockGho).balanceOf(address(_swapper)), 0);
    }

    function test_executeSwap_moreThanOneToOneOutput(uint256 amountIn, uint16 amountOutExtra) public {
        amountIn = _boundAssetAmount(address(_mockUsdt), amountIn);
        uint256 amountOutIfNoSlippage = amountIn.convertAssetDecimals(address(_mockUsdt), address(_mockGho));
        uint256 actualAmountOut = amountOutIfNoSlippage + uint256(amountOutExtra);

        _mockTransferIntoSwapper(_mockUsdt, amountIn);
        _seedOutputToken(_mockGho, actualAmountOut);
        _setSlippageBps(0);
        _prepareSlippageAndFeeCoverage(_mockGho, 0);

        bytes memory data =
            _encodeDexSwapExactInputData(address(_mockUsdt), address(_mockGho), amountIn, amountOutIfNoSlippage, 0);
        vm.prank(allocator);
        uint256 actualAmountOutFromSwap = _swapper.executeSwap(address(_mockUsdt), address(_mockGho), amountIn, data);

        // Allocator should be able to pull the output token of actualAmountOut
        vm.prank(allocator);
        IERC20(_mockGho).safeTransferFrom(address(_swapper), address(this), actualAmountOutFromSwap);
        assertEq(IERC20(_mockGho).balanceOf(address(_swapper)), 0);
    }

    function test_executeSwap_usesIdleFunds(uint256 amountIn) public {
        amountIn = _boundAssetAmount(address(_mockUsdt), amountIn);
        uint256 amountOutIfNoSlippage = amountIn.convertAssetDecimals(address(_mockUsdt), address(_mockGho));

        // Airdrop the amountOutIfNoSlippage to the Swapper which a manager might do to float liquidity for a swap.
        _mockGho.mint(address(_swapper), amountOutIfNoSlippage);

        _mockTransferIntoSwapper(_mockUsdt, amountIn);
        _seedOutputToken(_mockGho, amountOutIfNoSlippage);
        _setSlippageBps(0);
        _prepareSlippageAndFeeCoverage(_mockGho, 0);

        address[] memory targets = new address[](0);
        bytes[] memory callDatas = new bytes[](0);
        Swapper.SlippageParams memory slippageParams =
            Swapper.SlippageParams({slippageToleranceBps: 0, slippageCoverageSource: slippageCoverageSource});
        bytes memory data = abi.encode(targets, callDatas, slippageParams);

        vm.prank(allocator);
        uint256 actualAmountOut = _swapper.executeSwap(address(_mockUsdt), address(_mockGho), amountIn, data);

        assertEq(IERC20(_mockUsdt).balanceOf(address(_swapper)), amountIn);
        assertEq(IERC20(_mockGho).balanceOf(address(_swapper)), amountOutIfNoSlippage);

        // Check that the Swapper approved msg.sender to pull the output token
        vm.prank(allocator);
        IERC20(_mockGho).safeTransferFrom(address(_swapper), address(this), actualAmountOut);
        assertEq(IERC20(_mockGho).balanceOf(address(_swapper)), 0);
    }

    function test_executeSwap_usesIdleFunds_requireSlippageCoverage(uint256 amountIn, uint16 slippageToleranceBps)
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

        bytes memory data = _encodeDexSwapExactInputData(
            address(_mockUsdt), address(_mockGho), amountIn, minAmountOut, slippageToleranceBps
        );
        vm.prank(allocator);
        uint256 actualAmountOut = _swapper.executeSwap(address(_mockUsdt), address(_mockGho), amountIn, data);

        // Check that the slippage coverage source no longer has the amount needed to cover slippage
        assertEq(_mockGho.balanceOf(address(slippageCoverageSource)), 0);

        // Check that the Allocator was approved to pull the amountOutIfNoSlippage
        vm.prank(allocator);
        IERC20(_mockGho).safeTransferFrom(address(_swapper), address(this), actualAmountOut);
        assertEq(IERC20(_mockGho).balanceOf(address(_swapper)), 0);
    }

    function test_executeSwap_reverts_6decimalsInput_18decimalsOutput_slippage(
        uint256 amountIn,
        uint16 slippageToleranceBps
    ) public {
        vm.assume(slippageToleranceBps < type(uint16).max);
        uint16 actualSlippage = slippageToleranceBps + 1;
        vm.assume(actualSlippage <= 10_000);
        amountIn = _boundAssetAmount(address(_mockUsdt), amountIn);
        uint256 amountOutIfNoSlippage = amountIn.convertAssetDecimals(address(_mockUsdt), address(_mockGho));
        vm.assume(amountOutIfNoSlippage > 0);
        uint256 minAmountOut = amountOutIfNoSlippage * (10_000 - actualSlippage) / 10_000;
        vm.assume(minAmountOut > 0);

        uint256 amountNeededFromSlippageCoverageSource = amountOutIfNoSlippage - minAmountOut;
        vm.assume(amountNeededFromSlippageCoverageSource > 0);

        _mockTransferIntoSwapper(_mockUsdt, amountIn);
        _seedOutputToken(_mockGho, minAmountOut);
        _setSlippageBps(actualSlippage);
        _prepareSlippageAndFeeCoverage(_mockGho, amountNeededFromSlippageCoverageSource);

        assertEq(_mockGho.balanceOf(address(slippageCoverageSource)), amountNeededFromSlippageCoverageSource);

        bytes memory data = _encodeDexSwapExactInputData(
            address(_mockUsdt), address(_mockGho), amountIn, minAmountOut, slippageToleranceBps
        );
        vm.prank(allocator);
        vm.expectRevert(abi.encodeWithSelector(ISwapper.SlippageToleranceExceeded.selector));
        _swapper.executeSwap(address(_mockUsdt), address(_mockGho), amountIn, data);
    }

    function test_executeSwap_reverts_18decimalsInput_6decimalsOutput_slippage(
        uint256 amountIn,
        uint16 slippageToleranceBps
    ) public {
        vm.assume(slippageToleranceBps < type(uint16).max);
        uint16 actualSlippage = slippageToleranceBps + 1;
        vm.assume(actualSlippage <= 10_000);
        amountIn = _boundAssetAmount(address(_mockGho), amountIn);
        uint256 amountOutIfNoSlippage = amountIn.convertAssetDecimals(address(_mockGho), address(_mockUsdt));
        vm.assume(amountOutIfNoSlippage > 0);
        uint256 minAmountOut = amountOutIfNoSlippage * (10_000 - actualSlippage) / 10_000;
        vm.assume(minAmountOut > 0);

        uint256 amountNeededFromSlippageCoverageSource = amountOutIfNoSlippage - minAmountOut;
        vm.assume(amountNeededFromSlippageCoverageSource > 0);

        _mockTransferIntoSwapper(_mockGho, amountIn);
        _seedOutputToken(_mockUsdt, minAmountOut);
        _setSlippageBps(actualSlippage);
        _prepareSlippageAndFeeCoverage(_mockUsdt, 0);

        bytes memory data = _encodeDexSwapExactInputData(
            address(_mockGho), address(_mockUsdt), amountIn, minAmountOut, slippageToleranceBps
        );
        vm.prank(allocator);
        // NOTE: this can either revert if the coverage source does not approve enough to cover slippage or if the min
        // output of tokenOut is less than actual output. It is possible that converting 18dp asset value to 6dp
        // asset value and then calculating the minAmountOut after slippage results in a value that is equal to the
        // actual amount out (the impact of the actual slippage does is not large enough to make amountOut less than
        // what tolerated slippage allows).
        vm.expectRevert();
        _swapper.executeSwap(address(_mockGho), address(_mockUsdt), amountIn, data);
    }

    function test_executeSwap_reverts_ifCallToTargetFailed() public {
        uint256 amountIn = 100;

        vm.mockCallRevert(
            address(_mockDex),
            abi.encodeWithSelector(
                IMockDex.swapExactInput.selector, address(_mockUsdt), address(_mockGho), amountIn, 0
            ),
            abi.encodeWithSelector(IMockDex.InsufficientLiquidity.selector)
        );

        bytes memory data = _encodeDexSwapExactInputData(address(_mockUsdt), address(_mockGho), amountIn, 0, 0);

        vm.expectRevert(abi.encodeWithSelector(ISwapper.CallToTargetFailed.selector));
        vm.prank(allocator);
        _swapper.executeSwap(address(_mockUsdt), address(_mockGho), amountIn, data);
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

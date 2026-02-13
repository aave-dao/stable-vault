// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {EarningChainGateway} from "src/core/earning/EarningChainGateway.sol";
import {EarningChainState} from "src/core/earning/EarningChainState.sol";
import {IEarningChainState} from "src/interfaces/IEarningChainState.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {MathLib} from "src/libraries/MathLib.sol";

import {TestWithHelpers} from "test/helpers/TestWithHelpers.sol";
import {MockAccessManager} from "test/mocks/MockAccessManager.sol";
import {MockAllocator} from "test/mocks/MockAllocator.sol";
import {MockDummyIouTokenManager} from "test/mocks/MockDummyIouTokenManager.sol";
import {IMockErc20} from "test/mocks/MockErc20.sol";
import {MockNonStandardErc20} from "test/mocks/MockNonStandardErc20.sol";
import {MockTransferHelper} from "test/mocks/MockTransferHelper.sol";

contract EarningChainStateTest is TestWithHelpers {
    using MathLib for uint256;
    using AssetLib for uint256;

    uint256 internal ACCOUNTING_CHAIN_ID = 1;

    IMockErc20 internal _mockUsdt;
    IMockErc20 internal _mockGho;
    MockAllocator internal _mockAllocator;
    MockAccessManager internal _mockAccessManager;
    MockTransferHelper internal _mockTransferHelper;
    address internal _priceOracle;

    EarningChainGateway internal _earningChainGateway;
    EarningChainState internal _earningChainState;

    function setUp() public {
        _mockUsdt = IMockErc20(address(new MockNonStandardErc20("Test USDT", "tUSDT", 6)));
        _mockGho = IMockErc20(address(new MockNonStandardErc20("Test GHO", "tGHO", 18)));
        _mockAllocator = new MockAllocator();
        _mockAccessManager = new MockAccessManager(makeAddr("admin"));
        _mockTransferHelper = new MockTransferHelper();

        _priceOracle = address(_deployPriceOracle(address(_mockAccessManager), 9_995e23));
        _mockAssetPrice(_priceOracle, address(_mockUsdt), MathLib.RAY);
        _mockAssetPrice(_priceOracle, address(_mockGho), MathLib.RAY);

        MockDummyIouTokenManager mockIouTokenManager = new MockDummyIouTokenManager();

        address withdrawalPolicy = makeAddr("withdrawalPolicy");

        address earningChainGatewayImpl = address(
            new EarningChainGateway(
                ACCOUNTING_CHAIN_ID,
                address(_mockAllocator),
                _priceOracle,
                address(mockIouTokenManager),
                address(_mockTransferHelper),
                withdrawalPolicy
            )
        );
        _earningChainGateway = EarningChainGateway(
            address(
                new TransparentUpgradeableProxy(
                    earningChainGatewayImpl,
                    address(this),
                    abi.encodeCall(EarningChainGateway.initialize, address(_mockAccessManager))
                )
            )
        );

        address earningChainStateImpl = address(new EarningChainState(address(_earningChainGateway)));
        _earningChainState = EarningChainState(
            address(
                new TransparentUpgradeableProxy(
                    earningChainStateImpl, address(this), ""
                )
            )
        );
    }

    function test_getState_returnsExpectedStateWithMultipleAssets(
        uint256 usdtBalance,
        uint256 ghoBalance,
        uint256 usdtPriceRay,
        uint256 ghoPriceRay,
        uint256 warpTime
    ) public {
        usdtBalance = _boundAssetAmount(address(_mockUsdt), usdtBalance);
        ghoBalance = _boundAssetAmount(address(_mockGho), ghoBalance);
        usdtPriceRay = bound(usdtPriceRay, 1e24, 1e30);
        ghoPriceRay = bound(ghoPriceRay, 1e24, 1e30);
        warpTime = bound(warpTime, 1, 365 days);
        vm.warp(block.timestamp + warpTime);

        _mockAllocator.mockAssetBalance(address(_mockUsdt), usdtBalance);
        _mockAllocator.mockAssetBalance(address(_mockGho), ghoBalance);
        _mockAssetPrice(_priceOracle, address(_mockUsdt), usdtPriceRay);
        _mockAssetPrice(_priceOracle, address(_mockGho), ghoPriceRay);

        uint256 expectedBalanceRay = usdtPriceRay.rayMulDown(usdtBalance.assetDecimalsToRay(address(_mockUsdt)))
            + ghoPriceRay.rayMulDown(ghoBalance.assetDecimalsToRay(address(_mockGho)));

        bytes memory stateData = _earningChainState.getState();

        IEarningChainState.State memory state = abi.decode(stateData, (IEarningChainState.State));
        IEarningChainState.BalanceSnapshot memory snapshot =
            abi.decode(state.data, (IEarningChainState.BalanceSnapshot));

        assertEq(state.version, 1, "Version should be 1");
        assertEq(snapshot.balanceRay, expectedBalanceRay, "Aggregated balance mismatch");
        assertEq(snapshot.timestamp, block.timestamp, "Timestamp should be current block.timestamp");
        assertEq(snapshot.blockNumber, block.number, "Block number should be current block.number");
    }
}

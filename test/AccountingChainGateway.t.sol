// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {AccountingChainGateway} from "../src/accounting/AccountingChainGateway.sol";
import {AssetLib} from "../src/libraries/AssetLib.sol";
import {MathLib} from "../src/libraries/MathLib.sol";
import {TestWithHelpers} from "./helpers/TestWithHelpers.sol";
import {MockAccessManager} from "./mocks/MockAccessManager.sol";
import {MockAssetRegistry} from "./mocks/MockAssetRegistry.sol";
import {MockBridgeAdapter} from "./mocks/MockBridgeAdapter.sol";
import {IMockErc20} from "./mocks/MockErc20.sol";
import {MockFundsHandler} from "./mocks/MockFundsHandler.sol";
import {MockIouTokenManager} from "./mocks/MockIouTokenManager.sol";
import {MockNonStandardErc20} from "./mocks/MockNonStandardErc20.sol";

contract AccountingChainGatewayTest is TestWithHelpers {
    using MathLib for uint256;
    using AssetLib for uint256;
    using SafeERC20 for IERC20;

    uint256 internal ACCOUNTING_CHAIN_ID = 1;
    uint256 internal EARNING_CHAIN_ID = 2;

    address admin = makeAddr("ADMIN");
    address everyRoleAccount = makeAddr("EVERY_ROLE_ACCOUNT");

    MockAccessManager internal _mockAccessManager;
    MockFundsHandler internal _mockFundsHandler;
    IMockErc20 internal _mockUsdt;
    IMockErc20 internal _mockGho;
    IMockErc20 internal _mockUnsupportedAsset;
    MockBridgeAdapter internal _mockBridgeAdapterAssets;
    MockBridgeAdapter internal _mockBridgeAdapterData;
    MockIouTokenManager internal _mockIouTokenManager;
    MockAssetRegistry internal _mockAssetRegistry;

    AccountingChainGateway internal _accountingChainGateway;

    function _deployAccountingChainGateway(
        MockAccessManager mockAccessManager,
        address iouTokenManager,
        address fundsHandler
    ) internal returns (AccountingChainGateway) {
        address accountingChainGatewayImpl = address(new AccountingChainGateway(fundsHandler, iouTokenManager));
        AccountingChainGateway accountingChainGateway = AccountingChainGateway(
            address(
                new TransparentUpgradeableProxy(
                    accountingChainGatewayImpl,
                    address(this),
                    abi.encodeCall(AccountingChainGateway.initialize, (address(mockAccessManager)))
                )
            )
        );

        vm.prank(admin);
        accountingChainGateway.addBridgeAdapter(address(0), EARNING_CHAIN_ID, address(_mockBridgeAdapterData));
        vm.prank(admin);
        accountingChainGateway.setDefaultBridgeAdapter(address(0), EARNING_CHAIN_ID, address(_mockBridgeAdapterData));
        vm.prank(admin);
        accountingChainGateway.addBridgeAdapter(address(_mockUsdt), EARNING_CHAIN_ID, address(_mockBridgeAdapterAssets));
        vm.prank(admin);
        accountingChainGateway.setDefaultBridgeAdapter(
            address(_mockUsdt), EARNING_CHAIN_ID, address(_mockBridgeAdapterAssets)
        );
        vm.prank(admin);
        accountingChainGateway.addBridgeAdapter(address(_mockGho), EARNING_CHAIN_ID, address(_mockBridgeAdapterAssets));
        vm.prank(admin);
        accountingChainGateway.setDefaultBridgeAdapter(
            address(_mockGho), EARNING_CHAIN_ID, address(_mockBridgeAdapterAssets)
        );

        return accountingChainGateway;
    }

    function setUp() public virtual {
        _mockUsdt = IMockErc20(address(new MockNonStandardErc20("Test USDT", "tUSDT", 6)));

        _mockGho = IMockErc20(address(new MockNonStandardErc20("Test GHO", "tGHO", 18)));

        _mockUnsupportedAsset =
            IMockErc20(address(new MockNonStandardErc20("Test Unsupported Asset", "tUNSUPPORTED", 18)));

        _mockIouTokenManager = new MockIouTokenManager();

        _mockAssetRegistry = new MockAssetRegistry();

        _mockFundsHandler = new MockFundsHandler();

        _mockBridgeAdapterAssets = new MockBridgeAdapter();

        _mockBridgeAdapterData = new MockBridgeAdapter();

        _mockAccessManager = new MockAccessManager(admin);

        _accountingChainGateway = _deployAccountingChainGateway(
            _mockAccessManager, address(_mockIouTokenManager), address(_mockFundsHandler)
        );
    }

    function test_getFundsHandler_returnsExpectedFundsHandler() public view {
        assertEq(_accountingChainGateway.getFundsHandler(), address(_mockFundsHandler));
    }
}

// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICrossChainForwarder} from "aave-delivery-infrastructure/contracts/interfaces/ICrossChainForwarder.sol";
import {Vm} from "forge-std/Vm.sol";

import {AdiAdapter} from "src/bridging/adi/AdiAdapter.sol";
import {CcipAdapter} from "src/bridging/ccip/CcipAdapter.sol";
import {Allocator} from "src/core/Allocator.sol";
import {AccountingChainGateway} from "src/core/accounting/AccountingChainGateway.sol";
import {FundsHandler} from "src/core/accounting/FundsHandler.sol";
import {StableVault} from "src/core/accounting/StableVault.sol";
import {EarningChainGateway} from "src/core/earning/EarningChainGateway.sol";
import {IouToken} from "src/core/ious/IouToken.sol";
import {IouTokenManager} from "src/core/ious/IouTokenManager.sol";
import {IAllocator} from "src/interfaces/IAllocator.sol";
import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {IChainBalanceOracle} from "src/interfaces/IChainBalanceOracle.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {IPriceOracle} from "src/interfaces/IPriceOracle.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {AssetRegistry} from "src/periphery/AssetRegistry.sol";
import {PolicyRegistry} from "src/periphery/PolicyRegistry.sol";
import {TransferHelper} from "src/periphery/TransferHelper.sol";
import {WithdrawalExecutionPolicy} from "src/policies/WithdrawalExecutionPolicy.sol";
import {Constants} from "src/types/Constants.sol";

import {AdiHelper} from "pigeon/src/adi/AdiHelper.sol";
import {CcipHelper} from "pigeon/src/ccip/CcipHelper.sol";

import {MockAccessManager} from "test/mocks/MockAccessManager.sol";
import {MockErc20} from "test/mocks/MockErc20.sol";
import {TestErc4626} from "test/mocks/TestErc4626.sol";

import {AdiAdapterPigeonLocalForkBase} from "./AdiAdapterPigeonLocalForkBase.sol";

contract FixedPriceOracle is IPriceOracle {
    function getPrice(address) external pure returns (uint256) {
        return MathLib.RAY;
    }

    function getPrices(address[] calldata assets) external pure returns (uint256[] memory prices) {
        prices = new uint256[](assets.length);
        for (uint256 i = 0; i < assets.length; i++) {
            prices[i] = MathLib.RAY;
        }
    }

    function validatePrice(address) external pure {}
}

contract MutableChainBalanceOracle is IChainBalanceOracle {
    mapping(uint256 chainId => ChainBalance balance) internal _balances;

    function setChainBalance(uint256 chainId, ChainBalance memory balance) external {
        _balances[chainId] = balance;
    }

    function getChainBalance(uint256 chainId) external view returns (ChainBalance memory) {
        return _balances[chainId];
    }
}

/// @notice Real StableVault + IOU gateway flow, bridged as a.DI data-only messages over local forks.
contract AdiAdapterPigeonIouWithdrawal is AdiAdapterPigeonLocalForkBase {
    using AssetLib for uint256;

    struct AccountingStack {
        MockAccessManager accessManager;
        TransferHelper transferHelper;
        FixedPriceOracle priceOracle;
        MutableChainBalanceOracle chainBalanceOracle;
        MockErc20 asset;
        AssetRegistry assetRegistry;
        WithdrawalExecutionPolicy withdrawalExecutionPolicy;
        PolicyRegistry policyRegistry;
        IouToken iouToken;
        IouTokenManager iouTokenManager;
        StableVault vault;
        Allocator allocator;
        FundsHandler fundsHandler;
        AccountingChainGateway gateway;
        AdiAdapter adiAdapter;
        TestErc4626 strategy;
    }

    struct EarningStack {
        MockAccessManager accessManager;
        TransferHelper transferHelper;
        FixedPriceOracle priceOracle;
        MockErc20 asset;
        AssetRegistry assetRegistry;
        WithdrawalExecutionPolicy withdrawalExecutionPolicy;
        PolicyRegistry policyRegistry;
        IouToken iouToken;
        IouTokenManager iouTokenManager;
        Allocator allocator;
        EarningChainGateway gateway;
        AdiAdapter adiAdapter;
        TestErc4626 strategy;
    }

    struct CcipDataOnlyAdapters {
        CcipAdapter accounting;
        CcipAdapter earning;
    }

    struct DataOnlyBridgeRemovalIds {
        bytes32 accounting;
        bytes32 earning;
    }

    uint256 internal constant DEFAULT_MAX_PER_SECOND_RATE = 1000000005781378656804591713; // ~20% APY
    uint256 internal constant BURN_IOU_TOKEN_GAS_LIMIT = 120_000;
    uint256 internal constant CCIP_NATIVE_FEE_PAYMENT = 1 ether;
    uint256 internal constant MAX_ACTIVE_SUB_VAULTS = 201;
    uint8 internal constant MAX_STRATEGIES_PER_ASSET = 15;
    uint128 internal constant TEST_MIN_REDEMPTION_CAPACITY = 1e30;
    uint128 internal constant TEST_MIN_REDEMPTION_REFILL_RATE = 1e25;
    uint128 internal constant TEST_REDEMPTION_CAPACITY = type(uint128).max - 1;
    uint128 internal constant TEST_REDEMPTION_REFILL_RATE = 1e30;

    address internal _proxyAdmin = makeAddr("PROXY_ADMIN");
    address internal _admin = makeAddr("ADI_IOU_ADMIN");
    address internal _treasury = makeAddr("ADI_IOU_TREASURY");
    address internal _user = makeAddr("ADI_IOU_USER");

    AccountingStack internal _accounting;
    EarningStack internal _earning;

    function setUp() public override {
        super.setUp();
        if (!vm.envOr("FORK_TEST", false)) {
            return;
        }

        vm.selectFork(_ethFork);
        _accounting = _deployAccountingStack();

        vm.selectFork(_arbFork);
        _earning = _deployEarningStack();

        _wireStacks();
    }

    function test_iouWithdrawalOverAdi_bridgeMintAndBurnLockedAccountingIous() public onlyForkTest {
        uint256 depositAmount = 500e6;
        vm.selectFork(_ethFork);
        uint256 iouAmountRay = depositAmount.assetDecimalsToRay(address(_accounting.asset));

        _depositIntoStableVault(depositAmount);
        _airdropEarningLiquidity(depositAmount);

        vm.selectFork(_ethFork);
        vm.prank(_user);
        uint256 mintedIous = _accounting.vault.requestWithdrawal(_user, iouAmountRay, "");
        assertEq(mintedIous, iouAmountRay, "unexpected requested IOU amount");
        assertEq(_accounting.iouToken.balanceOf(_user), iouAmountRay, "accounting IOUs not minted");

        Vm.Log[] memory bridgeLogs = _bridgeAccountingIousToEarning(iouAmountRay);

        vm.selectFork(_arbFork);
        assertEq(_earning.iouToken.balanceOf(_user), 0, "earning IOUs should not mint before relay");
        assertEq(_earning.iouToken.totalSupply(), 0, "earning IOU supply should be zero before relay");

        _adiHelper.helpEthToArb(
            AdiHelper.EthToArbArgs({
                l2ForkId: _arbFork, l1Inbox: ARB_INBOX, l1Bridge: ARB_BRIDGE, expectedL1CCC: _ethCcc, logs: bridgeLogs
            })
        );

        vm.selectFork(_ethFork);
        assertEq(_accounting.iouToken.balanceOf(_user), 0, "accounting user IOUs should be locked");
        assertEq(_accounting.iouToken.balanceOf(address(_accounting.iouTokenManager)), iouAmountRay, "IOUs not locked");
        assertEq(_accounting.iouTokenManager.getLockedBalance(), iouAmountRay, "unexpected locked IOU balance");

        vm.selectFork(_arbFork);
        assertEq(_earning.iouToken.balanceOf(_user), iouAmountRay, "earning IOUs not minted");
        assertEq(_earning.iouToken.totalSupply(), iouAmountRay, "earning IOU supply not minted");
        uint256 userAssetBefore = _earning.asset.balanceOf(_user);
        uint256 burnSourceBlock = block.number;

        Vm.Log[] memory burnLogs = _exchangeEarningIousForAssets(iouAmountRay);

        assertEq(_earning.iouToken.balanceOf(_user), 0, "earning IOUs not burned");
        assertEq(_earning.iouToken.totalSupply(), 0, "earning IOU supply not burned");
        assertGt(_earning.asset.balanceOf(_user), userAssetBefore, "user did not receive earning-chain assets");

        vm.selectFork(_ethFork);
        assertEq(_accounting.iouTokenManager.getLockedBalance(), iouAmountRay, "locked IOUs burned before relay");
        assertEq(
            _accounting.iouToken.balanceOf(address(_accounting.iouTokenManager)),
            iouAmountRay,
            "manager IOUs burned before relay"
        );
        _accounting.chainBalanceOracle
            .setChainBalance(
                ARB_CHAIN_ID,
                IChainBalanceOracle.ChainBalance({
                    balanceRay: 0,
                    lastUpdateTimestamp: block.timestamp,
                    sourceChainTimestamp: block.timestamp,
                    sourceChainBlockNumber: burnSourceBlock,
                    isStale: false
                })
            );

        _adiHelper.helpMultiBridge(
            AdiHelper.MultiBridgeArgs({
                dstForkId: _ethFork,
                dstCcipRouter: ETH_CCIP_ROUTER,
                dstCcipChainSelector: ETH_CCIP_CHAIN_SELECTOR,
                srcCcipOnRamp: address(0),
                dstLzEndpoint: LZ_ENDPOINT_V2,
                srcHlMailbox: ARB_HL_MAILBOX,
                dstHlMailbox: ETH_HL_MAILBOX,
                logs: burnLogs
            })
        );

        assertEq(_accounting.iouTokenManager.getLockedBalance(), 0, "locked IOUs not burned");
        assertEq(_accounting.iouToken.balanceOf(address(_accounting.iouTokenManager)), 0, "manager still holds IOUs");
        assertEq(_accounting.iouToken.totalSupply(), 0, "accounting IOU supply not burned");
    }

    function test_iouBurnRetryOverAdi_burnsLockedAccountingIous() public onlyForkTest {
        uint256 depositAmount = 500e6;
        vm.selectFork(_ethFork);
        uint256 iouAmountRay = depositAmount.assetDecimalsToRay(address(_accounting.asset));

        _depositIntoStableVault(depositAmount);
        _airdropEarningLiquidity(depositAmount);

        vm.selectFork(_ethFork);
        vm.prank(_user);
        _accounting.vault.requestWithdrawal(_user, iouAmountRay, "");

        Vm.Log[] memory bridgeLogs = _bridgeAccountingIousToEarning(iouAmountRay);
        _adiHelper.helpEthToArb(
            AdiHelper.EthToArbArgs({
                l2ForkId: _arbFork, l1Inbox: ARB_INBOX, l1Bridge: ARB_BRIDGE, expectedL1CCC: _ethCcc, logs: bridgeLogs
            })
        );

        vm.selectFork(_arbFork);
        assertEq(_earning.iouToken.balanceOf(_user), iouAmountRay, "earning IOUs not minted before burn retry");
        uint256 userAssetBefore = _earning.asset.balanceOf(_user);
        uint256 burnSourceBlock = block.number;
        Vm.Log[] memory burnLogs = _exchangeEarningIousForAssets(iouAmountRay);
        bytes memory encodedBurnTransaction = _firstSuccessfulEncodedTransaction(burnLogs);

        assertEq(_earning.iouToken.balanceOf(_user), 0, "earning IOUs not burned before retry");
        assertGt(_earning.asset.balanceOf(_user), userAssetBefore, "user did not receive earning-chain assets");

        vm.selectFork(_ethFork);
        assertEq(_accounting.iouTokenManager.getLockedBalance(), iouAmountRay, "locked IOUs burned before retry");
        _accounting.chainBalanceOracle
            .setChainBalance(
                ARB_CHAIN_ID,
                IChainBalanceOracle.ChainBalance({
                    balanceRay: 0,
                    lastUpdateTimestamp: block.timestamp,
                    sourceChainTimestamp: block.timestamp,
                    sourceChainBlockNumber: burnSourceBlock,
                    isStale: false
                })
            );

        vm.selectFork(_arbFork);
        address[] memory bridgeAdaptersToRetry = _configuredArbToEthRetryAdapters();
        uint256 retryNativeFee = _prepareRetryFees(_earning.adiAdapter, encodedBurnTransaction, bridgeAdaptersToRetry);

        vm.recordLogs();
        _earning.adiAdapter.retryTransaction{value: retryNativeFee}(
            encodedBurnTransaction, DEFAULT_GAS_LIMIT, bridgeAdaptersToRetry
        );
        Vm.Log[] memory retryLogs = vm.getRecordedLogs();
        assertGe(_adiHelper.countSuccessfulForwards(retryLogs), 2, "BURN retry should meet forwarding threshold");

        _adiHelper.helpMultiBridge(
            AdiHelper.MultiBridgeArgs({
                dstForkId: _ethFork,
                dstCcipRouter: ETH_CCIP_ROUTER,
                dstCcipChainSelector: ETH_CCIP_CHAIN_SELECTOR,
                srcCcipOnRamp: address(0),
                dstLzEndpoint: LZ_ENDPOINT_V2,
                srcHlMailbox: ARB_HL_MAILBOX,
                dstHlMailbox: ETH_HL_MAILBOX,
                logs: retryLogs
            })
        );

        vm.selectFork(_ethFork);
        assertEq(_accounting.iouTokenManager.getLockedBalance(), 0, "locked IOUs not burned by retry");
        assertEq(_accounting.iouToken.balanceOf(address(_accounting.iouTokenManager)), 0, "manager still holds IOUs");
        assertEq(_accounting.iouToken.totalSupply(), 0, "accounting IOU supply not burned by retry");
    }

    function test_iouBurnOverAdi_quorumThenNoDuplicateBurn() public onlyForkTest {
        uint256 depositAmount = 500e6;
        vm.selectFork(_ethFork);
        uint256 iouAmountRay = depositAmount.assetDecimalsToRay(address(_accounting.asset));

        _depositIntoStableVault(depositAmount);
        _airdropEarningLiquidity(depositAmount);

        vm.selectFork(_ethFork);
        vm.prank(_user);
        _accounting.vault.requestWithdrawal(_user, iouAmountRay, "");

        Vm.Log[] memory bridgeLogs = _bridgeAccountingIousToEarning(iouAmountRay);
        _adiHelper.helpEthToArb(
            AdiHelper.EthToArbArgs({
                l2ForkId: _arbFork, l1Inbox: ARB_INBOX, l1Bridge: ARB_BRIDGE, expectedL1CCC: _ethCcc, logs: bridgeLogs
            })
        );

        vm.selectFork(_arbFork);
        assertEq(_earning.iouToken.balanceOf(_user), iouAmountRay, "earning IOUs not minted before quorum test");
        uint256 burnSourceBlock = block.number;
        Vm.Log[] memory burnLogs = _exchangeEarningIousForAssets(iouAmountRay);

        vm.selectFork(_ethFork);
        assertEq(_accounting.iouTokenManager.getLockedBalance(), iouAmountRay, "locked IOUs burned before relay");
        _accounting.chainBalanceOracle
            .setChainBalance(
                ARB_CHAIN_ID,
                IChainBalanceOracle.ChainBalance({
                    balanceRay: 0,
                    lastUpdateTimestamp: block.timestamp,
                    sourceChainTimestamp: block.timestamp,
                    sourceChainBlockNumber: burnSourceBlock,
                    isStale: false
                })
            );

        _adiHelper.helpMultiBridge(
            AdiHelper.MultiBridgeArgs({
                dstForkId: _ethFork,
                dstCcipRouter: ETH_CCIP_ROUTER,
                dstCcipChainSelector: ETH_CCIP_CHAIN_SELECTOR,
                srcCcipOnRamp: address(0),
                dstLzEndpoint: address(0),
                srcHlMailbox: address(0),
                dstHlMailbox: address(0),
                logs: burnLogs
            })
        );
        vm.selectFork(_ethFork);
        assertEq(_accounting.iouTokenManager.getLockedBalance(), iouAmountRay, "single relay should not burn IOUs");
        assertEq(
            _accounting.iouToken.balanceOf(address(_accounting.iouTokenManager)),
            iouAmountRay,
            "single relay changed locked IOU balance"
        );

        _adiHelper.helpMultiBridge(
            AdiHelper.MultiBridgeArgs({
                dstForkId: _ethFork,
                dstCcipRouter: address(0),
                dstCcipChainSelector: 0,
                srcCcipOnRamp: address(0),
                dstLzEndpoint: LZ_ENDPOINT_V2,
                srcHlMailbox: address(0),
                dstHlMailbox: address(0),
                logs: burnLogs
            })
        );
        vm.selectFork(_ethFork);
        assertEq(_accounting.iouTokenManager.getLockedBalance(), 0, "second relay should burn locked IOUs");
        assertEq(_accounting.iouToken.balanceOf(address(_accounting.iouTokenManager)), 0, "manager still holds IOUs");
        assertEq(_accounting.iouToken.totalSupply(), 0, "accounting IOU supply not burned");

        _adiHelper.helpMultiBridge(
            AdiHelper.MultiBridgeArgs({
                dstForkId: _ethFork,
                dstCcipRouter: address(0),
                dstCcipChainSelector: 0,
                srcCcipOnRamp: address(0),
                dstLzEndpoint: address(0),
                srcHlMailbox: ARB_HL_MAILBOX,
                dstHlMailbox: ETH_HL_MAILBOX,
                logs: burnLogs
            })
        );
        vm.selectFork(_ethFork);
        assertEq(_accounting.iouTokenManager.getLockedBalance(), 0, "extra relay should not relock or reburn IOUs");
        assertEq(
            _accounting.iouToken.balanceOf(address(_accounting.iouTokenManager)),
            0,
            "extra relay changed manager IOU balance"
        );
        assertEq(_accounting.iouToken.totalSupply(), 0, "extra relay changed accounting IOU supply");
    }

    function test_iouBridge_replacesCcipDataOnlyBridgeWithAdi() public onlyForkTest {
        uint256 depositAmount = 500e6;
        vm.selectFork(_ethFork);
        uint256 iouAmountRay = depositAmount.assetDecimalsToRay(address(_accounting.asset));
        CcipDataOnlyAdapters memory ccip = _deployCcipDataOnlyAdapters();

        _replaceAdiWithCcip(ccip);

        _depositIntoStableVault(depositAmount);
        _requestAccountingWithdrawal(iouAmountRay);
        Vm.Log[] memory ccipLogs = _bridgeAccountingIousToEarningViaCcip(iouAmountRay, ccip.accounting);

        vm.selectFork(_arbFork);
        assertEq(_earning.iouToken.balanceOf(_user), 0, "CCIP IOUs should be in flight");

        DataOnlyBridgeRemovalIds memory ccipRemovalIds = _migrateCcipToAdi(ccip);

        _depositIntoStableVault(depositAmount);
        _requestAccountingWithdrawal(iouAmountRay);
        Vm.Log[] memory adiLogs = _bridgeAccountingIousToEarning(iouAmountRay);
        _relayAccountingToEarningViaAdi(adiLogs);

        vm.selectFork(_arbFork);
        assertEq(_earning.iouToken.balanceOf(_user), iouAmountRay, "aDI IOUs not minted during migration");

        _relayAccountingToEarningViaCcip(ccipLogs);

        vm.selectFork(_arbFork);
        assertEq(_earning.iouToken.balanceOf(_user), iouAmountRay * 2, "CCIP in-flight IOUs not minted");

        _removeCcipDataOnlyAdapters(ccip, ccipRemovalIds);

        _depositIntoStableVault(depositAmount);
        _requestAccountingWithdrawal(iouAmountRay);
        Vm.Log[] memory postRemovalAdiLogs = _bridgeAccountingIousToEarning(iouAmountRay);
        _relayAccountingToEarningViaAdi(postRemovalAdiLogs);

        vm.selectFork(_arbFork);
        assertEq(_earning.iouToken.balanceOf(_user), iouAmountRay * 3, "post-removal aDI IOUs not minted");

        vm.selectFork(_ethFork);
        vm.expectRevert(IChainGateway.AdapterNotFound.selector);
        vm.prank(address(_accounting.iouTokenManager));
        _accounting.gateway
            .sendBridgeIouTokenMessageWithFeePayer(
                ARB_CHAIN_ID,
                _user,
                iouAmountRay,
                address(ccip.accounting),
                _user,
                DEFAULT_GAS_LIMIT,
                _ccipNativeFeeData()
            );
    }

    function _deployAccountingStack() internal returns (AccountingStack memory stack) {
        stack.accessManager = new MockAccessManager(_admin);
        stack.transferHelper = new TransferHelper();
        stack.priceOracle = new FixedPriceOracle();
        stack.chainBalanceOracle = new MutableChainBalanceOracle();
        stack.asset = new MockErc20("Fork ETH USDC", "fETHUSDC", 6);

        uint256 nonce = vm.getNonce(address(this));
        address assetRegistryAddress = vm.computeCreateAddress(address(this), nonce + 1);
        address withdrawalExecutionPolicyAddress = vm.computeCreateAddress(address(this), nonce + 3);
        address iouTokenAddress = vm.computeCreateAddress(address(this), nonce + 4);
        address iouTokenManagerAddress = vm.computeCreateAddress(address(this), nonce + 6);
        address vaultAddress = vm.computeCreateAddress(address(this), nonce + 8);
        address allocatorAddress = vm.computeCreateAddress(address(this), nonce + 10);
        address fundsHandlerAddress = vm.computeCreateAddress(address(this), nonce + 12);
        address gatewayAddress = vm.computeCreateAddress(address(this), nonce + 14);
        address policyRegistryAddress = vm.computeCreateAddress(address(this), nonce + 15);

        stack.assetRegistry = AssetRegistry(
            address(
                new TransparentUpgradeableProxy(
                    address(new AssetRegistry()),
                    _proxyAdmin,
                    abi.encodeCall(AssetRegistry.initialize, (address(stack.accessManager)))
                )
            )
        );
        require(address(stack.assetRegistry) == assetRegistryAddress, "asset registry address mismatch");

        stack.withdrawalExecutionPolicy = WithdrawalExecutionPolicy(
            address(
                new TransparentUpgradeableProxy(
                    address(
                        new WithdrawalExecutionPolicy(
                            vaultAddress, TEST_MIN_REDEMPTION_CAPACITY, TEST_MIN_REDEMPTION_REFILL_RATE
                        )
                    ),
                    _proxyAdmin,
                    abi.encodeCall(WithdrawalExecutionPolicy.initialize, (address(stack.accessManager), 0))
                )
            )
        );
        require(
            address(stack.withdrawalExecutionPolicy) == withdrawalExecutionPolicyAddress,
            "withdrawal execution policy address mismatch"
        );
        _seedWithdrawalExecutionPolicy(stack.withdrawalExecutionPolicy);

        stack.iouToken = new IouToken(iouTokenManagerAddress, "IOU: Fork Stable Vault", "IOU-FORK");
        require(address(stack.iouToken) == iouTokenAddress, "accounting IOU token address mismatch");

        stack.iouTokenManager = IouTokenManager(
            address(
                new TransparentUpgradeableProxy(
                    address(
                        new IouTokenManager(
                            iouTokenAddress, gatewayAddress, vaultAddress, address(stack.transferHelper), true
                        )
                    ),
                    _proxyAdmin,
                    ""
                )
            )
        );
        require(address(stack.iouTokenManager) == iouTokenManagerAddress, "accounting IOU manager address mismatch");

        stack.vault = StableVault(
            address(
                new TransparentUpgradeableProxy(
                    address(
                        new StableVault(
                            DEFAULT_MAX_PER_SECOND_RATE,
                            assetRegistryAddress,
                            iouTokenManagerAddress,
                            fundsHandlerAddress,
                            address(stack.transferHelper),
                            address(stack.priceOracle),
                            MAX_ACTIVE_SUB_VAULTS,
                            policyRegistryAddress
                        )
                    ),
                    _proxyAdmin,
                    abi.encodeCall(
                        StableVault.initialize,
                        (address(stack.accessManager), _treasury, MathLib.RAY, "Fork Stable Vault", "FSV")
                    )
                )
            )
        );
        require(address(stack.vault) == vaultAddress, "stable vault address mismatch");

        stack.allocator = Allocator(
            address(
                new TransparentUpgradeableProxy(
                    address(
                        new Allocator(
                            assetRegistryAddress,
                            fundsHandlerAddress,
                            fundsHandlerAddress,
                            address(stack.priceOracle),
                            address(stack.transferHelper),
                            MAX_STRATEGIES_PER_ASSET,
                            policyRegistryAddress
                        )
                    ),
                    _proxyAdmin,
                    abi.encodeCall(Allocator.initialize, (address(stack.accessManager)))
                )
            )
        );
        require(address(stack.allocator) == allocatorAddress, "accounting allocator address mismatch");

        stack.fundsHandler = FundsHandler(
            address(
                new TransparentUpgradeableProxy(
                    address(
                        new FundsHandler(
                            vaultAddress,
                            gatewayAddress,
                            allocatorAddress,
                            address(stack.priceOracle),
                            address(stack.transferHelper),
                            address(stack.chainBalanceOracle),
                            policyRegistryAddress
                        )
                    ),
                    _proxyAdmin,
                    abi.encodeCall(FundsHandler.initialize, (address(stack.accessManager)))
                )
            )
        );
        require(address(stack.fundsHandler) == fundsHandlerAddress, "funds handler address mismatch");

        stack.gateway = AccountingChainGateway(
            address(
                new TransparentUpgradeableProxy(
                    address(
                        new AccountingChainGateway(
                            fundsHandlerAddress, iouTokenManagerAddress, address(stack.chainBalanceOracle)
                        )
                    ),
                    _proxyAdmin,
                    abi.encodeCall(AccountingChainGateway.initialize, (address(stack.accessManager)))
                )
            )
        );
        require(address(stack.gateway) == gatewayAddress, "accounting gateway address mismatch");

        stack.policyRegistry = new PolicyRegistry(address(stack.accessManager));
        require(address(stack.policyRegistry) == policyRegistryAddress, "accounting policy registry address mismatch");
        vm.prank(_admin);
        stack.policyRegistry
            .setPolicy(
                keccak256(bytes("aave.stable-vault.StableVault.policy.withdrawal-execution")),
                address(stack.withdrawalExecutionPolicy)
            );

        stack.adiAdapter =
            new AdiAdapter(address(stack.accessManager), gatewayAddress, _ethCcc, address(stack.transferHelper));
        stack.strategy = new TestErc4626(IERC20(address(stack.asset)));

        _configureAccountingStack(stack);
    }

    function _deployEarningStack() internal returns (EarningStack memory stack) {
        stack.accessManager = new MockAccessManager(_admin);
        stack.transferHelper = new TransferHelper();
        stack.priceOracle = new FixedPriceOracle();
        stack.asset = new MockErc20("Fork ARB USDC", "fARBUSDC", 6);

        uint256 nonce = vm.getNonce(address(this));
        address assetRegistryAddress = vm.computeCreateAddress(address(this), nonce + 1);
        address gatewayAddress = vm.computeCreateAddress(address(this), nonce + 10);
        address withdrawalExecutionPolicyAddress = vm.computeCreateAddress(address(this), nonce + 3);
        address iouTokenAddress = vm.computeCreateAddress(address(this), nonce + 4);
        address iouTokenManagerAddress = vm.computeCreateAddress(address(this), nonce + 6);
        address allocatorAddress = vm.computeCreateAddress(address(this), nonce + 8);
        address policyRegistryAddress = vm.computeCreateAddress(address(this), nonce + 11);

        stack.assetRegistry = AssetRegistry(
            address(
                new TransparentUpgradeableProxy(
                    address(new AssetRegistry()),
                    _proxyAdmin,
                    abi.encodeCall(AssetRegistry.initialize, (address(stack.accessManager)))
                )
            )
        );
        require(address(stack.assetRegistry) == assetRegistryAddress, "earning asset registry address mismatch");

        stack.withdrawalExecutionPolicy = WithdrawalExecutionPolicy(
            address(
                new TransparentUpgradeableProxy(
                    address(
                        new WithdrawalExecutionPolicy(
                            gatewayAddress, TEST_MIN_REDEMPTION_CAPACITY, TEST_MIN_REDEMPTION_REFILL_RATE
                        )
                    ),
                    _proxyAdmin,
                    abi.encodeCall(WithdrawalExecutionPolicy.initialize, (address(stack.accessManager), 0))
                )
            )
        );
        require(
            address(stack.withdrawalExecutionPolicy) == withdrawalExecutionPolicyAddress,
            "earning withdrawal execution policy address mismatch"
        );
        _seedWithdrawalExecutionPolicy(stack.withdrawalExecutionPolicy);

        stack.iouToken = new IouToken(iouTokenManagerAddress, "IOU: Fork Stable Vault", "IOU-FORK");
        require(address(stack.iouToken) == iouTokenAddress, "earning IOU token address mismatch");

        stack.iouTokenManager = IouTokenManager(
            address(
                new TransparentUpgradeableProxy(
                    address(
                        new IouTokenManager(
                            iouTokenAddress, gatewayAddress, address(0), address(stack.transferHelper), false
                        )
                    ),
                    _proxyAdmin,
                    ""
                )
            )
        );
        require(address(stack.iouTokenManager) == iouTokenManagerAddress, "earning IOU manager address mismatch");

        stack.allocator = Allocator(
            address(
                new TransparentUpgradeableProxy(
                    address(
                        new Allocator(
                            assetRegistryAddress,
                            gatewayAddress,
                            gatewayAddress,
                            address(stack.priceOracle),
                            address(stack.transferHelper),
                            MAX_STRATEGIES_PER_ASSET,
                            policyRegistryAddress
                        )
                    ),
                    _proxyAdmin,
                    abi.encodeCall(Allocator.initialize, (address(stack.accessManager)))
                )
            )
        );
        require(address(stack.allocator) == allocatorAddress, "earning allocator address mismatch");

        stack.gateway = EarningChainGateway(
            address(
                new TransparentUpgradeableProxy(
                    address(
                        new EarningChainGateway(
                            ETH_CHAIN_ID,
                            allocatorAddress,
                            address(stack.priceOracle),
                            iouTokenManagerAddress,
                            address(stack.transferHelper),
                            policyRegistryAddress,
                            BURN_IOU_TOKEN_GAS_LIMIT
                        )
                    ),
                    _proxyAdmin,
                    abi.encodeCall(EarningChainGateway.initialize, (address(stack.accessManager)))
                )
            )
        );
        require(address(stack.gateway) == gatewayAddress, "earning gateway address mismatch");

        stack.policyRegistry = new PolicyRegistry(address(stack.accessManager));
        require(address(stack.policyRegistry) == policyRegistryAddress, "earning policy registry address mismatch");
        vm.prank(_admin);
        stack.policyRegistry
            .setPolicy(
                keccak256(bytes("aave.stable-vault.EarningChainGateway.policy.withdrawal-execution")),
                address(stack.withdrawalExecutionPolicy)
            );

        stack.adiAdapter =
            new AdiAdapter(address(stack.accessManager), gatewayAddress, _arbCcc, address(stack.transferHelper));
        stack.strategy = new TestErc4626(IERC20(address(stack.asset)));

        _configureEarningStack(stack);
    }

    function _configureAccountingStack(AccountingStack memory stack) internal {
        IAssetRegistry.AssetConfig memory assetConfig = IAssetRegistry.AssetConfig({
            depositFromUserAllowed: true,
            depositIntoAllocatorAllowed: true,
            swapInputTokenAllowed: true,
            swapOutputTokenAllowed: true
        });
        stack.assetRegistry.setAssetConfig(address(stack.asset), assetConfig);
        stack.allocator.addStrategy(address(stack.asset), address(stack.strategy));
        stack.fundsHandler.addEarningChain(ARB_CHAIN_ID);
        stack.gateway.addDataOnlyBridgeAdapter(ARB_CHAIN_ID, address(stack.adiAdapter));
    }

    function _configureEarningStack(EarningStack memory stack) internal {
        IAssetRegistry.AssetConfig memory assetConfig = IAssetRegistry.AssetConfig({
            depositFromUserAllowed: true,
            depositIntoAllocatorAllowed: true,
            swapInputTokenAllowed: true,
            swapOutputTokenAllowed: true
        });
        stack.assetRegistry.setAssetConfig(address(stack.asset), assetConfig);
        stack.allocator.addStrategy(address(stack.asset), address(stack.strategy));
        stack.gateway.addDataOnlyBridgeAdapter(ETH_CHAIN_ID, address(stack.adiAdapter));
    }

    function _seedWithdrawalExecutionPolicy(WithdrawalExecutionPolicy withdrawalExecutionPolicy) internal {
        withdrawalExecutionPolicy.raiseRedemptionCapacity(TEST_REDEMPTION_CAPACITY);
        withdrawalExecutionPolicy.raiseRedemptionRefillRate(TEST_REDEMPTION_REFILL_RATE);
    }

    function _wireStacks() internal {
        vm.selectFork(_ethFork);
        _accounting.adiAdapter.setDestinationChainAdapter(ARB_CHAIN_ID, address(_earning.adiAdapter));
        _approveAdiAdapter(_ethCcc, address(_accounting.adiAdapter));

        vm.selectFork(_arbFork);
        _earning.adiAdapter.setDestinationChainAdapter(ETH_CHAIN_ID, address(_accounting.adiAdapter));
        _approveAdiAdapter(_arbCcc, address(_earning.adiAdapter));
    }

    function _deployCcipDataOnlyAdapters() internal returns (CcipDataOnlyAdapters memory adapters) {
        vm.selectFork(_ethFork);
        adapters.accounting = new CcipAdapter(
            address(_accounting.accessManager),
            address(_accounting.gateway),
            ETH_CCIP_ROUTER,
            address(_accounting.transferHelper),
            address(_accounting.assetRegistry)
        );

        vm.selectFork(_arbFork);
        adapters.earning = new CcipAdapter(
            address(_earning.accessManager),
            address(_earning.gateway),
            ARB_CCIP_ROUTER,
            address(_earning.transferHelper),
            address(_earning.assetRegistry)
        );

        vm.selectFork(_ethFork);
        adapters.accounting.setChainSelector(ARB_CHAIN_ID, ARB_CCIP_CHAIN_SELECTOR);
        adapters.accounting.setDestinationChainAdapter(ARB_CHAIN_ID, address(adapters.earning));

        vm.selectFork(_arbFork);
        adapters.earning.setChainSelector(ETH_CHAIN_ID, ETH_CCIP_CHAIN_SELECTOR);
        adapters.earning.setDestinationChainAdapter(ETH_CHAIN_ID, address(adapters.accounting));
    }

    function _replaceAdiWithCcip(CcipDataOnlyAdapters memory ccip) internal {
        vm.selectFork(_ethFork);
        _accounting.gateway.addDataOnlyBridgeAdapter(ARB_CHAIN_ID, address(ccip.accounting));
        bytes32 accountingAdiRemovalId =
            _accounting.gateway.initiateDataOnlyBridgeAdapterRemoval(ARB_CHAIN_ID, address(_accounting.adiAdapter));
        _accounting.gateway
            .finalizeDataOnlyBridgeAdapterRemoval(ARB_CHAIN_ID, address(_accounting.adiAdapter), accountingAdiRemovalId);
        assertEq(
            uint8(_accounting.gateway.getDataOnlyBridgeAdapterMode(ARB_CHAIN_ID, address(ccip.accounting))),
            uint8(IChainGateway.DataOnlyBridgeAdapterMode.SEND_AND_RECEIVE),
            "accounting CCIP not enabled"
        );
        assertEq(
            uint8(_accounting.gateway.getDataOnlyBridgeAdapterMode(ARB_CHAIN_ID, address(_accounting.adiAdapter))),
            uint8(IChainGateway.DataOnlyBridgeAdapterMode.NOT_SUPPORTED),
            "accounting aDI still registered"
        );

        vm.selectFork(_arbFork);
        _earning.gateway.addDataOnlyBridgeAdapter(ETH_CHAIN_ID, address(ccip.earning));
        bytes32 earningAdiRemovalId =
            _earning.gateway.initiateDataOnlyBridgeAdapterRemoval(ETH_CHAIN_ID, address(_earning.adiAdapter));
        _earning.gateway
            .finalizeDataOnlyBridgeAdapterRemoval(ETH_CHAIN_ID, address(_earning.adiAdapter), earningAdiRemovalId);
        assertEq(
            uint8(_earning.gateway.getDataOnlyBridgeAdapterMode(ETH_CHAIN_ID, address(ccip.earning))),
            uint8(IChainGateway.DataOnlyBridgeAdapterMode.SEND_AND_RECEIVE),
            "earning CCIP not enabled"
        );
        assertEq(
            uint8(_earning.gateway.getDataOnlyBridgeAdapterMode(ETH_CHAIN_ID, address(_earning.adiAdapter))),
            uint8(IChainGateway.DataOnlyBridgeAdapterMode.NOT_SUPPORTED),
            "earning aDI still registered"
        );
    }

    function _migrateCcipToAdi(CcipDataOnlyAdapters memory ccip)
        internal
        returns (DataOnlyBridgeRemovalIds memory removalIds)
    {
        vm.selectFork(_ethFork);
        _accounting.gateway.addDataOnlyBridgeAdapter(ARB_CHAIN_ID, address(_accounting.adiAdapter));
        removalIds.accounting =
            _accounting.gateway.initiateDataOnlyBridgeAdapterRemoval(ARB_CHAIN_ID, address(ccip.accounting));
        assertEq(
            uint8(_accounting.gateway.getDataOnlyBridgeAdapterMode(ARB_CHAIN_ID, address(ccip.accounting))),
            uint8(IChainGateway.DataOnlyBridgeAdapterMode.RECEIVE_ONLY),
            "accounting CCIP not receive-only"
        );
        assertEq(
            uint8(_accounting.gateway.getDataOnlyBridgeAdapterMode(ARB_CHAIN_ID, address(_accounting.adiAdapter))),
            uint8(IChainGateway.DataOnlyBridgeAdapterMode.SEND_AND_RECEIVE),
            "accounting aDI not enabled"
        );

        vm.selectFork(_arbFork);
        _earning.gateway.addDataOnlyBridgeAdapter(ETH_CHAIN_ID, address(_earning.adiAdapter));
        removalIds.earning = _earning.gateway.initiateDataOnlyBridgeAdapterRemoval(ETH_CHAIN_ID, address(ccip.earning));
        assertEq(
            uint8(_earning.gateway.getDataOnlyBridgeAdapterMode(ETH_CHAIN_ID, address(ccip.earning))),
            uint8(IChainGateway.DataOnlyBridgeAdapterMode.RECEIVE_ONLY),
            "earning CCIP not receive-only"
        );
        assertEq(
            uint8(_earning.gateway.getDataOnlyBridgeAdapterMode(ETH_CHAIN_ID, address(_earning.adiAdapter))),
            uint8(IChainGateway.DataOnlyBridgeAdapterMode.SEND_AND_RECEIVE),
            "earning aDI not enabled"
        );
    }

    function _removeCcipDataOnlyAdapters(CcipDataOnlyAdapters memory ccip, DataOnlyBridgeRemovalIds memory removalIds)
        internal
    {
        vm.selectFork(_ethFork);
        _accounting.gateway
            .finalizeDataOnlyBridgeAdapterRemoval(ARB_CHAIN_ID, address(ccip.accounting), removalIds.accounting);
        assertEq(
            uint8(_accounting.gateway.getDataOnlyBridgeAdapterMode(ARB_CHAIN_ID, address(ccip.accounting))),
            uint8(IChainGateway.DataOnlyBridgeAdapterMode.NOT_SUPPORTED),
            "accounting CCIP still registered"
        );
        assertEq(
            uint8(_accounting.gateway.getDataOnlyBridgeAdapterMode(ARB_CHAIN_ID, address(_accounting.adiAdapter))),
            uint8(IChainGateway.DataOnlyBridgeAdapterMode.SEND_AND_RECEIVE),
            "accounting aDI not enabled after CCIP removal"
        );

        vm.selectFork(_arbFork);
        _earning.gateway.finalizeDataOnlyBridgeAdapterRemoval(ETH_CHAIN_ID, address(ccip.earning), removalIds.earning);
        assertEq(
            uint8(_earning.gateway.getDataOnlyBridgeAdapterMode(ETH_CHAIN_ID, address(ccip.earning))),
            uint8(IChainGateway.DataOnlyBridgeAdapterMode.NOT_SUPPORTED),
            "earning CCIP still registered"
        );
        assertEq(
            uint8(_earning.gateway.getDataOnlyBridgeAdapterMode(ETH_CHAIN_ID, address(_earning.adiAdapter))),
            uint8(IChainGateway.DataOnlyBridgeAdapterMode.SEND_AND_RECEIVE),
            "earning aDI not enabled after CCIP removal"
        );
    }

    function _depositIntoStableVault(uint256 depositAmount) internal {
        vm.selectFork(_ethFork);
        _accounting.asset.mint(_user, depositAmount);
        vm.startPrank(_user);
        _accounting.asset.approve(address(_accounting.vault), depositAmount);
        _accounting.vault.deposit(_user, address(_accounting.asset), depositAmount, "");
        vm.stopPrank();
    }

    function _requestAccountingWithdrawal(uint256 iouAmountRay) internal {
        vm.selectFork(_ethFork);
        vm.prank(_user);
        uint256 mintedIous = _accounting.vault.requestWithdrawal(_user, iouAmountRay, "");
        assertEq(mintedIous, iouAmountRay, "unexpected requested IOU amount");
    }

    function _airdropEarningLiquidity(uint256 amount) internal {
        vm.selectFork(_arbFork);
        _earning.asset.mint(address(_earning.transferHelper), amount);
        vm.prank(address(_earning.gateway));
        _earning.allocator.deposit(address(_earning.asset), amount);
    }

    function _bridgeAccountingIousToEarning(uint256 amountRay) internal returns (Vm.Log[] memory logs) {
        vm.selectFork(_ethFork);
        bytes memory message = _bridgeIouTokenMessage(_user, amountRay);
        uint256 nativeFee = _prepareForwardFeesFor(_user, _accounting.adiAdapter, ARB_CHAIN_ID, message);

        vm.recordLogs();
        vm.prank(_user);
        _accounting.iouTokenManager.bridgeTokens{value: nativeFee}(
            ARB_CHAIN_ID, _user, amountRay, address(_accounting.adiAdapter), DEFAULT_GAS_LIMIT, ""
        );
        logs = vm.getRecordedLogs();

        assertEq(_adiHelper.countSuccessfulForwards(logs), 1, "ETH->ARB IOU bridge should forward once");
    }

    function _bridgeAccountingIousToEarningViaCcip(uint256 amountRay, CcipAdapter ccipAdapter)
        internal
        returns (Vm.Log[] memory logs)
    {
        vm.selectFork(_ethFork);
        vm.deal(_user, CCIP_NATIVE_FEE_PAYMENT);

        vm.recordLogs();
        vm.prank(_user);
        _accounting.iouTokenManager.bridgeTokens{value: CCIP_NATIVE_FEE_PAYMENT}(
            ARB_CHAIN_ID, _user, amountRay, address(ccipAdapter), DEFAULT_GAS_LIMIT, _ccipNativeFeeData()
        );
        logs = vm.getRecordedLogs();

        _assertOneCcipMessage(logs);
    }

    function _relayAccountingToEarningViaAdi(Vm.Log[] memory logs) internal {
        _adiHelper.helpEthToArb(
            AdiHelper.EthToArbArgs({
                l2ForkId: _arbFork, l1Inbox: ARB_INBOX, l1Bridge: ARB_BRIDGE, expectedL1CCC: _ethCcc, logs: logs
            })
        );
    }

    function _relayAccountingToEarningViaCcip(Vm.Log[] memory logs) internal {
        new CcipHelper()
            .help(
                CcipHelper.HelpArgs({
                dstForkId: _arbFork,
                dstRouter: ARB_CCIP_ROUTER,
                expDstChainSelector: ARB_CCIP_CHAIN_SELECTOR,
                srcOnRamp: address(0),
                logs: logs
            })
            );
    }

    function _exchangeEarningIousForAssets(uint256 amountRay) internal returns (Vm.Log[] memory logs) {
        vm.selectFork(_arbFork);
        bytes memory message = _burnIouTokenMessage(amountRay, block.timestamp, block.number);
        uint256 nativeFee = _prepareForwardFeesFor(_user, _earning.adiAdapter, ETH_CHAIN_ID, message);

        vm.recordLogs();
        vm.prank(_user);
        _earning.gateway.exchangeIouTokens{value: nativeFee}(
            amountRay, address(_earning.asset), 0, _user, address(_earning.adiAdapter), DEFAULT_GAS_LIMIT, "", ""
        );
        logs = vm.getRecordedLogs();

        assertGe(_adiHelper.countSuccessfulForwards(logs), 2, "ARB->ETH IOU burn should meet forwarding threshold");
    }

    function _prepareForwardFeesFor(
        address feePayer,
        AdiAdapter adapter,
        uint256 destinationChainId,
        bytes memory message
    ) internal returns (uint256 nativeFee) {
        ICrossChainForwarder.Fee[] memory fees;
        uint256 successfulQuotes;
        (nativeFee, fees, successfulQuotes) =
            adapter.quoteMessageToChain(destinationChainId, message, DEFAULT_GAS_LIMIT);
        assertGt(successfulQuotes, 0, "no successful aDI quotes");

        for (uint256 i = 0; i < fees.length; i++) {
            if (fees[i].amount == 0) {
                continue;
            }
            deal(fees[i].token, feePayer, fees[i].amount);
            vm.prank(feePayer);
            IERC20(fees[i].token).approve(address(adapter), fees[i].amount);
        }

        if (nativeFee > 0) {
            vm.deal(feePayer, nativeFee);
        }
    }

    function _assertOneCcipMessage(Vm.Log[] memory logs) internal {
        CcipHelper ccipHelper = new CcipHelper();
        Vm.Log[] memory ccipLogs = ccipHelper.findLogs(logs, 1);
        bytes32 selector = ccipLogs[0].topics[0];
        assertTrue(
            selector == ccipHelper.CCIP_MESSAGE_SENT_SELECTOR()
                || selector == ccipHelper.CCIP_SEND_REQUESTED_SELECTOR(),
            "CCIP IOU bridge should emit one message"
        );
    }

    function _ccipNativeFeeData() internal pure returns (bytes memory) {
        return abi.encode(CcipAdapter.CcipFeeParams({feeToken: Constants.NATIVE_CURRENCY, nativeFeeRefundThreshold: 0}));
    }

    function _bridgeIouTokenMessage(address recipient, uint256 amountRay) internal pure returns (bytes memory) {
        return abi.encode(
            IChainGateway.CrossChainMessage({
                messageType: IChainGateway.MessageType.BRIDGE_IOU_TOKEN,
                data: abi.encode(IChainGateway.IouTokenBridgeMessage({recipient: recipient, amount: amountRay}))
            })
        );
    }

    function _burnIouTokenMessage(uint256 amountRay, uint256 timestamp, uint256 blockNumber)
        internal
        pure
        returns (bytes memory)
    {
        return abi.encode(
            IChainGateway.CrossChainMessage({
                messageType: IChainGateway.MessageType.BURN_IOU_TOKEN,
                data: abi.encode(
                    IChainGateway.BurnIouTokenMessage({
                        iouTokenAmountBurnedRay: amountRay, timestamp: timestamp, blockNumber: blockNumber
                    })
                )
            })
        );
    }

    function _configuredArbToEthRetryAdapters() internal view returns (address[] memory bridgeAdaptersToRetry) {
        uint256 adapterCount;
        if (_arbCcipAdapter != address(0)) {
            adapterCount++;
        }
        if (_arbLzAdapter != address(0)) {
            adapterCount++;
        }
        if (_arbHlAdapter != address(0)) {
            adapterCount++;
        }
        require(adapterCount >= 2, "ARB_ETH_RETRY_ADAPTERS_NOT_CONFIGURED");

        bridgeAdaptersToRetry = new address[](adapterCount);
        uint256 index;
        if (_arbCcipAdapter != address(0)) {
            bridgeAdaptersToRetry[index++] = _arbCcipAdapter;
        }
        if (_arbLzAdapter != address(0)) {
            bridgeAdaptersToRetry[index++] = _arbLzAdapter;
        }
        if (_arbHlAdapter != address(0)) {
            bridgeAdaptersToRetry[index++] = _arbHlAdapter;
        }
    }
}

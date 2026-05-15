// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

import {AdiAdapter} from "src/bridging/adi/AdiAdapter.sol";
import {Allocator} from "src/core/Allocator.sol";
import {AccountingChainGateway} from "src/core/accounting/AccountingChainGateway.sol";
import {FundsHandler} from "src/core/accounting/FundsHandler.sol";
import {StableVault} from "src/core/accounting/StableVault.sol";
import {EarningChainGateway} from "src/core/earning/EarningChainGateway.sol";
import {IouToken} from "src/core/ious/IouToken.sol";
import {IouTokenManager} from "src/core/ious/IouTokenManager.sol";
import {IAdiCrossChainForwarder} from "src/interfaces/IAdiCrossChainForwarder.sol";
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

    uint256 internal constant DEFAULT_MAX_PER_SECOND_RATE = 1000000005781378656804591713; // ~20% APY
    uint256 internal constant BURN_IOU_TOKEN_GAS_LIMIT = 120_000;
    uint256 internal constant MAX_ACTIVE_SUB_VAULTS = 201;
    uint8 internal constant MAX_STRATEGIES_PER_ASSET = 15;

    address internal _proxyAdmin = makeAddr("PROXY_ADMIN");
    address internal _admin = makeAddr("ADI_IOU_ADMIN");
    address internal _treasury = makeAddr("ADI_IOU_TREASURY");
    address internal _user = makeAddr("ADI_IOU_USER");

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
        uint256 userAssetBefore = _earning.asset.balanceOf(_user);
        uint256 burnSourceBlock = block.number;

        Vm.Log[] memory burnLogs = _exchangeEarningIousForAssets(iouAmountRay);

        assertEq(_earning.iouToken.balanceOf(_user), 0, "earning IOUs not burned");
        assertEq(_earning.iouToken.totalSupply(), 0, "earning IOU supply not burned");
        assertGt(_earning.asset.balanceOf(_user), userAssetBefore, "user did not receive earning-chain assets");

        vm.selectFork(_ethFork);
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
                    address(new WithdrawalExecutionPolicy(vaultAddress)),
                    _proxyAdmin,
                    abi.encodeCall(WithdrawalExecutionPolicy.initialize, (address(stack.accessManager), 0))
                )
            )
        );
        require(
            address(stack.withdrawalExecutionPolicy) == withdrawalExecutionPolicyAddress,
            "withdrawal execution policy address mismatch"
        );

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
                    address(new WithdrawalExecutionPolicy(gatewayAddress)),
                    _proxyAdmin,
                    abi.encodeCall(WithdrawalExecutionPolicy.initialize, (address(stack.accessManager), 0))
                )
            )
        );
        require(
            address(stack.withdrawalExecutionPolicy) == withdrawalExecutionPolicyAddress,
            "earning withdrawal execution policy address mismatch"
        );

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
        stack.allocator.setDefaultStrategy(address(stack.asset), address(stack.strategy));
        stack.fundsHandler.addEarningChain(ARB_CHAIN_ID);
        stack.gateway.addBridgeAdapter(Constants.ASSET_FOR_DATA_ONLY_BRIDGE, ARB_CHAIN_ID, address(stack.adiAdapter));
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
        stack.allocator.setDefaultStrategy(address(stack.asset), address(stack.strategy));
        stack.gateway.addBridgeAdapter(Constants.ASSET_FOR_DATA_ONLY_BRIDGE, ETH_CHAIN_ID, address(stack.adiAdapter));
    }

    function _wireStacks() internal {
        vm.selectFork(_ethFork);
        _accounting.adiAdapter.setDestinationChainAdapter(ARB_CHAIN_ID, address(_earning.adiAdapter));
        _approveAdiAdapter(_ethCcc, address(_accounting.adiAdapter));

        vm.selectFork(_arbFork);
        _earning.adiAdapter.setDestinationChainAdapter(ETH_CHAIN_ID, address(_accounting.adiAdapter));
        _approveAdiAdapter(_arbCcc, address(_earning.adiAdapter));
    }

    function _depositIntoStableVault(uint256 depositAmount) internal {
        vm.selectFork(_ethFork);
        _accounting.asset.mint(_user, depositAmount);
        vm.startPrank(_user);
        _accounting.asset.approve(address(_accounting.vault), depositAmount);
        _accounting.vault.deposit(_user, address(_accounting.asset), depositAmount, "");
        vm.stopPrank();
    }

    function _airdropEarningLiquidity(uint256 amount) internal {
        vm.selectFork(_arbFork);
        _earning.asset.mint(address(_earning.transferHelper), amount);
        vm.prank(address(_earning.gateway));
        _earning.allocator.depositAllowIdle(address(_earning.asset), amount);
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
        IAdiCrossChainForwarder.Fee[] memory fees;
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
}

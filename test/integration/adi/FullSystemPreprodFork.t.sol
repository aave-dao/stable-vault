// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICrossChainForwarder} from "aave-delivery-infrastructure/contracts/interfaces/ICrossChainForwarder.sol";
import {Vm} from "forge-std/Vm.sol";

import {AdiAdapter} from "src/bridging/adi/AdiAdapter.sol";
import {StableVault} from "src/core/accounting/StableVault.sol";
import {EarningChainGateway} from "src/core/earning/EarningChainGateway.sol";
import {IouTokenManager} from "src/core/ious/IouTokenManager.sol";
import {IChainBalanceOracle} from "src/interfaces/IChainBalanceOracle.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";

import {AdiHelper} from "pigeon/src/adi/AdiHelper.sol";

import {AdiAdapterPigeonLocalForkBase} from "./AdiAdapterPigeonLocalForkBase.sol";
import {AccountingChainForkHarness, EarningChainForkHarness} from "./PreprodForkHarnesses.sol";

/// @notice End-to-end check over the deployed contracts: runs the real preprod deploy scripts on both forks, then
/// drives a deposit -> requestWithdrawal -> bridge-IOU -> exchange/burn round trip over the deployed gateway /
/// IouTokenManager /
/// AdiAdapter, relayed by Pigeon through the real preprod a.DI CrossChainController. Accounting chain = Arbitrum,
/// earning chain = Ethereum, matching the preprod config. Skipped unless FORK_TEST=true; run via
/// run-adi-pigeon-fork-test.sh.
contract FullSystemPreprodFork is AdiAdapterPigeonLocalForkBase {
    string internal constant EARNING_OUTPUT = "deployments/fullsystem-earning.forktest.json";
    string internal constant ACCOUNTING_OUTPUT = "deployments/fullsystem-accounting.forktest.json";

    uint256 internal constant DEPOSIT_AMOUNT = 80e6; // 80 USDC, under the 100 USDC deposit cap.
    uint256 internal constant WITHDRAWAL_RAY = 50e27; // $50 principal request, under the $200 redemption cap.
    uint256 internal constant EARNING_LIQUIDITY = 1_000e6; // Idle USDC seeded into the earning Allocator for the
    // payout.

    address internal _user = makeAddr("FULL_SYSTEM_USER");

    // Deterministic CREATE3 addresses (identical on both chains), resolved from the deploy harness.
    address internal _accessManager;
    address internal _adiAdapter;

    address internal _accVault;
    address internal _accIouToken;
    address internal _accIouTokenManager;
    address internal _accAdapter;
    address internal _accChainBalanceOracle;
    address internal _accUsdc; // accounting-chain deposit asset, from the deploy config

    address internal _earnIouToken;
    address internal _earnGateway;
    address internal _earnAllocator;
    address internal _earnAdapter;
    address internal _earnUsdc; // earning-chain payout asset, from the deploy config

    enum BridgeAmb {
        Ccip,
        LayerZero,
        Hyperlane
    }

    function setUp() public override {
        if (!vm.envOr("FORK_TEST", false)) {
            return;
        }

        _ethFork = vm.createSelectFork(vm.envOr("ETH_FORK_RPC", DEFAULT_ETH_FORK_RPC));
        _arbFork = vm.createSelectFork(vm.envOr("ARB_FORK_RPC", DEFAULT_ARB_FORK_RPC));

        // a.DI CrossChainController + bridge-adapter addresses (env, from adi-deploy) and the AMB endpoints they wire,
        // used to relay the cross-chain messages once the Stable Vaults system is deployed below.
        _loadForkDeploymentConfig();
        _loadAmbEndpointsFromAdapters();

        // Earning chain (Ethereum).
        vm.selectFork(_ethFork);
        assertEq(block.chainid, ETH_CHAIN_ID, "expected Ethereum fork for earning chain");
        EarningChainForkHarness earning = new EarningChainForkHarness();
        earning.redirectOutputTo(EARNING_OUTPUT);
        _earnUsdc = earning.usdc();
        _fundDeployer(earning.deployerAddr(), earning.usdc(), earning.usdt(), address(0));
        // Un-finalized a.DI (e.g. canary) keeps owner/guardian on the deployer EOA; finalize on the fork so the
        // deploy validates. No-op for already-finalized environments (preprod/prod).
        _finalizeAdiHandoffOnForkIfNeeded(_ethCcc, earning.accessManagerAddr(), earning.adiAdapterAddr());
        earning.run();
        _earnIouToken = earning.iouTokenAddr();
        _earnGateway = earning.gatewayAddr();
        _earnAllocator = earning.allocatorAddr();
        _earnAdapter = earning.adiAdapterAddr();
        _accessManager = earning.accessManagerAddr();
        _adiAdapter = earning.adiAdapterAddr();
        assertEq(earning.adiCccAddr(), _ethCcc, "SV earning config CCC != adi-deploy ETH CCC");

        // Accounting chain (Arbitrum).
        vm.selectFork(_arbFork);
        assertEq(block.chainid, ARB_CHAIN_ID, "expected Arbitrum fork for accounting chain");
        AccountingChainForkHarness accounting = new AccountingChainForkHarness();
        accounting.redirectOutputTo(ACCOUNTING_OUTPUT);
        _accUsdc = accounting.usdc();
        _fundDeployer(accounting.deployerAddr(), accounting.usdc(), accounting.usdt(), accounting.gho());
        // Un-finalized a.DI (e.g. canary) keeps owner/guardian on the deployer EOA; finalize on the fork so the
        // deploy validates. No-op for already-finalized environments (preprod/prod).
        _finalizeAdiHandoffOnForkIfNeeded(_arbCcc, accounting.accessManagerAddr(), accounting.adiAdapterAddr());
        accounting.run();
        _accVault = accounting.stableVaultAddr();
        _accIouToken = accounting.iouTokenAddr();
        _accIouTokenManager = accounting.iouTokenManagerAddr();
        _accAdapter = accounting.adiAdapterAddr();
        _accChainBalanceOracle = accounting.chainBalanceOracleAddr();
        assertEq(accounting.adiCccAddr(), _arbCcc, "SV accounting config CCC != adi-deploy ARB CCC");

        // Pigeon helpers, deployed while the Arbitrum fork is selected so the ARB->ETH relay runs from the src fork.
        _deployPigeonHelpers();
    }

    /// @notice Full cross-chain round trip over the deployed contracts: deposit on Arbitrum, request a withdrawal to
    /// mint accounting IOUs, bridge them to Ethereum (minting earning IOUs), then exchange those earning IOUs for
    /// assets which burns them and relays a BURN_IOU_TOKEN message back to Arbitrum to burn the locked accounting IOUs.
    function test_fullSystem_depositBridgeAndBurnBack() external onlyForkTest {
        // Both deploys landed on the same deterministic adapter the a.DI handoff delegated control to.
        assertEq(_accAdapter, _adiAdapter, "accounting adapter address mismatch");
        assertEq(_earnAdapter, _adiAdapter, "earning adapter address mismatch");
        assertGt(_accessManager.code.length, 0, "AccessManager not deployed on accounting fork");

        _bridgeAccountingIousToEarning();
        _exchangeEarningIousAndBurnBack();
    }

    /// @notice Stage the ARB->ETH bridge delivery one a.DI adapter at a time against the deployed earning chain: a
    /// single confirmation stays below the 2-of-3 quorum (no mint), the second reaches quorum (mint), and a third,
    /// over-quorum delivery is recorded without minting again (a.DI envelope replay protection).
    function test_bridge_quorumStagedThenNoReplay() external onlyForkTest {
        Vm.Log[] memory bridgeLogs = _depositRequestAndBridge();

        // Below quorum: CCIP alone is one confirmation, short of requiredConfirmations = 2 on Ethereum.
        _relayBridgeAmb(bridgeLogs, BridgeAmb.Ccip);
        vm.selectFork(_ethFork);
        assertEq(IERC20(_earnIouToken).balanceOf(_user), 0, "earning IOUs minted below quorum");
        assertEq(IERC20(_earnIouToken).totalSupply(), 0, "earning IOU supply non-zero below quorum");

        // Quorum reached: LayerZero is the second distinct confirmation, so the earning chain mints.
        _relayBridgeAmb(bridgeLogs, BridgeAmb.LayerZero);
        vm.selectFork(_ethFork);
        assertEq(IERC20(_earnIouToken).balanceOf(_user), WITHDRAWAL_RAY, "earning IOUs not minted at quorum");
        assertEq(IERC20(_earnIouToken).totalSupply(), WITHDRAWAL_RAY, "earning IOU supply wrong at quorum");

        // Over quorum / replay: Hyperlane arrives after the envelope already executed; it is recorded but does not
        // mint.
        _relayBridgeAmb(bridgeLogs, BridgeAmb.Hyperlane);
        vm.selectFork(_ethFork);
        assertEq(IERC20(_earnIouToken).balanceOf(_user), WITHDRAWAL_RAY, "over-quorum delivery minted again");
        assertEq(IERC20(_earnIouToken).totalSupply(), WITHDRAWAL_RAY, "over-quorum delivery changed earning supply");
    }

    /// @dev Accounting (Arbitrum) -> earning (Ethereum): deposit, request withdrawal, lock + bridge the IOUs through
    /// the deployed AdiAdapter and real preprod CCC, relay all three adapters via Pigeon, and assert the earning chain
    /// mints.
    function _bridgeAccountingIousToEarning() internal {
        Vm.Log[] memory bridgeLogs = _depositRequestAndBridge();

        // Nothing minted on the earning chain before the relay.
        vm.selectFork(_ethFork);
        assertEq(IERC20(_earnIouToken).balanceOf(_user), 0, "earning IOUs minted before relay");
        assertEq(IERC20(_earnIouToken).totalSupply(), 0, "earning IOU supply non-zero before relay");

        // Relay the three a.DI bridge messages (CCIP + LayerZero + Hyperlane) into the Ethereum CCC; quorum mints.
        vm.selectFork(_arbFork);
        _adiHelper.helpMultiBridge(
            AdiHelper.MultiBridgeArgs({
                dstForkId: _ethFork,
                dstCcipRouter: ETH_CCIP_ROUTER,
                dstCcipChainSelector: ETH_CCIP_CHAIN_SELECTOR,
                srcCcipOnRamp: address(0),
                dstLzEndpoint: LZ_ENDPOINT_V2,
                srcHlMailbox: ARB_HL_MAILBOX,
                dstHlMailbox: ETH_HL_MAILBOX,
                logs: bridgeLogs
            })
        );

        // The earning chain minted the IOUs to the user.
        vm.selectFork(_ethFork);
        assertEq(IERC20(_earnIouToken).balanceOf(_user), WITHDRAWAL_RAY, "earning IOUs not minted after relay");
        assertEq(IERC20(_earnIouToken).totalSupply(), WITHDRAWAL_RAY, "earning IOU supply not minted after relay");
    }

    /// @dev Deposit on Arbitrum, request a withdrawal (mints accounting IOUs), then lock + bridge them toward Ethereum
    /// over the deployed AdiAdapter and real preprod CCC. Returns the source forward logs without relaying, so callers
    /// control how the destination receives them. Asserts all three generic adapters forwarded and the IOUs are locked.
    function _depositRequestAndBridge() internal returns (Vm.Log[] memory bridgeLogs) {
        vm.selectFork(_arbFork);
        deal(_accUsdc, _user, DEPOSIT_AMOUNT);
        vm.startPrank(_user);
        IERC20(_accUsdc).approve(_accVault, DEPOSIT_AMOUNT);
        StableVault(_accVault).deposit(_user, _accUsdc, DEPOSIT_AMOUNT, "");
        vm.stopPrank();

        vm.prank(_user);
        uint256 mintedIous = StableVault(_accVault).requestWithdrawal(_user, WITHDRAWAL_RAY, "");
        assertEq(mintedIous, WITHDRAWAL_RAY, "unexpected requested IOU amount");
        assertEq(IERC20(_accIouToken).balanceOf(_user), WITHDRAWAL_RAY, "accounting IOUs not minted");

        bytes memory message = _bridgeIouTokenMessage(_user, WITHDRAWAL_RAY);
        uint256 nativeFee = _prepareForwardFeesFor(_user, AdiAdapter(_accAdapter), ETH_CHAIN_ID, message);

        vm.recordLogs();
        vm.prank(_user);
        IouTokenManager(_accIouTokenManager).bridgeTokens{value: nativeFee}(
            ETH_CHAIN_ID, _user, WITHDRAWAL_RAY, _accAdapter, DEFAULT_GAS_LIMIT, ""
        );
        bridgeLogs = vm.getRecordedLogs();
        // ARB->ETH forwards over all three generic a.DI adapters (CCIP + LayerZero + Hyperlane). We assert all three
        // engaged so a silently broken adapter is caught instead of being masked by the 2-of-3 receiver quorum.
        assertEq(_adiHelper.countSuccessfulForwards(bridgeLogs), 3, "ARB->ETH bridge should forward via all 3 adapters");
        assertEq(IERC20(_accIouToken).balanceOf(_user), 0, "accounting IOUs not locked on bridge");
        assertEq(IouTokenManager(_accIouTokenManager).getLockedBalance(), WITHDRAWAL_RAY, "IOUs not locked");
    }

    /// @dev Relay only a single AMB's leg of an ARB->ETH a.DI envelope by disabling the other two routers/endpoints.
    function _relayBridgeAmb(Vm.Log[] memory bridgeLogs, BridgeAmb amb) internal {
        _adiHelper.helpMultiBridge(
            AdiHelper.MultiBridgeArgs({
                dstForkId: _ethFork,
                dstCcipRouter: amb == BridgeAmb.Ccip ? ETH_CCIP_ROUTER : address(0),
                dstCcipChainSelector: amb == BridgeAmb.Ccip ? ETH_CCIP_CHAIN_SELECTOR : uint64(0),
                srcCcipOnRamp: address(0),
                dstLzEndpoint: amb == BridgeAmb.LayerZero ? LZ_ENDPOINT_V2 : address(0),
                srcHlMailbox: amb == BridgeAmb.Hyperlane ? ARB_HL_MAILBOX : address(0),
                dstHlMailbox: amb == BridgeAmb.Hyperlane ? ETH_HL_MAILBOX : address(0),
                logs: bridgeLogs
            })
        );
    }

    /// @dev Earning (Ethereum) -> accounting (Arbitrum): exchange the earning IOUs for assets (burns them locally and
    /// sends a BURN_IOU_TOKEN message), relay it over the Arbitrum-native a.DI path, and assert the locked accounting
    /// IOUs are burned. The accounting ChainBalanceOracle is mocked to a fresh snapshot so the burn's freshness guard
    /// (_validateInboundMessageBlockNumber) passes without a real cross-chain oracle update.
    function _exchangeEarningIousAndBurnBack() internal {
        vm.selectFork(_ethFork);

        // Seed the earning Allocator with idle USDC so the withdrawal payout is served without touching strategies.
        deal(_earnUsdc, _earnAllocator, EARNING_LIQUIDITY);
        uint256 userAssetBefore = IERC20(_earnUsdc).balanceOf(_user);
        uint256 burnBlockNumber = block.number;

        bytes memory burnMessage = _burnIouTokenMessage(WITHDRAWAL_RAY, block.timestamp, burnBlockNumber);
        uint256 nativeFee = _prepareForwardFeesFor(_user, AdiAdapter(_earnAdapter), ARB_CHAIN_ID, burnMessage);

        vm.recordLogs();
        vm.prank(_user);
        EarningChainGateway(_earnGateway).exchangeIouTokens{value: nativeFee}(
            WITHDRAWAL_RAY, _earnUsdc, 0, _user, _earnAdapter, DEFAULT_GAS_LIMIT, "", ""
        );
        Vm.Log[] memory burnLogs = vm.getRecordedLogs();
        // ETH->ARB uses the single Arbitrum-native adapter (Ethereum requiredForwardingSuccesses = 1, Arbitrum receiver
        // quorum = 1), so exactly one forward is expected here.
        assertEq(_adiHelper.countSuccessfulForwards(burnLogs), 1, "ETH->ARB burn should forward via the native adapter");

        // Earning IOUs burned, user paid out in earning-chain assets.
        assertEq(IERC20(_earnIouToken).balanceOf(_user), 0, "earning IOUs not burned");
        assertEq(IERC20(_earnIouToken).totalSupply(), 0, "earning IOU supply not burned");
        assertGt(IERC20(_earnUsdc).balanceOf(_user), userAssetBefore, "user did not receive earning-chain assets");

        // Accounting IOUs still locked until the burn message is relayed.
        vm.selectFork(_arbFork);
        assertEq(IouTokenManager(_accIouTokenManager).getLockedBalance(), WITHDRAWAL_RAY, "locked IOUs burned early");
        _mockFreshEarningChainBalance(burnBlockNumber);

        // Relay the BURN message Ethereum -> Arbitrum over the Arbitrum-native bridge.
        vm.selectFork(_ethFork);
        _adiHelper.helpEthToArb(
            AdiHelper.EthToArbArgs({
                l2ForkId: _arbFork, l1Inbox: ARB_INBOX, l1Bridge: ARB_BRIDGE, expectedL1CCC: _ethCcc, logs: burnLogs
            })
        );

        // Locked accounting IOUs are burned, closing the round trip.
        vm.selectFork(_arbFork);
        assertEq(IouTokenManager(_accIouTokenManager).getLockedBalance(), 0, "locked IOUs not burned");
        assertEq(IERC20(_accIouToken).balanceOf(_accIouTokenManager), 0, "manager still holds IOUs");
        assertEq(IERC20(_accIouToken).totalSupply(), 0, "accounting IOU supply not burned");
    }

    /// @dev Mock the accounting ChainBalanceOracle so the earning-chain balance snapshot is fresh enough to accept a
    /// burn message stamped at `burnBlockNumber`; production gets this from the real cross-chain oracle update.
    function _mockFreshEarningChainBalance(uint256 burnBlockNumber) internal {
        IChainBalanceOracle.ChainBalance memory fresh = IChainBalanceOracle.ChainBalance({
            balanceRay: 0,
            lastUpdateTimestamp: block.timestamp,
            sourceChainTimestamp: block.timestamp,
            sourceChainBlockNumber: burnBlockNumber + 1_000_000,
            isStale: false
        });
        vm.mockCall(
            _accChainBalanceOracle,
            abi.encodeWithSelector(IChainBalanceOracle.getChainBalance.selector, ETH_CHAIN_ID),
            abi.encode(fresh)
        );
    }

    /// @dev Fund the deployer with native gas and 1-unit-plus of each aTokenVault underlying the deploy locks. `gho` is
    /// address(0) on the earning chain (GHO routes to sGho there, no aTokenVault).
    function _fundDeployer(address deployer, address usdc, address usdt, address gho) internal {
        vm.deal(deployer, 1000 ether);
        deal(usdc, deployer, 1_000e6);
        deal(usdt, deployer, 1_000e6);
        if (gho != address(0)) {
            deal(gho, deployer, 1_000e18);
        }
    }

    /// @dev Quote the a.DI forward, fund the fee payer with each required fee token plus native, and approve the
    /// adapter.
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

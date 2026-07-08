// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Client} from "@chainlink-ccip/contracts/libraries/Client.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import {CcipAdapter} from "src/bridging/ccip/CcipAdapter.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {Constants} from "src/types/Constants.sol";

import {BaseTest} from "test/BaseTest.t.sol";
import {MockGateway} from "test/mocks/MockGateway.sol";

/// @title BurnIouTokenGasTest
/// @notice Measures the gas cost of processing a BURN_IOU_TOKEN message.
/// Used to determine the payload gas limit and CCIP data-only receive overhead.
/// @dev Destination execution flow measured by these tests and should be deterministic:
/// OffRamp.executeSingleMessage()                                  // paid by CCIP executor (DON)
///   -> validates Merkle proof, source chain, nonce                // paid by executor
///   -> processes token transfers (pools)                          // paid by executor
///   -> Router.routeMessage(msg, gasCheck, receiverExecutionGasLimit, receiver)
///      -> CallWithExactGas._callWithExactGasSafeReturnData(...)
///         -> CALL(receiverExecutionGasLimit, receiver, ...)
///            -> CcipAdapter.ccipReceive(message)
///               -> CcipAdapter._validateMessageSource
///               -> CcipAdapter._processMessage
///                  -> AccountingChainGateway.receiveMessage        // payloadExecutionGasLimit starts here
///                     -> AccountingChainGateway._receiveData
///                        -> AccountingChainGateway._burnIouToken
///                           -> ChainBalanceOracle.getChainBalance
///                           -> IouTokenManager.burnLockedTokens
///                              -> IouToken.burn
///
/// Offramp/router work and the `CallWithExactGas` pre-check overhead are outside both limits.
/// The adapter adds DATA_ONLY_RECEIVE_GAS_OVERHEAD to the user-provided payloadExecutionGasLimit before passing it to
/// CCIP as receiverExecutionGasLimit.
contract BurnIouTokenGasTest is BaseTest {
    string internal NAMESPACE = "BurnIouToken";
    uint256 internal constant ENFORCED_BURN_IOU_TOKEN_PAYLOAD_EXECUTION_GAS_LIMIT = 120_000;

    // keccak256(abi.encode(uint256(keccak256("aave.storage.IouTokenManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT_IOU_TOKEN_MANAGER =
        0xc66e11a4855dc9db3d359cf776e012e79f530b562e1a94c415417157a76d1500;

    uint256 burnAmount = 1000e27; // 1000 IOUs in RAY

    function setUp() public override {
        super.setUp();

        // Mint IOU tokens directly to the accounting chain IouTokenManager (simulating locked tokens).
        vm.prank(address(vault));
        iouTokenManager_accountingChain.mintTokens(address(iouTokenManager_accountingChain), burnAmount);

        // Set lockedBalance to match minted amount.
        vm.store(address(iouTokenManager_accountingChain), STORAGE_SLOT_IOU_TOKEN_MANAGER, bytes32(burnAmount));

        // Publish a chain balance snapshot with current block.number so the message won't revert
        // with StaleChainBalance.
        _mockChainBalance(
            EARNING_CHAIN_ID,
            10_000e27,
            block.timestamp,
            block.timestamp - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS,
            false
        );
    }

    function _buildBurnIouTokenPayload(uint256 amount) internal view returns (bytes memory) {
        return abi.encode(
            IChainGateway.CrossChainMessage({
                messageType: IChainGateway.MessageType.BURN_IOU_TOKEN,
                data: abi.encode(
                    IChainGateway.BurnIouTokenMessage({
                        iouTokenAmountBurnedRay: amount, timestamp: block.timestamp, blockNumber: block.number
                    })
                )
            })
        );
    }

    function _buildDataOnlyCcipMessage(bytes memory payload, bytes32 messageId)
        internal
        view
        returns (Client.Any2EVMMessage memory)
    {
        return Client.Any2EVMMessage({
            messageId: messageId,
            sourceChainSelector: EARNING_CHAIN_CCIP_SELECTOR,
            sender: abi.encode(address(ccipAdapter_earningChain)),
            data: payload,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
    }

    function _buildBurnIouTokenCcipMessage() internal view returns (Client.Any2EVMMessage memory) {
        return _buildDataOnlyCcipMessage(_buildBurnIouTokenPayload(burnAmount), keccak256("burn-iou-gas-test"));
    }

    function _deployAdapterWithNoopGateway() internal returns (CcipAdapter adapter) {
        MockGateway noopGateway = new MockGateway();
        adapter = new CcipAdapter(
            accessManager_accountingChainAddress,
            address(noopGateway),
            address(mockCcipRouter),
            transferHelper_accountingChainAddress,
            assetRegistry_accountingChainAddress
        );

        vm.mockCall(
            accessManager_accountingChainAddress,
            abi.encodeWithSelector(IAccessManager.canCall.selector),
            abi.encode(true, uint32(0))
        );

        vm.startPrank(everyRoleAccount);
        adapter.setChainSelector(EARNING_CHAIN_ID, EARNING_CHAIN_CCIP_SELECTOR);
        adapter.setDestinationChainAdapter(EARNING_CHAIN_ID, address(ccipAdapter_earningChain));
        vm.stopPrank();
    }

    /// @notice Measures the payload execution gas from AccountingChainGateway.receiveMessage and downstream.
    function test_receiveMessage_burnIouToken_payloadExecution_gasUsed() public {
        bytes memory burnPayload = _buildBurnIouTokenPayload(burnAmount);

        vm.prank(address(ccipAdapter_accountingChain));
        accountingChainGateway.receiveMessage(EARNING_CHAIN_ID, Constants.ASSET_FOR_DATA_ONLY_BRIDGE, 0, burnPayload);
        vm.snapshotGasLastCall(NAMESPACE, "[receiveMessage] BURN_IOU_TOKEN payload");
    }

    /// @notice Measures data-only CCIP adapter receive overhead against a no-op gateway.
    function test_ccipReceive_dataOnlyAdapterOverhead_gasUsed() public {
        CcipAdapter adapter = _deployAdapterWithNoopGateway();
        Client.Any2EVMMessage memory ccipMessage = _buildDataOnlyCcipMessage({
            payload: abi.encode(keccak256("noop-payload")), messageId: keccak256("data-only-overhead")
        });

        vm.prank(address(mockCcipRouter));
        adapter.ccipReceive(ccipMessage);
        vm.snapshotGasLastCall(NAMESPACE, "[ccipReceive] data-only adapter overhead");
    }

    function test_ccipReceive_dataOnlyAdapterOverhead_succeedsWithConfiguredGasLimit() public {
        CcipAdapter adapter = _deployAdapterWithNoopGateway();
        Client.Any2EVMMessage memory ccipMessage = Client.Any2EVMMessage({
            messageId: keccak256("data-only-overhead-exact-gas"),
            sourceChainSelector: EARNING_CHAIN_CCIP_SELECTOR,
            sender: abi.encode(address(ccipAdapter_earningChain)),
            data: abi.encode(keccak256("noop-payload")),
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

        (bool success,, uint256 gasUsed) =
            mockCcipRouter.routeMessage(ccipMessage, 5_000, adapter.getDataOnlyReceiveGasOverhead(), address(adapter));

        assertTrue(success, "Should succeed with the configured data-only receive overhead");
        emit log_named_uint("Data-only adapter overhead gas used", gasUsed);
    }

    /// @notice Measures receiver gas: CCIP adapter overhead plus BURN_IOU_TOKEN payload execution.
    function test_ccipReceive_burnIouToken_gasUsed() public {
        Client.Any2EVMMessage memory ccipMessage = _buildBurnIouTokenCcipMessage();

        vm.prank(address(mockCcipRouter));
        ccipAdapter_accountingChain.ccipReceive(ccipMessage);
        vm.snapshotGasLastCall(NAMESPACE, "[ccipReceive] BURN_IOU_TOKEN");
    }

    /// @notice Same measurement with a small burn amount to check if amount affects gas.
    function test_ccipReceive_burnIouToken_smallAmount_gasUsed() public {
        uint256 smallBurnAmount = 1e27; // 1 IOU

        Client.Any2EVMMessage memory ccipMessage =
            _buildDataOnlyCcipMessage(_buildBurnIouTokenPayload(smallBurnAmount), keccak256("burn-iou-gas-test-small"));

        vm.prank(address(mockCcipRouter));
        ccipAdapter_accountingChain.ccipReceive(ccipMessage);
        vm.snapshotGasLastCall(NAMESPACE, "[ccipReceive] BURN_IOU_TOKEN - small amount");
    }

    /// @notice Demonstrates that the MockCCIPRouter rejects the message when gasLimit is too low.
    /// The router calls ccipReceive with exact gas, and if it runs out, the call fails.
    function test_burnIouToken_failsWithInsufficientGasLimit() public {
        Client.Any2EVMMessage memory ccipMessage = _buildBurnIouTokenCcipMessage();

        uint256 tooLowGasLimit = 30_000;

        (bool success,, uint256 gasUsed) = mockCcipRouter.routeMessage(
            ccipMessage,
            5_000, // gasForCallExactCheck
            tooLowGasLimit,
            address(ccipAdapter_accountingChain)
        );

        assertFalse(success, "Should fail with insufficient gas");
        emit log_named_uint("Gas used before OOG", gasUsed);
    }

    /// @notice Demonstrates success with the enforced payload gas limit plus adapter overhead.
    function test_burnIouToken_succeedsWithEnforcedGasLimit() public {
        Client.Any2EVMMessage memory ccipMessage = _buildBurnIouTokenCcipMessage();
        uint256 receiverExecutionGasLimit = ENFORCED_BURN_IOU_TOKEN_PAYLOAD_EXECUTION_GAS_LIMIT
            + ccipAdapter_accountingChain.getDataOnlyReceiveGasOverhead();

        (bool success,, uint256 gasUsed) = mockCcipRouter.routeMessage(
            ccipMessage,
            5_000, // gasForCallExactCheck
            receiverExecutionGasLimit,
            address(ccipAdapter_accountingChain)
        );

        assertTrue(success, "Should succeed with the enforced gas limit");
        emit log_named_uint("Actual receiver gas used by ccipReceive", gasUsed);
    }

    /// @notice Binary-searches for the minimum receiver gas limit at which ccipReceive succeeds.
    function test_burnIouToken_findMinimumGasLimit() public {
        Client.Any2EVMMessage memory ccipMessage = _buildBurnIouTokenCcipMessage();

        uint256 low = 10_000;
        uint256 high = 500_000;

        while (high - low > 100) {
            uint256 mid = (low + high) / 2;

            // Re-setup state for each attempt since successful calls modify storage.
            uint256 snapshot = vm.snapshotState();

            (bool success,,) =
                mockCcipRouter.routeMessage(ccipMessage, 5_000, mid, address(ccipAdapter_accountingChain));

            vm.revertToState(snapshot);

            if (success) {
                high = mid;
            } else {
                low = mid;
            }
        }

        emit log_named_uint("Minimum gasLimit (within 100 gas)", high);
        emit log_named_uint("Recommended gasLimit (2x safety margin)", high * 2);
    }
}

// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {Client} from "@chainlink-ccip/contracts/libraries/Client.sol";

import {IChainGateway} from "src/interfaces/IChainGateway.sol";

import {BaseTest} from "test/BaseTest.t.sol";

/// @title BurnIouTokenGasTest
/// @notice Measures the gas cost of processing a BURN_IOU_TOKEN message on the accounting chain.
/// Used to determine the minimum CCIP gasLimit required for this message type.
/// @dev Destination execution flow measured by these tests and should be deterministic:
/// OffRamp.executeSingleMessage()                                  // paid by CCIP executor (DON)
///   -> validates Merkle proof, source chain, nonce                // paid by executor
///   -> processes token transfers (pools)                          // paid by executor
///   -> Router.routeMessage(msg, gasCheck, gasLimit, receiver)
///      -> CallWithExactGas._callWithExactGasSafeReturnData(...)
///         -> CALL(gasLimit, receiver, ...)                        // user's `gasLimit` starts here
///            -> CcipAdapter.ccipReceive(message)
///               -> CcipAdapter._validateMessageSource
///               -> CcipAdapter._processMessage
///                  -> AccountingChainGateway.receiveMessage
///                     -> AccountingChainGateway._receiveData
///                        -> AccountingChainGateway._burnIouToken
///                           -> ChainBalanceOracle.getChainBalance
///                           -> IouTokenManager.burnLockedTokens
///                              -> IouToken.burn
///
/// Offramp/router work and the `CallWithExactGas` pre-check overhead are outside the user's `gasLimit`.
/// The budget only needs to cover `ccipReceive` and everything it calls downstream.
contract BurnIouTokenGasTest is BaseTest {
    string internal NAMESPACE = "BurnIouToken";
    uint256 internal constant ENFORCED_BURN_IOU_TOKEN_GAS_LIMIT = 120_000;

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

    function _buildBurnIouTokenCcipMessage() internal view returns (Client.Any2EVMMessage memory) {
        bytes memory burnPayload = abi.encode(
            IChainGateway.CrossChainMessage({
                messageType: IChainGateway.MessageType.BURN_IOU_TOKEN,
                data: abi.encode(
                    IChainGateway.BurnIouTokenMessage({
                        iouTokenAmountBurnedRay: burnAmount, timestamp: block.timestamp, blockNumber: block.number
                    })
                )
            })
        );

        return Client.Any2EVMMessage({
            messageId: keccak256("burn-iou-gas-test"),
            sourceChainSelector: EARNING_CHAIN_CCIP_SELECTOR,
            sender: abi.encode(address(ccipAdapter_earningChain)),
            data: burnPayload,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });
    }

    /// @notice Measures the gas consumed by ccipReceive when processing a BURN_IOU_TOKEN message.
    /// This represents the total destination-chain gas that the CCIP gasLimit must cover.
    function test_ccipReceive_burnIouToken_gasUsed() public {
        Client.Any2EVMMessage memory ccipMessage = _buildBurnIouTokenCcipMessage();

        vm.prank(address(mockCcipRouter));
        ccipAdapter_accountingChain.ccipReceive(ccipMessage);
        vm.snapshotGasLastCall(NAMESPACE, "[ccipReceive] BURN_IOU_TOKEN");
    }

    /// @notice Same measurement with a small burn amount to check if amount affects gas.
    function test_ccipReceive_burnIouToken_smallAmount_gasUsed() public {
        uint256 smallBurnAmount = 1e27; // 1 IOU

        bytes memory burnPayload = abi.encode(
            IChainGateway.CrossChainMessage({
                messageType: IChainGateway.MessageType.BURN_IOU_TOKEN,
                data: abi.encode(
                    IChainGateway.BurnIouTokenMessage({
                        iouTokenAmountBurnedRay: smallBurnAmount, timestamp: block.timestamp, blockNumber: block.number
                    })
                )
            })
        );

        Client.Any2EVMMessage memory ccipMessage = Client.Any2EVMMessage({
            messageId: keccak256("burn-iou-gas-test-small"),
            sourceChainSelector: EARNING_CHAIN_CCIP_SELECTOR,
            sender: abi.encode(address(ccipAdapter_earningChain)),
            data: burnPayload,
            destTokenAmounts: new Client.EVMTokenAmount[](0)
        });

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

    /// @notice Demonstrates success with the enforced 120k gas limit and reports the actual gas consumed.
    function test_burnIouToken_succeedsWithEnforcedGasLimit() public {
        Client.Any2EVMMessage memory ccipMessage = _buildBurnIouTokenCcipMessage();

        (bool success,, uint256 gasUsed) = mockCcipRouter.routeMessage(
            ccipMessage,
            5_000, // gasForCallExactCheck
            ENFORCED_BURN_IOU_TOKEN_GAS_LIMIT,
            address(ccipAdapter_accountingChain)
        );

        assertTrue(success, "Should succeed with the enforced gas limit");
        emit log_named_uint("Actual gas used by ccipReceive", gasUsed);
    }

    /// @notice Binary-searches for the minimum gasLimit at which ccipReceive succeeds.
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

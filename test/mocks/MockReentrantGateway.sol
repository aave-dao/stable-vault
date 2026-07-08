// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Client} from "@chainlink-ccip/contracts/libraries/Client.sol";

import {IAny2EVMMessageReceiver} from "@chainlink-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";

/// @notice Mock gateway that attempts reentrancy when receiveMessage is called.
/// @dev Used for testing reentrancy protection in CcipAdapter.
contract MockReentrantGateway {
    enum ReentrancyMode {
        NONE,
        RETRY_MESSAGE,
        CCIP_RECEIVE
    }

    address public transferHelper;
    bool public shouldRevert;
    address public reentrancyTarget;
    bytes32 public reentrancyMessageId;
    ReentrancyMode public reentrancyMode;
    Client.Any2EVMMessage public reentrancyMessage;

    constructor(address _transferHelper) {
        transferHelper = _transferHelper;
    }

    function setShouldRevert(bool _shouldRevert) external {
        shouldRevert = _shouldRevert;
    }

    function setReentrancyTarget(address _target, bytes32 _messageId) external {
        reentrancyTarget = _target;
        reentrancyMessageId = _messageId;
        reentrancyMode = ReentrancyMode.RETRY_MESSAGE;
    }

    function setReentrancyTargetCcipReceive(address _target, Client.Any2EVMMessage calldata _message) external {
        reentrancyTarget = _target;
        reentrancyMessage = _message;
        reentrancyMode = ReentrancyMode.CCIP_RECEIVE;
    }

    function clearReentrancyTarget() external {
        reentrancyTarget = address(0);
        reentrancyMode = ReentrancyMode.NONE;
    }

    /// @notice Mock receiveMessage that can revert or attempt reentrancy
    function receiveMessage(uint256, address, uint256, bytes memory) external {
        if (shouldRevert) {
            revert("MockReentrantGateway: forced revert");
        }

        if (reentrancyMode == ReentrancyMode.CCIP_RECEIVE) {
            // Attempt to re-enter ccipReceive
            IAny2EVMMessageReceiver(reentrancyTarget).ccipReceive(reentrancyMessage);
        } else if (reentrancyMode == ReentrancyMode.RETRY_MESSAGE) {
            // Attempt to re-enter retryMessage using low-level call
            (bool success, bytes memory returnData) =
                reentrancyTarget.call(abi.encodeWithSignature("retryMessage(bytes32)", reentrancyMessageId));
            if (!success) {
                // Bubble up the revert
                assembly {
                    revert(add(returnData, 32), mload(returnData))
                }
            }
        }
    }
}

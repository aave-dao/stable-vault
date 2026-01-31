// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IAny2EVMMessageReceiver} from "@chainlink-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";
import {Client} from "@chainlink-ccip/contracts/libraries/Client.sol";

import {ICcipBridgeAdapter} from "src/interfaces/ICcipBridgeAdapter.sol";

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

    function receiveMessage(uint256, address, uint256, bytes calldata) external {
        if (shouldRevert) {
            revert("gateway error");
        }

        // Attempt reentrancy based on mode
        if (reentrancyTarget != address(0)) {
            if (reentrancyMode == ReentrancyMode.RETRY_MESSAGE) {
                ICcipBridgeAdapter(reentrancyTarget).retryMessage(reentrancyMessageId);
            } else if (reentrancyMode == ReentrancyMode.CCIP_RECEIVE) {
                IAny2EVMMessageReceiver(reentrancyTarget).ccipReceive(reentrancyMessage);
            }
        }
    }
}

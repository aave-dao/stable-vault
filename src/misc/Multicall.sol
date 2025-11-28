// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {IMulticall} from "src/interfaces/IMulticall.sol";

/// @title Multicall
/// @author Aave Labs
/// @notice This contract allows for batching multiple calls into a single call.
/// @dev Inspired by OpenZeppelin's Multicall contract.
abstract contract Multicall is IMulticall {
    /// @inheritdoc IMulticall
    function multicall(bytes[] calldata data) external returns (bytes[] memory) {
        bytes[] memory returnDatas = new bytes[](data.length);
        for (uint256 i; i < data.length; ++i) {
            (bool callSucceeded, bytes memory returnData) = address(this).delegatecall(data[i]);
            assembly ("memory-safe") {
                if iszero(callSucceeded) {
                    // Bubble up first revert
                    revert(add(returnData, 32), mload(returnData))
                }
            }
            returnDatas[i] = returnData;
        }
        return returnDatas;
    }
}

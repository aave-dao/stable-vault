// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

library EventLib {
    /// @notice Emitted when the manager is set.
    event ManagerSet(address manager);

    /// @notice Emitted when the allocator is set.
    event AllocatorSet(address allocator);
}

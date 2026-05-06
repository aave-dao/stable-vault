// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {Errors} from "src/types/Errors.sol";

/// @title RateLimitWindowLib
/// @author Aave Labs
/// @notice Rate-limit primitive shared across policies. Each window has a maximum capacity and refills linearly at a
/// fixed rate per second; operations consume from the available capacity and revert when it is exhausted.
library RateLimitWindowLib {
    /// @notice State and configuration of a rate-limit window. Grouped so a single mapping value carries both the
    /// admin-set parameters and the live availability tracking.
    /// @param maxAmount Maximum capacity of the window. A value of `0` disables the limit.
    /// @param refillRate Amount of capacity restored per second.
    /// @param currentAmount Capacity available at `lastUpdated`, never above `maxAmount`.
    /// @param lastUpdated Unix timestamp at which `currentAmount` was last written.
    struct Window {
        uint128 maxAmount;
        uint128 refillRate;
        uint128 currentAmount;
        uint128 lastUpdated;
    }

    /// @notice Thrown by `consume` when the operation amount exceeds the available capacity.
    /// @custom:selector 0x3f7b7a68
    error RateLimited();

    /// @notice Returns the available capacity at `block.timestamp`, refilled but not written back.
    /// @param window The window to read from.
    /// @return The capacity available for consumption right now.
    function preview(Window storage window) internal view returns (uint256) {
        uint256 maxAmount = window.maxAmount;
        uint256 currentAmount = window.currentAmount;
        if (currentAmount >= maxAmount) {
            return maxAmount;
        }
        uint256 refillRate = window.refillRate;
        if (refillRate == 0) {
            return currentAmount;
        }
        uint256 elapsed = block.timestamp - window.lastUpdated;
        if (elapsed == 0) {
            return currentAmount;
        }
        // Cap `elapsed` so `elapsed * refillRate` cannot overflow: past this point the result saturates at `maxAmount`.
        uint256 maxElapsed = maxAmount / refillRate + 1;
        if (elapsed >= maxElapsed) {
            return maxAmount;
        }
        uint256 newCurrentAmount = currentAmount + elapsed * refillRate;
        if (newCurrentAmount > maxAmount) {
            return maxAmount;
        }
        return newCurrentAmount;
    }

    /// @notice Refills the window and consumes `amount` from the available capacity.
    /// @param window The window to update.
    /// @param amount The amount to consume.
    function consume(Window storage window, uint256 amount) internal {
        uint256 available = preview(window);
        require(available >= amount, RateLimited());
        unchecked {
            // Casting to uint128 is safe because available - amount <= maxAmount <= type(uint128).max
            // forge-lint: disable-next-line(unsafe-typecast)
            window.currentAmount = uint128(available - amount);
        }
        // Casting to uint128 is safe because block.timestamp fits in uint128 for any practical chain lifetime.
        // forge-lint: disable-next-line(unsafe-typecast)
        window.lastUpdated = uint128(block.timestamp);
    }

    /// @notice Resets a window to full capacity with the supplied configuration. Starts the window full so callers
    /// don't have to wait a full refill cycle before honoring operations after enabling or updating a limit.
    /// @param window The window to configure.
    /// @param maxAmount Maximum capacity of the window. `0` disables the limit and requires `refillRate` to also be 0.
    /// @param refillRate Amount of capacity restored per second.
    function configure(Window storage window, uint128 maxAmount, uint128 refillRate) internal {
        require(maxAmount > 0 || refillRate == 0, Errors.InvalidParameter());
        window.maxAmount = maxAmount;
        window.refillRate = refillRate;
        window.currentAmount = maxAmount;
        // Casting to uint128 is safe because block.timestamp fits in uint128 for any practical chain lifetime.
        // forge-lint: disable-next-line(unsafe-typecast)
        window.lastUpdated = uint128(block.timestamp);
    }
}

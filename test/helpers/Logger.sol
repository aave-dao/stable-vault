// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {console} from "forge-std/console.sol";

/// @dev Wrapper of `console` to enable/disable logging on tests independently of Foundry's chosen verbosity level.
/// This allows to use the highest verbosity level (i.e. -vvvvv) without flooding the output with custom logs.
/// It'd also allow to add multiple levels of logging (e.g. debug, info, warning, error) instead of a single log
/// function, in case it becomes necessary.
library Logger {
    // Set to `true` to enable console logging output.
    bool constant LOGGING_ENABLED = false;

    function log(string memory s) internal pure {
        if (LOGGING_ENABLED) {
            console.log(s);
        }
    }

    function log(string memory s, address a) internal pure {
        if (LOGGING_ENABLED) {
            console.log(s, a);
        }
    }

    function log(string memory s, uint256 v) internal pure {
        if (LOGGING_ENABLED) {
            console.log(s, v);
        }
    }

    function log(string memory s, bool b) internal pure {
        if (LOGGING_ENABLED) {
            console.log(s, b);
        }
    }

    function log(string memory s, string memory s2) internal pure {
        if (LOGGING_ENABLED) {
            console.log(s, s2);
        }
    }

    function log(string memory s, uint256 a, address b, uint256 c) internal pure {
        if (LOGGING_ENABLED) {
            console.log(s, a, b, c);
        }
    }

    function logBytes(bytes memory b) internal pure {
        if (LOGGING_ENABLED) {
            console.logBytes(b);
        }
    }

    function logBytes32(bytes32 b) internal pure {
        if (LOGGING_ENABLED) {
            console.logBytes32(b);
        }
    }
}

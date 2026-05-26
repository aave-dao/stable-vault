// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {Vm} from "forge-std/Vm.sol";

library JsoncLib {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// Reads a JSONC file and returns parseable JSON. Strips `//` and `/* */` comments unless `JSONC_PRESTRIPPED=true`
    /// is set in the environment, in which case the file is returned verbatim.
    function read(string memory path) internal view returns (string memory) {
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory raw = VM.readFile(path);
        return VM.envOr("JSONC_PRESTRIPPED", false) ? raw : stripComments(raw);
    }

    function stripComments(string memory input) internal pure returns (string memory) {
        bytes memory inputBytes = bytes(input);
        bytes memory outputBytes = new bytes(inputBytes.length);
        uint256 outputLength;
        bool inString;
        bool escaped;

        for (uint256 i = 0; i < inputBytes.length; i++) {
            bytes1 char = inputBytes[i];

            if (inString) {
                outputBytes[outputLength++] = char;

                if (escaped) {
                    escaped = false;
                } else if (char == "\\") {
                    escaped = true;
                } else if (char == '"') {
                    inString = false;
                }
                continue;
            }

            if (char == '"') {
                inString = true;
                outputBytes[outputLength++] = char;
                continue;
            }

            if (char == "/" && i + 1 < inputBytes.length) {
                bytes1 nextChar = inputBytes[i + 1];
                if (nextChar == "/") {
                    i += 2;
                    while (i < inputBytes.length && inputBytes[i] != "\n" && inputBytes[i] != "\r") {
                        i++;
                    }
                    if (i < inputBytes.length) {
                        outputBytes[outputLength++] = inputBytes[i];
                    }
                    continue;
                }
                if (nextChar == "*") {
                    i += 2;
                    while (i + 1 < inputBytes.length && !(inputBytes[i] == "*" && inputBytes[i + 1] == "/")) {
                        if (inputBytes[i] == "\n" || inputBytes[i] == "\r") {
                            outputBytes[outputLength++] = inputBytes[i];
                        }
                        i++;
                    }
                    i++;
                    continue;
                }
            }

            outputBytes[outputLength++] = char;
        }

        bytes memory stripped = new bytes(outputLength);
        for (uint256 i = 0; i < outputLength; i++) {
            stripped[i] = outputBytes[i];
        }
        return string(stripped);
    }
}

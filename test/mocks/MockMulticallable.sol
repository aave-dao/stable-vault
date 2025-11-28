// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Multicall} from "src/misc/Multicall.sol";

contract MockMulticallable is Multicall {
    error SomeError();
    error SomeErrorWithParams(uint256 uintParam, address addressParam);

    function revertWithStringErrorMessage(string memory errorMessage) external pure {
        revert(errorMessage);
    }

    function revertWithSomeError() external pure {
        revert SomeError();
    }

    function revertWithSomeErrorWithParams(uint256 uintParam, address addressParam) external pure {
        revert SomeErrorWithParams(uintParam, addressParam);
    }

    function succeedReturningString(string memory stringValue) external pure returns (string memory) {
        return stringValue;
    }

    function succeedReturningUint(uint256 uintValue) external pure returns (uint256) {
        return uintValue;
    }

    function succeedReturningAddress(address addressValue) external pure returns (address) {
        return addressValue;
    }
}

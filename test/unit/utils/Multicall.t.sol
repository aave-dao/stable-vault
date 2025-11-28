// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {TestWithHelpers} from "../../helpers/TestWithHelpers.sol";
import {MockMulticallable} from "../../mocks/MockMulticallable.sol";

contract MulticallTest is TestWithHelpers {
    MockMulticallable mockMulticallable;

    function setUp() public {
        mockMulticallable = new MockMulticallable();
    }

    function test_multicall_bubblesUpExpectedError_stringErrorMessage() public {
        string memory errorMessage = "Some test error";

        bytes[] memory callDatas = new bytes[](1);
        callDatas[0] = abi.encodeWithSelector(MockMulticallable.revertWithStringErrorMessage.selector, errorMessage);

        vm.expectRevert(bytes(errorMessage));
        mockMulticallable.multicall(callDatas);
    }

    function test_multicall_bubblesUpExpectedError_customError() public {
        bytes[] memory callDatas = new bytes[](1);
        callDatas[0] = abi.encodeWithSelector(MockMulticallable.revertWithSomeError.selector);

        vm.expectRevert(MockMulticallable.SomeError.selector);
        mockMulticallable.multicall(callDatas);
    }

    function test_multicall_bubblesUpExpectedError_customErrorWithParams(uint256 uintParam, address addressParam)
        public
    {
        bytes[] memory callDatas = new bytes[](1);
        callDatas[0] =
            abi.encodeWithSelector(MockMulticallable.revertWithSomeErrorWithParams.selector, uintParam, addressParam);

        vm.expectRevert(abi.encodeWithSelector(MockMulticallable.SomeErrorWithParams.selector, uintParam, addressParam));
        mockMulticallable.multicall(callDatas);
    }

    function test_multicall_succeedsReturningString() public {
        string memory stringValue = "Some test string";

        bytes[] memory callDatas = new bytes[](1);
        callDatas[0] = abi.encodeWithSelector(MockMulticallable.succeedReturningString.selector, stringValue);

        bytes[] memory returnDatas = mockMulticallable.multicall(callDatas);
        assertEq(returnDatas.length, 1);
        assertEq(keccak256(returnDatas[0]), keccak256(abi.encode(stringValue)));
    }

    function test_multicall_succeedsReturningUint(uint256 uintValue) public {
        bytes[] memory callDatas = new bytes[](1);
        callDatas[0] = abi.encodeWithSelector(MockMulticallable.succeedReturningUint.selector, uintValue);

        bytes[] memory returnDatas = mockMulticallable.multicall(callDatas);
        assertEq(returnDatas.length, 1);
        assertEq(abi.decode(returnDatas[0], (uint256)), uintValue);
    }

    function test_multicall_succeedsReturningAddress(address addressValue) public {
        bytes[] memory callDatas = new bytes[](1);
        callDatas[0] = abi.encodeWithSelector(MockMulticallable.succeedReturningAddress.selector, addressValue);

        bytes[] memory returnDatas = mockMulticallable.multicall(callDatas);
        assertEq(returnDatas.length, 1);
        assertEq(abi.decode(returnDatas[0], (address)), addressValue);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

contract MockAccessManager {
    address internal immutable ADMIN;

    constructor(address initialAdminParam) {
        ADMIN = initialAdminParam;
    }

    // Allow by default, require to reject explicitly.
    mapping(address caller => mapping(address target => mapping(bytes4 selector => bool callRejected))) internal
        _callRejected;
    // A delay + timestamp approach can be used if we want to make it compatible with vm.warp.
    mapping(address caller => mapping(address target => mapping(bytes4 selector => uint32 delay))) internal _mockDelay;

    function mockCanCall(address caller, address target, bytes4 selector, bool allowCall, uint32 delay) external {
        _callRejected[caller][target][selector] = !allowCall;
        _mockDelay[caller][target][selector] = delay;
    }

    function mockAllowCall(address caller, address target, bytes4 selector, uint32 delay) external {
        _callRejected[caller][target][selector] = false;
        _mockDelay[caller][target][selector] = delay;
    }

    function mockRejectCall(address caller, address target, bytes4 selector, uint32 delay) external {
        _callRejected[caller][target][selector] = true;
        _mockDelay[caller][target][selector] = delay;
    }

    function mockCanCall(address caller, address target, bytes4 selector, bool allowCall) external {
        _callRejected[caller][target][selector] = !allowCall;
    }

    function mockAllowCall(address caller, address target, bytes4 selector) external {
        _callRejected[caller][target][selector] = false;
    }

    function mockRejectCall(address caller, address target, bytes4 selector) external {
        _callRejected[caller][target][selector] = true;
    }

    function canCall(address caller, address target, bytes4 selector)
        external
        view
        returns (bool allowed, uint32 delay)
    {
        return (!_callRejected[caller][target][selector], _mockDelay[caller][target][selector]);
    }
}

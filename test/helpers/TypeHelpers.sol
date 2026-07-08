// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

function _emptyUint256Array() pure returns (uint256[] memory) {
    uint256[] memory ret = new uint256[](0);
    return ret;
}

function _toSelectorArray(bytes4 selector) pure returns (bytes4[] memory) {
    bytes4[] memory selectors = new bytes4[](1);
    selectors[0] = selector;
    return selectors;
}

function _toSelectorArray(bytes4 selector0, bytes4 selector1) pure returns (bytes4[] memory) {
    bytes4[] memory selectors = new bytes4[](2);
    selectors[0] = selector0;
    selectors[1] = selector1;
    return selectors;
}

function _toSelectorArray(bytes4 selector0, bytes4 selector1, bytes4 selector2) pure returns (bytes4[] memory) {
    bytes4[] memory selectors = new bytes4[](3);
    selectors[0] = selector0;
    selectors[1] = selector1;
    selectors[2] = selector2;
    return selectors;
}

function _toSelectorArray(bytes4 selector0, bytes4 selector1, bytes4 selector2, bytes4 selector3)
    pure
    returns (bytes4[] memory)
{
    bytes4[] memory selectors = new bytes4[](4);
    selectors[0] = selector0;
    selectors[1] = selector1;
    selectors[2] = selector2;
    selectors[3] = selector3;
    return selectors;
}

function _toSelectorArray(bytes4 selector0, bytes4 selector1, bytes4 selector2, bytes4 selector3, bytes4 selector4)
    pure
    returns (bytes4[] memory)
{
    bytes4[] memory selectors = new bytes4[](5);
    selectors[0] = selector0;
    selectors[1] = selector1;
    selectors[2] = selector2;
    selectors[3] = selector3;
    selectors[4] = selector4;
    return selectors;
}

function _toUint256Array(uint256 n) pure returns (uint256[] memory) {
    uint256[] memory ret = new uint256[](1);
    ret[0] = n;
    return ret;
}

function _toUint256Array(uint256 n0, uint256 n1) pure returns (uint256[] memory) {
    uint256[] memory ret = new uint256[](2);
    ret[0] = n0;
    ret[1] = n1;
    return ret;
}

function _emptyBytesArray() pure returns (bytes[] memory) {
    bytes[] memory ret = new bytes[](0);
    return ret;
}

function _emptyBytes32Array() pure returns (bytes32[] memory) {
    return new bytes32[](0);
}

function _toBytesArray(bytes memory b) pure returns (bytes[] memory) {
    bytes[] memory ret = new bytes[](1);
    ret[0] = b;
    return ret;
}

function _toBytesArray(bytes memory b0, bytes memory b1) pure returns (bytes[] memory) {
    bytes[] memory ret = new bytes[](2);
    ret[0] = b0;
    ret[1] = b1;
    return ret;
}

function _toBoolArray(bool b) pure returns (bool[] memory) {
    bool[] memory ret = new bool[](1);
    ret[0] = b;
    return ret;
}

function _toBoolArray(bool b0, bool b1) pure returns (bool[] memory) {
    bool[] memory ret = new bool[](2);
    ret[0] = b0;
    ret[1] = b1;
    return ret;
}

function _emptyAddressArray() pure returns (address[] memory) {
    address[] memory ret = new address[](0);
    return ret;
}

function _toAddressArray(address a) pure returns (address[] memory) {
    address[] memory ret = new address[](1);
    ret[0] = a;
    return ret;
}

function _toAddressArray(address a0, address a1) pure returns (address[] memory) {
    address[] memory ret = new address[](2);
    ret[0] = a0;
    ret[1] = a1;
    return ret;
}

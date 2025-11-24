// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IMintableBurnableIERC20} from "./IMintableBurnableIERC20.sol";

interface IIouToken is IMintableBurnableIERC20 {
    function lock(address from, uint256 amount) external;
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IWithdrawalPolicy} from "../../src/interfaces/IWithdrawalPolicy.sol";

contract MockWithdrawalPolicy is IWithdrawalPolicy {
    function previewWithdrawal(address user, address assetOut, uint256 iouAmountRay, bytes memory data)
        external
        view
        override
        returns (uint256, uint16)
    {}
}

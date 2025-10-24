// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IChainGateway} from "./IChainGateway.sol";

interface IAccountingChainGateway is IChainGateway {
    error NotFundsHandler();

    function sendPushFundsToChainMessage(address asset, uint256 amount, uint256 targetChainId) external;
}

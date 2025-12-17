// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {ITransferHelper} from "src/interfaces/ITransferHelper.sol";

contract MockGateway is IChainGateway {
    address internal _transferHelper;
    uint256 internal _balanceToConsume;
    address internal _tokenToComsume;
    address internal _destination;

    function mockConsumeOnNextCall(
        address transferHelper,
        uint256 balanceToConsume,
        address tokenToComsumeBalance,
        address destination
    ) external {
        _transferHelper = transferHelper;
        _balanceToConsume = balanceToConsume;
        _tokenToComsume = tokenToComsumeBalance;
        _destination = destination;
    }

    function _mockConsume() internal {
        if (_balanceToConsume > 0) {
            ITransferHelper(_transferHelper).transfer(_tokenToComsume, _balanceToConsume, _destination);
        }
    }

    function sendBridgeIouTokenMessageWithFeePayer(
        uint256,
        /*destinationChainId*/
        address,
        /*iouTokenRecipient*/
        uint256,
        /*iouTokenAmountRay*/
        IBridgeAdapter.BridgeParams memory /*bridgeParams*/
    )
        external
        override
    {
        _mockConsume();
    }

    function getDefaultBridgeAdapter(address asset, uint256 chainId) external view returns (address) {}
    function addBridgeAdapter(address asset, uint256 chainId, address adapter) external {}
    function removeBridgeAdapter(address asset, uint256 chainId, address adapter) external {}
    function setDefaultBridgeAdapter(address asset, uint256 chainId, address adapter) external {}
    function receiveMessage(uint256 sourceChainId, IBridgeAdapter.BridgeAsset[] memory assets, bytes memory data)
        external {}
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {ITransferHelper} from "src/interfaces/ITransferHelper.sol";

contract MockGateway is IChainGateway {
    address internal _transferHelper;
    uint256 internal _balanceToConsume;
    address internal _tokenToComsume;

    function mockConsumeOnNextCall(address transferHelper, uint256 balanceToConsume, address tokenToComsumeBalance)
        external
    {
        _transferHelper = transferHelper;
        _balanceToConsume = balanceToConsume;
        _tokenToComsume = tokenToComsumeBalance;
    }

    function _mockConsume() internal {
        if (_balanceToConsume > 0) {
            ITransferHelper(_transferHelper).pull(_tokenToComsume, _balanceToConsume);
        }
    }

    function sendBridgeIouTokenMessageWithFeePayer(
        uint256,
        /*destinationChainId*/
        address,
        /*iouTokenRecipient*/
        uint256,
        /*iouTokenAmountRay*/
        IChainGateway.BridgeParams memory /*bridgeParams*/
    )
        external
        payable
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

    receive() external payable {}
}

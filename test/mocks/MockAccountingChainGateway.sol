// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IAccountingChainGateway} from "../../src/interfaces/IAccountingChainGateway.sol";
import {IBridgeAdapter} from "../../src/interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "../../src/interfaces/IChainGateway.sol";
import {ITransferHelper} from "../../src/interfaces/ITransferHelper.sol";

contract MockAccountingChainGateway is IAccountingChainGateway {
    address[] _assetsToPullFromTransferHelperInNextCall;
    uint256[] _amountsToPullFromTransferHelperInNextCall;
    address _transferHelper;

    function mockToConsumeAssetFromTransferHelperInNextCall(address asset, uint256 amount) external {
        _assetsToPullFromTransferHelperInNextCall.push(asset);
        _amountsToPullFromTransferHelperInNextCall.push(amount);
    }

    function mockTransferHelper(address transferHelper) external {
        _transferHelper = transferHelper;
    }

    function getDefaultBridgeAdapter(address asset, uint256 chainId) external view returns (address) {}

    function sendPushFundsToChainMessage(
        address, // asset
        uint256, // amount
        uint256, // targetChainId
        IChainGateway.BridgeParams memory // bridgeParams
    )
        external
        payable
    {
        _pullAssetsFromTransferHelper();
    }

    function addBridgeAdapter(address asset, uint256 chainId, address adapter) external {}

    function removeBridgeAdapter(address asset, uint256 chainId, address adapter) external {}

    function setDefaultBridgeAdapter(address asset, uint256 chainId, address adapter) external {}

    function receiveMessage(uint256 sourceChainId, IBridgeAdapter.BridgeAsset[] memory assets, bytes memory data)
        external {}

    function sendBridgeIouTokenMessageWithFeePayer(
        uint256 destinationChainId,
        address iouTokenRecipient,
        uint256 iouTokenAmountRay,
        IChainGateway.BridgeParams memory bridgeParams
    ) external payable {}

    function _pullAssetsFromTransferHelper() internal {
        if (_assetsToPullFromTransferHelperInNextCall.length > 0) {
            ITransferHelper(_transferHelper)
                .pull(_assetsToPullFromTransferHelperInNextCall, _amountsToPullFromTransferHelperInNextCall);
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IAccountingChainGateway} from "../../src/interfaces/IAccountingChainGateway.sol";
import {IBridgeAdapter} from "../../src/interfaces/IBridgeAdapter.sol";
import {ITransferHelper} from "../../src/interfaces/ITransferHelper.sol";

contract MockAccountingChainGateway is IAccountingChainGateway {
    address internal immutable TRANSFER_HELPER;

    constructor(address transferHelper) {
        TRANSFER_HELPER = transferHelper;
    }

    address[] _assetsToPullFromTransferHelperInNextCall;
    uint256[] _amountsToPullFromTransferHelperInNextCall;

    function mockToConsumeAssetFromTransferHelperInNextCall(address asset, uint256 amount) external {
        _assetsToPullFromTransferHelperInNextCall.push(asset);
        _amountsToPullFromTransferHelperInNextCall.push(amount);
    }

    function getDefaultBridgeAdapter(address asset, uint256 chainId) external view returns (address) {}

    function sendPushFundsToChainMessage(
        address, // asset
        uint256, // amount
        uint256, // targetChainId
        IBridgeAdapter.BridgeParams memory // bridgeParams
    )
        external
        payable
    {
        _pullAssetsFromTransferHelper();
    }

    function addBridgeAdapter(address asset, uint256 chainId, address adapter) external {}

    function removeBridgeAdapter(address asset, uint256 chainId, address adapter) external {}

    function setDefaultBridgeAdapter(address asset, uint256 chainId, address adapter) external {}

    /// @dev Called by Bridge Adapters which use the TransferHelper modifiers that assert no funds left in the
    /// TransferHelper.
    function receiveMessage(uint256 sourceChainId, IBridgeAdapter.BridgeAsset[] memory assets, bytes memory data)
        external
    {
        (sourceChainId, data);
        for (uint256 i = 0; i < assets.length; i++) {
            ITransferHelper(TRANSFER_HELPER).transfer(assets[i].asset, assets[i].amount, address(this));
        }
    }

    function sendBridgeIouTokenMessageWithFeePayer(
        uint256 destinationChainId,
        address iouTokenRecipient,
        uint256 iouTokenAmountRay,
        IBridgeAdapter.BridgeParams memory bridgeParams
    ) external payable {}

    function _pullAssetsFromTransferHelper() internal {
        if (_assetsToPullFromTransferHelperInNextCall.length > 0) {
            ITransferHelper(TRANSFER_HELPER)
                .pull(_assetsToPullFromTransferHelperInNextCall, _amountsToPullFromTransferHelperInNextCall);
        }
    }
}

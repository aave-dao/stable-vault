// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAccountingChainGateway} from "../interfaces/IAccountingChainGateway.sol";
import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "../interfaces/IChainGateway.sol";
import {IFundsHandler} from "../interfaces/IFundsHandler.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {BaseChainGateway} from "../common/BaseChainGateway.sol";

contract AccountingChainGateway is IAccountingChainGateway, BaseChainGateway {
    using SafeERC20 for IERC20;

    modifier onlyFundsHandler() {
        require(msg.sender == _fundsHandler, NotFundsHandler());
        _;
    }

    address internal _fundsHandler;

    constructor(address admin, address fundsHandler) BaseChainGateway(admin) {
        _fundsHandler = fundsHandler;
    }

    function sendPushFundsToChainMessage(address asset, uint256 amount, uint256 targetChainId)
        external
        onlyFundsHandler
    {
        address adapter = _bridgeAdapter[asset][targetChainId];
        require(adapter != address(0), UnsupportedAdapter());
        IERC20(asset).safeTransfer(adapter, amount);
        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: asset, amount: amount});
        IBridgeAdapter(adapter).publishMessageToChain(targetChainId, assets, "");
    }

    /// @dev Assume for Emergency withdrawal only - Earning chain will send whatever asset it prefers.
    /// @param amountRay The `amount` must be in RAY to be token agnostic.
    /// @param targetChainId The destination chainId.
    function sendPullFundsFromChainMessage(uint256 amountRay, uint256 targetChainId) external onlyFundsHandler {
        IBridgeAdapter(_bridgeAdapter[ASSET_FOR_DATA_ONLY_BRIDGE][targetChainId]).publishMessageToChain(
            targetChainId, new IBridgeAdapter.BridgeAsset[](0), abi.encode(amountRay)
        );
    }

    function _receiveFunds(uint256, /* sourceChainId */ IBridgeAdapter.BridgeAsset[] memory assets) internal override {
        require(assets.length == 1, ErrorsLib.InvalidBridgeAssetsLength());
        address asset = assets[0].asset;
        uint256 amount = assets[0].amount;
        IERC20(asset).safeTransferFrom(msg.sender, _fundsHandler, amount);
        IFundsHandler(_fundsHandler).fundsArrivedFromChainCallback(asset, amount);
    }

    function _receiveData(uint256 sourceChainId, bytes memory data) internal override {
        _onlyAdapter(ASSET_FOR_DATA_ONLY_BRIDGE, sourceChainId);
        // TODO: this assumes that the data is a balance snapshot and can be nothing else
        IChainGateway.BalanceSnapshot memory balanceSnapshot = abi.decode(data, (IChainGateway.BalanceSnapshot));
        IFundsHandler(_fundsHandler).updateChainBalanceCallback(
            sourceChainId, balanceSnapshot.balance, balanceSnapshot.timestamp
        );
    }
}

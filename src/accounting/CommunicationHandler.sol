// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICommunicationHandler} from "../interfaces/ICommunicationHandler.sol";
import {ICommunicationAdapter} from "../interfaces/ICommunicationAdapter.sol";
import {IBridgeCommunicationHandler} from "../interfaces/IBridgeCommunicationHandler.sol";
import {IFundsHandler} from "../interfaces/IFundsHandler.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {BridgeCommunicationHandler} from "../common/BridgeCommunicationHandler.sol";

contract CommunicationHandler is ICommunicationHandler, BridgeCommunicationHandler {
    using SafeERC20 for IERC20;

    modifier onlyFundsHandler() {
        require(msg.sender == _fundsHandler, NotFundsHandler());
        _;
    }

    address _fundsHandler;

    constructor(address admin, address fundsHandler) BridgeCommunicationHandler(admin) {
        _fundsHandler = fundsHandler;
    }

    function sendPushFundsToChainMessage(address asset, uint256 amount, uint256 targetChainId)
        external
        onlyFundsHandler
    {
        address adapter = _bridgeAdapter[asset][targetChainId];
        require(adapter != address(0), UnsupportedAdapter());
        IERC20(asset).safeTransfer(adapter, amount);
        ICommunicationAdapter(adapter).pushFundsToChain(targetChainId, asset, amount);
    }

    /// @dev Assume for Emergency withdrawal only - Earning chain will send whatever asset it prefers.
    /// @param amount The `amount` must be in RAY to be token agnostic.
    /// @param targetChainId The destination chainId.
    function sendPullFundsFromChainMessage(uint256 amount, uint256 targetChainId) external onlyFundsHandler {
        ICommunicationAdapter(_bridgeAdapter[ASSET_FOR_MESSAGE_ONLY_BRIDGE][targetChainId]).pullFundsFromChain(
            targetChainId, amount
        );
    }

    /// @param sourceChainId the ID of the chain where the balance snapshot was taken
    /// @param balance cumulative balance in RAY
    /// @param timestamp on source chain
    function receiveBalanceSnapshotMessage(uint256 sourceChainId, uint256 balance, uint256 timestamp)
        external
        override
        onlyAdapter(ASSET_FOR_MESSAGE_ONLY_BRIDGE, sourceChainId)
    {
        IFundsHandler(_fundsHandler).updateChainBalanceCallback(sourceChainId, balance, timestamp);
    }

    /// @inheritdoc IBridgeCommunicationHandler
    function receiveFunds(uint256 sourceChainId, address asset, uint256 amount)
        external
        override
        onlyAdapter(asset, sourceChainId)
    {
        IERC20(asset).safeTransferFrom(_bridgeAdapter[asset][sourceChainId], _fundsHandler, amount);
        IFundsHandler(_fundsHandler).fundsArrivedFromChainCallback(sourceChainId, asset, amount);
    }
}

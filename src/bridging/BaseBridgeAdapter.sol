// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "../interfaces/IChainGateway.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";

abstract contract BaseBridgeAdapter is Ownable, IBridgeAdapter {
    using SafeERC20 for IERC20;

    address internal _gateway;

    modifier onlyGateway() {
        require(msg.sender == _gateway, ErrorsLib.NotGateway());
        _;
    }

    constructor(address owner) Ownable(owner) {}

    function publishMessageToChain(
        uint256 destinationChainId,
        IBridgeAdapter.BridgeAsset[] memory assets,
        bytes memory data
    ) external virtual;

    function setGateway(address gateway) external onlyOwner {
        _gateway = gateway;
    }

    /// @notice Replays the funds receiving process for a given source chain and assets. Assets must be on this
    /// contract.
    /// @param sourceChainId The chain id of the chain which funds arrived from.
    /// @param assets The tokens to replay the receiving process for.
    function replayFundsReceiving(uint256 sourceChainId, IBridgeAdapter.BridgeAsset[] memory assets) external {
        _processReceivedFunds(sourceChainId, assets);
    }

    function _processReceivedFunds(uint256 sourceChainId, IBridgeAdapter.BridgeAsset[] memory assets) internal {
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i].asset;
            uint256 amount = assets[i].amount;
            IERC20(asset).forceApprove(_gateway, amount);
        }
        IChainGateway(_gateway).receiveMessage(sourceChainId, assets, "");
    }
}

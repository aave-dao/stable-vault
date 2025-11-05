// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "../interfaces/IChainGateway.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";

/// @title BaseBridgeAdapter
/// @notice Base contract for bridge adapters.
/// @dev Tokens inbound to this contract should be pulled into this contract with spend permission.
/// @dev Tokens outbound from this contract will be approved to be spent by predetermined spender. Outbound funds are
/// pulled from this contract.
abstract contract BaseBridgeAdapter is AccessManaged, IBridgeAdapter {
    using SafeERC20 for IERC20;

    address internal immutable GATEWAY;

    mapping(uint256 chainId => address destinationChainAdapter) internal _destinationChainAdapterOf;

    modifier onlyGateway() {
        require(msg.sender == GATEWAY, ErrorsLib.NotGateway());
        _;
    }

    constructor(address accessManager, address gateway) AccessManaged(accessManager) {
        GATEWAY = gateway;
    }

    function publishMessageToChainWithFeePayer(
        uint256 destinationChainId,
        IBridgeAdapter.BridgeAsset[] memory assets,
        bytes memory data,
        IChainGateway.BridgeAdapterParams memory bridgeAdapterParams
    ) external payable virtual;

    function setDestinationChainAdapter(uint256 chainId, address destinationChainAdapter) external override restricted {
        _destinationChainAdapterOf[chainId] = destinationChainAdapter;
    }

    /// @notice Replays the funds receiving process for a given source chain and assets. Assets must be on this
    /// contract.
    /// @param sourceChainId The chain id of the chain which funds arrived from.
    /// @param assets The tokens to replay the receiving process for.
    function replayFundsReceiving(uint256 sourceChainId, IBridgeAdapter.BridgeAsset[] memory assets) external override {
        _processReceivedFunds(sourceChainId, assets);
    }

    function _processReceivedFunds(uint256 sourceChainId, IBridgeAdapter.BridgeAsset[] memory assets) internal {
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i].asset;
            uint256 amount = assets[i].amount;
            IERC20(asset).forceApprove(GATEWAY, amount);
        }
        IChainGateway(GATEWAY).receiveMessage(sourceChainId, assets, "");
    }
}

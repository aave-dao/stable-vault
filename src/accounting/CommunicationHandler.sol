// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {ICommunicationHandler} from "../interfaces/ICommunicationHandler.sol";
import {ICommunicationAdapter} from "../interfaces/ICommunicationAdapter.sol";
import {IAllocator} from "../interfaces/IAllocator.sol";
import {IFundsHandler} from "../interfaces/IFundsHandler.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";

contract CommunicationHandler is ICommunicationHandler {
    using SafeERC20 for IERC20;

    address constant ASSET_FOR_MESSAGE_ONLY_BRIDGE = address(0);

    modifier onlyAdapter(address asset, uint256 fromChainId) {
        require(_bridgeAdapter[asset][fromChainId] == msg.sender, UnsupportedAdapter());
        _;
    }

    modifier onlyFundsHandler() {
        require(msg.sender == _fundsHandler, NotFundsHandler());
        _;
    }

    modifier onlyAdmin() {
        require(msg.sender == _admin, ErrorsLib.NotAdmin());
        _;
    }

    address _fundsHandler;
    address _admin;

    /// @dev Assumes a single asset is bridged per bridge action through an adapter.
    /// @dev asset == address(0) for message-only bridging.
    /// @dev Assumes token bridges also support Arbitrary Message Bridging.
    mapping(address asset => mapping(uint256 chainId => address adapter)) _bridgeAdapter;

    constructor(address admin, address fundsHandler) {
        _admin = admin;
        _fundsHandler = fundsHandler;
    }

    function sendPushFundsToChainMessage(address asset, uint256 amount, uint256 targetChainId)
        external
        onlyFundsHandler
    {
        address adapter = _bridgeAdapter[asset][targetChainId];
        require(adapter != address(0), UnsupportedAdapter());
        if (targetChainId == block.chainid) {
            // TODO: Is Adapter an Allocator directly or it's just a direct pass-thru?
            IERC20(asset).safeTransfer(adapter, amount);
            IAllocator(adapter).deposit(asset, amount);
            return;
        }
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

    /// @param fromChainId the ID of the chain where  th
    /// @param balance cumulative balance in RAY
    /// @param timestamp on source chain
    function receiveBalanceSnapshotMessage(uint256 fromChainId, uint256 balance, uint256 timestamp)
        external
        override
        onlyAdapter(ASSET_FOR_MESSAGE_ONLY_BRIDGE, fromChainId)
    {
        IFundsHandler(_fundsHandler).updateChainBalanceCallback(fromChainId, balance, timestamp);
    }

    /// @param fromChainId the ID of the chain where  th
    /// @param asset token address
    /// @param amount amount in asset decimal places
    function receiveFunds(uint256 fromChainId, address asset, uint256 amount)
        external
        override
        onlyAdapter(asset, fromChainId)
    {
        IERC20(asset).safeTransferFrom(_bridgeAdapter[asset][fromChainId], _fundsHandler, amount);
        IFundsHandler(_fundsHandler).fundsArrivedFromChainCallback(fromChainId, asset, amount);
    }

    /// @param asset asset to bridge using adapter
    /// @param chainId destination chainId
    /// @param adapter address of adapter implementing ICommunicationAdapter
    function setBridgeAdapter(address asset, uint256 chainId, address adapter) external onlyAdmin {
        address currentAdapter = _bridgeAdapter[asset][chainId];
        if (currentAdapter != adapter) {
            _bridgeAdapter[asset][chainId] = adapter;
        }
    }

    function getTokenBridgeAdapter(address asset, uint256 chainId) external view returns (address) {
        return _bridgeAdapter[asset][chainId];
    }
}

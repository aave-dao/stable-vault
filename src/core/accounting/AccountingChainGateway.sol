// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseChainGateway} from "src/core/BaseChainGateway.sol";
import {IAccountingChainGateway} from "src/interfaces/IAccountingChainGateway.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {IChainBalanceOracle} from "src/interfaces/IChainBalanceOracle.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {IFundsHandler} from "src/interfaces/IFundsHandler.sol";
import {IIouTokenManager} from "src/interfaces/IIouTokenManager.sol";

/// @title AccountingChainGateway
/// @author Aave Labs
/// @notice Facilitates cross chain messaging one or more Earning Chains.
contract AccountingChainGateway is BaseChainGateway, IAccountingChainGateway {
    using SafeERC20 for IERC20;

    address internal immutable FUNDS_HANDLER;
    address internal immutable CHAIN_BALANCE_ORACLE;

    modifier onlyFundsHandler() {
        require(msg.sender == FUNDS_HANDLER, OnlyFundsHandler());
        _;
    }

    /// @dev Constructor.
    /// @param fundsHandler The address of the FundsHandler contract.
    /// @param iouTokenManager The address of the IOU token manager contract.
    constructor(address fundsHandler, address iouTokenManager, address chainBalanceOracle)
        BaseChainGateway(iouTokenManager)
    {
        _disableInitializers();
        FUNDS_HANDLER = fundsHandler;
        CHAIN_BALANCE_ORACLE = chainBalanceOracle;
    }

    /// @dev Initializer.
    /// @param accessManager The address of the IAccessManager contract used for handling access control.
    function initialize(address accessManager) external virtual initializer {
        __AccountingChainGateway_init(accessManager);
    }

    function __AccountingChainGateway_init(address accessManager) internal virtual onlyInitializing {
        __BaseChainGateway_init(accessManager);
    }

    function getFundsHandler() external view returns (address) {
        return FUNDS_HANDLER;
    }

    /// @inheritdoc IAccountingChainGateway
    function sendPushFundsToChainMessage(
        address asset,
        uint256 amount,
        uint256 targetChainId,
        IBridgeAdapter.BridgeParams memory bridgeParams
    ) external payable override onlyFundsHandler {
        address adapter = $BaseChainGateway().defaultBridgeAdapter[asset][targetChainId];
        require(adapter != address(0), AdapterNotFound());
        _sendCrossChainMessage(targetChainId, adapter, asset, amount, "", bridgeParams);
    }

    function _receiveFunds(address asset, uint256 amount) internal override {
        IFundsHandler(FUNDS_HANDLER).fundsArrivedFromChainCallback(asset, amount);
    }

    function _receiveData(uint256 sourceChainId, bytes memory data) internal override {
        IChainGateway.CrossChainMessage memory crossChainMessage = abi.decode(data, (IChainGateway.CrossChainMessage));
        if (crossChainMessage.messageType == IChainGateway.MessageType.BRIDGE_IOU_TOKEN) {
            _bridgeIouTokenFromEarningChain(crossChainMessage.data);
        } else if (crossChainMessage.messageType == IChainGateway.MessageType.BURN_IOU_TOKEN) {
            _burnIouToken(sourceChainId, crossChainMessage.data);
        } else if (crossChainMessage.messageType == IChainGateway.MessageType.RETURN_FUNDS) {
            _processReturnFundsData(sourceChainId, crossChainMessage.data);
        } else {
            revert IChainGateway.InvalidMessageType();
        }
    }

    function _bridgeIouTokenFromEarningChain(bytes memory data) internal {
        IChainGateway.IouTokenBridgeMessage memory iouTokenBridgeMessage =
            abi.decode(data, (IChainGateway.IouTokenBridgeMessage));
        IIouTokenManager(IOU_TOKEN_MANAGER).releaseTokens(iouTokenBridgeMessage.recipient, iouTokenBridgeMessage.amount);
    }

    function _burnIouToken(uint256 sourceChainId, bytes memory data) internal {
        IChainGateway.BurnIouTokenMessage memory burnIouTokenMessage =
            abi.decode(data, (IChainGateway.BurnIouTokenMessage));
        _validateInboundMessageBlockNumber(sourceChainId, burnIouTokenMessage.blockNumber);
        IIouTokenManager(IOU_TOKEN_MANAGER).burnLockedTokens(burnIouTokenMessage.iouTokenAmountBurnedRay);
    }

    function _processReturnFundsData(uint256 sourceChainId, bytes memory data) internal view {
        IChainGateway.ReturnFundsMessage memory returnFundsMessage =
            abi.decode(data, (IChainGateway.ReturnFundsMessage));
        _validateInboundMessageBlockNumber(sourceChainId, returnFundsMessage.blockNumber);
    }

    /// @dev Validates that the block number of the inbound message is not newer than the latest update from the
    /// Chain Balance Oracle.
    /// @param earningChainId The ID of the Earning Chain that sent the message.
    /// @param earningChainMessageBlockNumber The block number of when the Earning Chain message was published.
    function _validateInboundMessageBlockNumber(uint256 earningChainId, uint256 earningChainMessageBlockNumber)
        internal
        view
    {
        IChainBalanceOracle.ChainBalance memory chainBalance =
            IChainBalanceOracle(CHAIN_BALANCE_ORACLE).getChainBalance(earningChainId);
        if (earningChainMessageBlockNumber > chainBalance.sourceChainBlockNumber) {
            // The funds were sent from the Earning Chain after the latest balance snapshot was taken.
            // The Chain Balance Oracle does not reflect a snapshot which captures the outflow of assets from the
            // Earning Chain.
            revert StaleChainBalanceTimestamp();
        }
    }
}

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
import {Errors} from "src/types/Errors.sol";

/// @title AccountingChainGateway
/// @author Aave Labs
/// @notice Facilitates cross chain messaging with one or more Earning Chains.
/// @custom:upgradeable
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
    /// @param chainBalanceOracle The address of the ChainBalanceOracle contract.
    constructor(address fundsHandler, address iouTokenManager, address chainBalanceOracle)
        BaseChainGateway(iouTokenManager)
    {
        require(fundsHandler != address(0), Errors.ZeroAddress());
        require(chainBalanceOracle != address(0), Errors.ZeroAddress());
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
        address adapter,
        IBridgeAdapter.BridgeParams memory bridgeParams
    ) external override onlyFundsHandler {
        _validateOutboundAdapter(asset, targetChainId, adapter);
        // Block pushing funds to a chain whose balance oracle is stale, as the target chain's state is unknown and
        // may be unhealthy (e.g. chain or oracle infrastructure is down). Sending funds there risks locking assets or
        // DoSing withdrawals due to a lack of aggregated liquidity until the oracle staleness is resolved.
        require(!IChainBalanceOracle(CHAIN_BALANCE_ORACLE).getChainBalance(targetChainId).isStale, StaleChainBalance());
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
    /// Chain Balance Oracle. In other words, accept the message if the snapshot is based on the same block or a more
    /// recent block than the one which funds were pulled from the Earning Chain Allocator and bridged to the Accounting
    /// Chain. Earning Chain blocks may be nearly as long as the period between reads of
    /// EarningChainStateProvider::getState(), so it is very likely for reads to be from the same block which funds are
    /// bridged to the Accounting Chain.
    /// @param earningChainId The ID of the Earning Chain that sent the message.
    /// @param earningChainMessageBlockNumber The block number of when the Earning Chain message was published.
    function _validateInboundMessageBlockNumber(uint256 earningChainId, uint256 earningChainMessageBlockNumber)
        internal
        view
    {
        IChainBalanceOracle.ChainBalance memory chainBalance =
            IChainBalanceOracle(CHAIN_BALANCE_ORACLE).getChainBalance(earningChainId);
        if (earningChainMessageBlockNumber > chainBalance.sourceChainBlockNumber) {
            // The funds were sent from the Earning Chain after the latest published balance snapshot was taken.
            // The Chain Balance Oracle does not reflect a snapshot which captures the outflow of assets from the
            // Earning Chain, therefore the value of funds bridged from the Earning Chain would be double counted
            // (counted once from the local Allocator if the fund reception is successful, and once through the stale
            // Earning Chain balance snapshot).
            revert StaleChainBalance();
        }
    }
}

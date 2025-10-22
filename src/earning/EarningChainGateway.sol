// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseChainGateway} from "../common/BaseChainGateway.sol";
import {IAllocator} from "../interfaces/IAllocator.sol";
import {IAllocator} from "../interfaces/IAllocator.sol";
import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "../interfaces/IChainGateway.sol";
import {IEarningChainGateway} from "../interfaces/IEarningChainGateway.sol";
import {IMintableBurnableIERC20} from "../interfaces/IMintableBurnableIERC20.sol";
import {AssetLib} from "../libraries/AssetLib.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {EventLib} from "../libraries/EventLib.sol";

/// @title EarningChainGateway
/// @notice Facilitates cross chain messaging with exactly one Accounting Chain.
contract EarningChainGateway is IEarningChainGateway, BaseChainGateway {
    using SafeERC20 for IERC20;
    using AssetLib for uint256;

    modifier onlyManager() {
        require(msg.sender == _manager, ErrorsLib.NotManager());
        _;
    }

    uint256 internal immutable ACCOUNTING_CHAIN_ID;
    address internal _allocator;
    address internal _manager;

    constructor(address admin, uint256 accountingChainId) BaseChainGateway(admin) {
        ACCOUNTING_CHAIN_ID = accountingChainId;
    }

    function setManager(address manager) external onlyAdmin {
        require(manager != address(0), ErrorsLib.ZeroAddress());
        _manager = manager;
        emit EventLib.ManagerSet(manager);
    }

    function setAllocator(address allocator) external onlyAdmin {
        require(allocator != address(0), ErrorsLib.ZeroAddress());
        _allocator = allocator;
        emit EventLib.AllocatorSet(allocator);
    }

    function _receiveFunds(IBridgeAdapter.BridgeAsset[] memory assets) internal override {
        for (uint256 i = 0; i < assets.length; i++) {
            address asset = assets[i].asset;
            uint256 amount = assets[i].amount;
            IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
            IERC20(asset).forceApprove(_allocator, amount);
            IAllocator(_allocator).deposit(asset, amount);
        }
        // TODO: should this callback be gated behind a flag sent from the Accounting Chain?
        _sendBalanceUpdate();
    }

    function _receiveData(uint256 sourceChainId, bytes memory data) internal view override {
        _onlyAdapter(ASSET_FOR_DATA_ONLY_BRIDGE, sourceChainId);
        IChainGateway.CrossChainMessage memory crossChainMessage = abi.decode(data, (IChainGateway.CrossChainMessage));
        if (crossChainMessage.messageType == IChainGateway.MessageType.BRIDGE_IOUTOKEN) {
            _bridgeIouTokenFromAccountingChain(sourceChainId, crossChainMessage.data);
        } else {
            revert IChainGateway.InvalidMessageType();
        }
    }

    // TODO: We should open this function to public (in case manager goes awol)
    function sendBalanceUpdate() external onlyManager {
        _sendBalanceUpdate();
    }

    function sendBridgeIouTokenMessage(
        address user,
        address recipient,
        address bridgeFeePayer,
        address bridgeFeeToken,
        uint256 targetChainId,
        uint256 amount
    ) external {
        require(user == msg.sender, "IouTokenBridge: not authorized");
        // TODO: Add this check everywhere where there is a targetChainId
        require(targetChainId == block.chainid, "IouTokenBridge: invalid target chain");
        // Lock tokens in this contract
        IERC20(IOU_TOKEN).transferFrom(user, address(this), amount);
        IBridgeAdapter(_bridgeAdapter[ASSET_FOR_DATA_ONLY_BRIDGE][targetChainId]).publishMessageToChainWithFeePayer(
            bridgeFeePayer,
            bridgeFeeToken,
            targetChainId,
            abi.encode(
                IChainGateway.CrossChainMessage({
                    messageType: MessageType.BRIDGE_IOUTOKEN,
                    data: abi.encode(IouTokenBridgeMessage({recipient: recipient, amount: amount}))
                })
            )
        );
    }

    // TODO: Add bridgeFeePayer, etc
    function exitViaIouTokens(address user, address recipient, address token, uint256 amountIouRay)
        external
        returns (uint256)
    {
        require(user == msg.sender, "User != msg.sender");
        IMintableBurnableIERC20(IOU_TOKEN).burn(user, amountIouRay);
        IAllocator(_allocator).withdraw(token, amountIouRay);
        IERC20(token).safeTransfer(recipient, amountIouRay);
        _sendIouBurnMessage(amountIouRay);
        return amountIouRay;
    }

    // TODO: This needs to have a better name?
    function exit(address asset, uint256 amount) external onlyManager {
        IAllocator(_allocator).withdraw(asset, amount);
        _returnFunds(asset, amount);
    }

    function _bridgeIouTokenFromAccountingChain(uint256 sourceChainId, bytes memory data) internal {
        IChainGateway.IouTokenBridgeMessage memory iouTokenBridgeMessage =
            abi.decode(data, (IChainGateway.IouTokenBridgeMessage));
        IMintableBurnableIERC20(IOU_TOKEN).mint(iouTokenBridgeMessage.recipient, iouTokenBridgeMessage.amount);
    }

    function _returnFunds(address asset, uint256 amount) internal {
        address adapter = _bridgeAdapter[asset][ACCOUNTING_CHAIN_ID];
        IERC20(asset).forceApprove(adapter, amount);
        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: asset, amount: amount});
        IBridgeAdapter(adapter).publishMessageToChain(ACCOUNTING_CHAIN_ID, assets, _getBalanceSnapshotData());
    }

    function _sendBalanceUpdate() internal {
        IBridgeAdapter(_bridgeAdapter[address(0)][ACCOUNTING_CHAIN_ID]).publishMessageToChain(
            ACCOUNTING_CHAIN_ID, new IBridgeAdapter.BridgeAsset[](0), _getBalanceSnapshotData()
        );
    }

    function _sendIouBurnMessage(uint256 amountIouRay) internal {
        IBridgeAdapter(_bridgeAdapter[address(0)][ACCOUNTING_CHAIN_ID]).publishMessageToChain(
            ACCOUNTING_CHAIN_ID,
            new IBridgeAdapter.BridgeAsset[](0),
            abi.encode(IChainGateway.BurnIouTokenMessage({amount: amountIouRay}))
        );
    }

    function _getBalanceSnapshotData() internal view returns (bytes memory) {
        IAllocator.AllocatorBalance[] memory allocatorBalances = IAllocator(_allocator).getAssetBalances();
        uint256 totalAssetsInRay;
        for (uint256 i = 0; i < allocatorBalances.length; i++) {
            totalAssetsInRay += allocatorBalances[i].amount.assetDecimalsToRay(allocatorBalances[i].asset);
        }
        return abi.encode(IChainGateway.BalanceSnapshot(totalAssetsInRay, block.timestamp));
    }
}

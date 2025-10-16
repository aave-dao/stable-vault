// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BaseChainGateway} from "../common/BaseChainGateway.sol";
import {IAllocator} from "../interfaces/IAllocator.sol";
import {IBridgeAdapter} from "../interfaces/IBridgeAdapter.sol";
import {IChainGateway} from "../interfaces/IChainGateway.sol";
import {IEarningChainGateway} from "../interfaces/IEarningChainGateway.sol";
import {IManagedAllocator} from "../interfaces/IManagedAllocator.sol";
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
        uint256 amountRay = abi.decode(data, (uint256));
        _emergencyExit(amountRay);
    }

    function sendBalanceUpdate() external onlyManager {
        _sendBalanceUpdate();
    }

    // TODO: This needs to have a better name?
    function exit(address asset, uint256 amount) external onlyManager {
        IAllocator(_allocator).withdraw(asset, amount);
        _returnFunds(asset, amount);
    }

    function _emergencyExit(uint256 amountRay) internal pure {
        (amountRay);
        revert("EarningChainGateway.emergencyExit:NOT_IMPLEMENTED");
        // TODO: re Emergency Withdrawal how to decide which token to pull from Allocator?
        // TODO: do we need to ccipSend multiple times to bridge multiple tokens?
        // TODO: Keep in mind not every asset in Earning chain will be bridgeable to Accounting chain
        // TODO: if someone emergencyWithdraws then have them wait a cooldown period since pull flow can fail if
        // insufficient bridgeable assets are on Earning chain (assume no swap can be performed) TODO: Implement; decide
        // which asset(s) to withdraw
        // TODO: check that the assets to withdraw from Allocator are actually bridgedable
    }

    function _returnFunds(address asset, uint256 amount) internal {
        address adapter = _bridgeAdapter[asset][ACCOUNTING_CHAIN_ID];
        IERC20(asset).forceApprove(adapter, amount);
        IBridgeAdapter.BridgeAsset[] memory assets = new IBridgeAdapter.BridgeAsset[](1);
        assets[0] = IBridgeAdapter.BridgeAsset({asset: asset, amount: amount});
        IBridgeAdapter(adapter).publishMessageToChain(ACCOUNTING_CHAIN_ID, assets, _getBalanceSnapshotData());
    }

    function _sendBalanceUpdate() internal {
        IBridgeAdapter(_bridgeAdapter[address(0)][ACCOUNTING_CHAIN_ID])
            .publishMessageToChain(ACCOUNTING_CHAIN_ID, new IBridgeAdapter.BridgeAsset[](0), _getBalanceSnapshotData());
    }

    function _getBalanceSnapshotData() internal view returns (bytes memory) {
        IManagedAllocator.AllocatorBalance[] memory allocatorBalances = IAllocator(_allocator).getAssetBalances();
        uint256 totalAssetsInRay;
        for (uint256 i = 0; i < allocatorBalances.length; i++) {
            totalAssetsInRay += allocatorBalances[i].amount.assetDecimalsToRay(allocatorBalances[i].asset);
        }
        return abi.encode(IChainGateway.BalanceSnapshot(totalAssetsInRay, block.timestamp));
    }
}

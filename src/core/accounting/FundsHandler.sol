// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";

import {IAccountingChainGateway} from "src/interfaces/IAccountingChainGateway.sol";
import {IAllocator} from "src/interfaces/IAllocator.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {IFundsHandler} from "src/interfaces/IFundsHandler.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {RescuableNative} from "src/misc/RescuableNative.sol";
import {RescuableToken} from "src/misc/RescuableToken.sol";
import {TransferHelperClient} from "src/misc/TransferHelperClient.sol";
import {Errors} from "src/types/Errors.sol";

/// @title FundsHandler
/// @author Aave Labs
/// @notice Handles push/pull of funds across the system.
contract FundsHandler is
    AccessManagedUpgradeable,
    RescuableNative,
    RescuableToken,
    TransferHelperClient,
    IFundsHandler
{
    using AssetLib for uint256;

    /// @notice The representation of an Earnings Chain's balance snapshot.
    /// @param chainId The chain id of the Earnings Chain.
    /// @param amountRay The cumulative value of assets in RAY.
    /// @param nonce The nonce of the balance snapshot (monotonically increasing).
    struct ChainBalanceSnapshot {
        uint256 chainId;
        // Assumes all balances have common denomination.
        uint256 amountRay;
        uint256 nonce;
    }

    address internal immutable VAULT;
    address internal immutable GATEWAY;
    address internal immutable ALLOCATOR;

    /// @custom:storage-location erc7201:aave.storage.FundsHandler
    struct FundsHandlerStorage {
        ChainBalanceSnapshot[] chainBalances;
    }

    // keccak256(abi.encode(uint256(keccak256("aave.storage.FundsHandler")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT_FUNDS_HANDLER =
        0xffa5bdc69644e89163c8759837db1aeb0b569037bb5259c74309b23147440c00;

    function $storage() private pure returns (FundsHandlerStorage storage _storage) {
        assembly {
            _storage.slot := STORAGE_SLOT_FUNDS_HANDLER
        }
    }

    modifier onlyBasedBoostedVault() {
        require(msg.sender == VAULT, OnlyBasedBoostedVault());
        _;
    }

    modifier onlyGateway() {
        require(msg.sender == GATEWAY, Errors.OnlyGateway());
        _;
    }

    /// @dev Constructor.
    /// @param basedBoostedVault The address of the BasedBoostedVault contract, which triggers deposits and withdrawals.
    /// @param gateway The address of the Gateway contract to use for cross-chain communication.
    /// @param allocator The address of the Allocator contract to use for immediate liquidity management.
    /// @param transferHelper The address of the TransferHelper contract to use for minimizing the number of transfers.
    constructor(address basedBoostedVault, address gateway, address allocator, address transferHelper)
        TransferHelperClient(transferHelper)
    {
        _disableInitializers();
        VAULT = basedBoostedVault;
        GATEWAY = gateway;
        ALLOCATOR = allocator;
    }

    /// @dev Initializer.
    /// @param accessManager The address of the IAccessManager contract used for handling access control.
    function initialize(address accessManager) external virtual initializer {
        __FundsHandler_init(accessManager);
    }

    function __FundsHandler_init(address accessManager) internal virtual onlyInitializing {
        __AccessManaged_init(accessManager);
    }

    /// @inheritdoc IFundsHandler
    function getAggregatedBalance() external view override returns (uint256) {
        IAllocator.AllocatorBalance[] memory allocatorAssets = IAllocator(ALLOCATOR).getTrustedAssetBalances();

        uint256 totalBalanceRay;

        for (uint16 i = 0; i < allocatorAssets.length; i++) {
            totalBalanceRay += allocatorAssets[i].amount.assetDecimalsToRay(allocatorAssets[i].asset);
        }
        for (uint16 i = 0; i < $storage().chainBalances.length; i++) {
            totalBalanceRay += $storage().chainBalances[i].amountRay;
        }
        return totalBalanceRay;
    }

    /// @inheritdoc IFundsHandler
    function getAssetBalances() external view override returns (AssetBalance[] memory) {
        IAllocator.AllocatorBalance[] memory allocatorAssets = IAllocator(ALLOCATOR).getTrustedAssetBalances();
        AssetBalance[] memory balances = new AssetBalance[](allocatorAssets.length + $storage().chainBalances.length);
        for (uint16 i = 0; i < allocatorAssets.length; i++) {
            balances[i] = AssetBalance({
                chainId: block.chainid,
                asset: allocatorAssets[i].asset,
                amountRay: allocatorAssets[i].amount.assetDecimalsToRay(allocatorAssets[i].asset)
            });
        }
        for (uint16 i = 0; i < $storage().chainBalances.length; i++) {
            balances[allocatorAssets.length + i] = AssetBalance({
                chainId: $storage().chainBalances[i].chainId,
                asset: address(0),
                amountRay: $storage().chainBalances[i].amountRay
            });
        }
        return balances;
    }

    /// @inheritdoc IFundsHandler
    function processDeposit(address asset, uint256 amount) external override onlyBasedBoostedVault {
        _pushFundsToImmediateLiquidity(asset, amount);
    }

    /// @inheritdoc IFundsHandler
    function processWithdrawal(address asset, uint256 amount) external override onlyBasedBoostedVault {
        _pullFundsFromImmediateLiquidity(asset, amount);
    }

    //////////////////////////////////////////// MANAGER FUNCTIONS /////////////////////////////////////////////////////

    /// @inheritdoc IFundsHandler
    function pushFundsToChain(
        address asset,
        uint256 amount,
        uint256 chainId,
        IBridgeAdapter.BridgeParams memory bridgeParams
    )
        external
        payable
        override
        restricted
        assertingTransferHelperBalanceFor(bridgeParams.feeToken)
        assertingTransferHelperBalanceFor(asset)
    {
        require(amount > 0, Errors.ZeroAmount());
        require(chainId != block.chainid, Errors.InvalidDestinationChainId());

        // Transfer the bridge fee to the TransferHelper.
        _transferBridgeFeeToTransferHelper(bridgeParams);

        // Pull funds from liquidity into the TransferHelper.
        _pullFundsFromImmediateLiquidity(asset, amount);

        IAccountingChainGateway(GATEWAY).sendPushFundsToChainMessage(asset, amount, chainId, bridgeParams);
    }

    // Gateway Functions

    /// @inheritdoc IFundsHandler
    function updateChainBalanceCallback(uint256 chainId, uint256 snapshotBalanceRay, uint256 chainBalanceSnapshotNonce)
        external
        override
        onlyGateway
    {
        _updateChainBalance(chainId, snapshotBalanceRay, chainBalanceSnapshotNonce);
    }

    /// @inheritdoc IFundsHandler
    function fundsArrivedFromChainCallback(address asset, uint256 amount) external override onlyGateway {
        _pushFundsToImmediateLiquidity(asset, amount);
    }

    ////////////////////////////////////////////////// INTERNAL ////////////////////////////////////////////////////////

    function _updateChainBalance(uint256 chainId, uint256 snapshotBalanceRay, uint256 chainBalanceSnapshotNonce)
        internal
    {
        bool chainExists;
        for (uint16 i = 0; i < $storage().chainBalances.length; i++) {
            if ($storage().chainBalances[i].chainId == chainId) {
                chainExists = true;
                // Nonces should always be strictly increasing.
                // Use < to avoid replayable nonces.
                if ($storage().chainBalances[i].nonce < chainBalanceSnapshotNonce) {
                    $storage().chainBalances[i].nonce = chainBalanceSnapshotNonce;
                    $storage().chainBalances[i].amountRay = snapshotBalanceRay;
                }
            }
        }
        if (!chainExists) {
            $storage().chainBalances
                .push(
                    ChainBalanceSnapshot({
                        chainId: chainId, amountRay: snapshotBalanceRay, nonce: chainBalanceSnapshotNonce
                    })
                );
        }
        emit ChainBalanceSnapshotReceived(chainId, snapshotBalanceRay, chainBalanceSnapshotNonce);
    }

    function _pushFundsToImmediateLiquidity(address asset, uint256 amount) internal {
        IAllocator(ALLOCATOR).deposit(asset, amount);
    }

    function _pullFundsFromImmediateLiquidity(address asset, uint256 amount) internal {
        IAllocator(ALLOCATOR).withdraw(asset, amount);
    }

    function _beforeRescueTokens(
        address, // token
        uint256 // amount
    )
        internal
        virtual
        override
    {
        // Equivalent to adding the `restricted` modifier.
        _checkCanCall(_msgSender(), _msgData());
    }

    function _beforeRescueNative(uint256) internal virtual override {
        // Equivalent to adding the `restricted` modifier.
        _checkCanCall(_msgSender(), _msgData());
    }
}

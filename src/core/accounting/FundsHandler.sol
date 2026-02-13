// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {EnumerableSet} from "lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";

import {LocalBalanceAggregator} from "src/core/LocalBalanceAggregator.sol";
import {IAccountingChainGateway} from "src/interfaces/IAccountingChainGateway.sol";
import {IAllocator} from "src/interfaces/IAllocator.sol";
import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {IChainBalanceOracle} from "src/interfaces/IChainBalanceOracle.sol";
import {IFundsHandler} from "src/interfaces/IFundsHandler.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {MathLib} from "src/libraries/MathLib.sol";
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
    LocalBalanceAggregator,
    TransferHelperClient,
    IFundsHandler
{
    using AssetLib for uint256;
    using MathLib for uint256;
    using EnumerableSet for EnumerableSet.UintSet;

    address internal immutable VAULT;
    address internal immutable GATEWAY;
    address internal immutable CHAIN_BALANCE_ORACLE;

    /// @custom:storage-location erc7201:aave.storage.FundsHandler
    struct FundsHandlerStorage {
        EnumerableSet.UintSet earningChainIds;
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
    /// @param priceOracle The address of the PriceOracle contract to use for pricing assets.
    /// @param transferHelper The address of the TransferHelper contract to use for minimizing the number of transfers.
    /// @param chainBalanceOracle The address of the ChainBalanceOracle contract to use for cross-chain balance queries.
    constructor(
        address basedBoostedVault,
        address gateway,
        address allocator,
        address priceOracle,
        address transferHelper,
        address chainBalanceOracle
    ) TransferHelperClient(transferHelper) LocalBalanceAggregator(allocator, priceOracle) {
        _disableInitializers();
        VAULT = basedBoostedVault;
        GATEWAY = gateway;
        CHAIN_BALANCE_ORACLE = chainBalanceOracle;
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
        uint256 totalBalanceRay = _getLocalAggregatedBalance();
        for (uint256 i = 0; i < $storage().earningChainIds.length(); i++) {
            totalBalanceRay += _getAdjustedEarningChainBalanceRay($storage().earningChainIds.at(i));
        }
        return totalBalanceRay;
    }

    /// @inheritdoc IFundsHandler
    function getAssetBalances() external view override returns (AssetBalance[] memory) {
        IAllocator.AllocatorBalance[] memory allocatorAssets = IAllocator(ALLOCATOR).getTrustedAssetBalances();
        AssetBalance[] memory balances =
            new AssetBalance[](allocatorAssets.length + $storage().earningChainIds.length());
        for (uint256 i = 0; i < allocatorAssets.length; i++) {
            balances[i] = AssetBalance({
                chainId: block.chainid,
                asset: allocatorAssets[i].asset,
                amountRay: allocatorAssets[i].amount.assetDecimalsToRay(allocatorAssets[i].asset)
            });
        }
        for (uint256 i = 0; i < $storage().earningChainIds.length(); i++) {
            uint256 chainId = $storage().earningChainIds.at(i);
            balances[allocatorAssets.length + i] = AssetBalance({
                chainId: chainId, asset: address(0), amountRay: _getAdjustedEarningChainBalanceRay(chainId)
            });
        }
        return balances;
    }

    /// @inheritdoc IFundsHandler
    function processDeposit(address asset, uint256 amount) external override onlyBasedBoostedVault returns (uint256) {
        return IAllocator(ALLOCATOR).deposit(asset, amount);
    }

    /// @inheritdoc IFundsHandler
    function processWithdrawal(address asset, uint256 amount) external override onlyBasedBoostedVault {
        _pullFundsFromImmediateLiquidity(asset, amount);
    }

    ///////////////////////////////////////////// ADMIN FUNCTIONS //////////////////////////////////////////////////////

    /// @inheritdoc IFundsHandler
    function addEarningChain(uint256 chainId) external override restricted {
        require(chainId != block.chainid, Errors.InvalidDestinationChainId());
        require(!$storage().earningChainIds.contains(chainId), ChainIdAlreadyAdded());
        $storage().earningChainIds.add(chainId);
        emit EarningChainAdded(chainId);
    }

    /// @inheritdoc IFundsHandler
    function removeEarningChain(uint256 chainId) external override restricted {
        require($storage().earningChainIds.contains(chainId), ChainIdNotAdded());
        $storage().earningChainIds.remove(chainId);
        emit EarningChainRemoved(chainId);
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
        require($storage().earningChainIds.contains(chainId), Errors.InvalidDestinationChainId());

        // Transfer the bridge fee to the TransferHelper.
        _transferBridgeFeeToTransferHelper(bridgeParams);

        // Pull funds from liquidity into the TransferHelper.
        _pullFundsFromImmediateLiquidity(asset, amount);

        IAccountingChainGateway(GATEWAY).sendPushFundsToChainMessage(asset, amount, chainId, bridgeParams);
    }

    // Gateway Functions

    /// @inheritdoc IFundsHandler
    function fundsArrivedFromChainCallback(address asset, uint256 amount) external override onlyGateway {
        IAllocator(ALLOCATOR).depositAllowIdle(asset, amount);
    }

    ////////////////////////////////////////////////// INTERNAL ////////////////////////////////////////////////////////

    function _pullFundsFromImmediateLiquidity(address asset, uint256 amount) internal {
        IAllocator(ALLOCATOR).withdraw(asset, amount);
    }

    /// @dev Grossly under-estimates the balance if the chain balance is stale.
    function _getAdjustedEarningChainBalanceRay(uint256 chainId) internal view returns (uint256) {
        IChainBalanceOracle.ChainBalance memory chainBalance =
            IChainBalanceOracle(CHAIN_BALANCE_ORACLE).getChainBalance(chainId);
        return chainBalance.isStale ? 0 : chainBalance.balanceRay;
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

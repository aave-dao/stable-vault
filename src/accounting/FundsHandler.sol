// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {RescuableAssets} from "../common/RescuableAssets.sol";
import {IAccountingChainGateway} from "../interfaces/IAccountingChainGateway.sol";
import {IAllocator} from "../interfaces/IAllocator.sol";
import {IChainGateway} from "../interfaces/IChainGateway.sol";
import {IFundsHandler} from "../interfaces/IFundsHandler.sol";
import {AssetLib} from "../libraries/AssetLib.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";

/// @title FundsHandler
/// @notice Handles push/pull of funds across the system.
contract FundsHandler is AccessManagedUpgradeable, RescuableAssets, IFundsHandler {
    using SafeERC20 for IERC20;
    using AssetLib for uint256;

    struct ChainBalanceSnapshot {
        uint256 chainId;
        // Assumes all balances have common denomination.
        uint256 amountRay;
        uint256 nonce;
    }

    address internal constant BRIDGE_FEE_ON_NATIVE_CURRENCY = address(0);

    address internal immutable VAULT;
    address internal immutable GATEWAY;
    address internal immutable ALLOCATOR;

    ChainBalanceSnapshot[] internal _chainBalances;

    modifier onlyBasedBoostedVault() {
        require(msg.sender == VAULT, NotBasedBoostedVault());
        _;
    }

    modifier onlyGateway() {
        require(msg.sender == GATEWAY, NotGateway());
        _;
    }

    /// @dev Constructor.
    /// @param basedBoostedVault The address of the BasedBoostedVault contract, which triggers deposits and withdrawals.
    /// @param gateway The address of the Gateway contract to use for cross-chain communication.
    /// @param allocator The address of the Allocator contract to use for immediate liquidity management.
    constructor(address basedBoostedVault, address gateway, address allocator) {
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
        IAllocator.AllocatorBalance[] memory allocatorAssets = IAllocator(ALLOCATOR).getAssetBalances();

        uint256 totalBalanceRay;

        for (uint16 i = 0; i < allocatorAssets.length; i++) {
            totalBalanceRay += allocatorAssets[i].amount.assetDecimalsToRay(allocatorAssets[i].asset);
        }
        for (uint16 i = 0; i < _chainBalances.length; i++) {
            totalBalanceRay += _chainBalances[i].amountRay;
        }
        return totalBalanceRay;
    }

    /// @inheritdoc IFundsHandler
    function getAssetBalances() external view override returns (AssetBalance[] memory) {
        IAllocator.AllocatorBalance[] memory allocatorAssets = IAllocator(ALLOCATOR).getAssetBalances();
        AssetBalance[] memory balances = new AssetBalance[](allocatorAssets.length + _chainBalances.length);
        for (uint16 i = 0; i < allocatorAssets.length; i++) {
            balances[i] = AssetBalance({
                chainId: block.chainid,
                asset: allocatorAssets[i].asset,
                amountRay: allocatorAssets[i].amount.assetDecimalsToRay(allocatorAssets[i].asset)
            });
        }
        for (uint16 i = 0; i < _chainBalances.length; i++) {
            balances[allocatorAssets.length + i] = AssetBalance({
                chainId: _chainBalances[i].chainId, asset: address(0), amountRay: _chainBalances[i].amountRay
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
        IERC20(asset).forceApprove(VAULT, amount);
    }

    //////////////////////////////////////////// MANAGER FUNCTIONS /////////////////////////////////////////////////////

    /// @inheritdoc IFundsHandler
    function pushFundsToChain(
        address asset,
        uint256 amount,
        uint256 chainId,
        IChainGateway.BridgeParams memory bridgeParams
    ) external payable override restricted {
        require(amount > 0, ErrorsLib.ZeroAmount());

        if (bridgeParams.feeToken != BRIDGE_FEE_ON_NATIVE_CURRENCY) {
            IERC20(bridgeParams.feeToken).safeTransferFrom(bridgeParams.feePayer, address(this), bridgeParams.feeAmount);
            IERC20(bridgeParams.feeToken).forceApprove(GATEWAY, bridgeParams.feeAmount);
        }

        _pullFundsFromImmediateLiquidity(asset, amount);
        // Increase allowance in case of the fee token matching the token being bridged.
        IERC20(asset).safeIncreaseAllowance(GATEWAY, amount);
        // Increment the chain balance snapshot for the target chain.
        _updateChainBalanceBeforeBridging(chainId, amount.assetDecimalsToRay(asset));
        IAccountingChainGateway(GATEWAY).sendPushFundsToChainMessage{value: msg.value}(
            asset, amount, chainId, bridgeParams
        );
    }

    /// @inheritdoc RescuableAssets
    function rescueTokens(address asset, uint256 amount) public override restricted {
        super.rescueTokens(asset, amount);
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
    /// @dev Caller must have have transferred funds to this contract
    function fundsArrivedFromChainCallback(address asset, uint256 amount) external override onlyGateway {
        _pushFundsToImmediateLiquidity(asset, amount);
    }

    ////////////////////////////////////////////////// INTERNAL ////////////////////////////////////////////////////////

    function _updateChainBalance(uint256 chainId, uint256 snapshotBalanceRay, uint256 chainBalanceSnapshotNonce)
        internal
    {
        bool chainExists;
        for (uint16 i = 0; i < _chainBalances.length; i++) {
            if (_chainBalances[i].chainId == chainId) {
                chainExists = true;
                // Nonces should always be strictly increasing.
                // Use < to avoid replayable nonces.
                if (_chainBalances[i].nonce < chainBalanceSnapshotNonce) {
                    _chainBalances[i].nonce = chainBalanceSnapshotNonce;
                    _chainBalances[i].amountRay = snapshotBalanceRay;
                }
            }
        }
        if (!chainExists) {
            _chainBalances.push(
                ChainBalanceSnapshot({
                    chainId: chainId, amountRay: snapshotBalanceRay, nonce: chainBalanceSnapshotNonce
                })
            );
        }
    }

    ////////////////////////////////////////////////// INTERNAL /////////////////////////////////////////////////////

    /// @dev This does not update the chain balance snapshot nonce because any potential incoming snapshot data would be
    /// ignored.
    function _updateChainBalanceBeforeBridging(uint256 chainId, uint256 amountToIncrementRay) internal {
        bool chainExists;
        for (uint16 i = 0; i < _chainBalances.length; i++) {
            if (_chainBalances[i].chainId == chainId) {
                chainExists = true;
                _chainBalances[i].amountRay += amountToIncrementRay;
            }
        }
        if (!chainExists) {
            _chainBalances.push(ChainBalanceSnapshot({chainId: chainId, amountRay: amountToIncrementRay, nonce: 0}));
        }
    }

    function _pushFundsToImmediateLiquidity(address asset, uint256 amount) internal {
        IERC20(asset).forceApprove(ALLOCATOR, amount);
        IAllocator(ALLOCATOR).deposit(asset, amount);
    }

    function _pullFundsFromImmediateLiquidity(address asset, uint256 amount) internal {
        IAllocator(ALLOCATOR).withdraw(asset, amount);
    }
}

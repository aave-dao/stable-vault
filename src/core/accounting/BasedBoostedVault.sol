// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {
    ReentrancyGuardTransientUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {IBasedBoostedVault} from "src/interfaces/IBasedBoostedVault.sol";
import {IFundsHandler} from "src/interfaces/IFundsHandler.sol";
import {IIouTokenManager} from "src/interfaces/IIouTokenManager.sol";
import {ITransferHelper} from "src/interfaces/ITransferHelper.sol";
import {IWithdrawalPolicy} from "src/interfaces/IWithdrawalPolicy.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {Multicall} from "src/misc/Multicall.sol";
import {RescuableNative} from "src/misc/RescuableNative.sol";
import {RescuableToken} from "src/misc/RescuableToken.sol";
import {TransferHelperClient} from "src/misc/TransferHelperClient.sol";
import {Constants} from "src/types/Constants.sol";
import {Errors} from "src/types/Errors.sol";

/// @title BasedBoostedVault.
/// @author Aave Labs
/// @notice Semi-fixed rate vault.
/// @dev This contract supports batching of calls using the Multicall contract.
/// @dev Assets balances are tracked in RAY internally; conversions from and to specific asset denomination is made on
/// deposit and on withdrawal execution.
contract BasedBoostedVault is
    AccessManagedUpgradeable,
    RescuableNative,
    RescuableToken,
    TransferHelperClient,
    Multicall,
    ReentrancyGuardTransientUpgradeable,
    IBasedBoostedVault
{
    using MathLib for uint256;
    using AssetLib for uint256;
    using SafeERC20 for IERC20;

    /// @notice A subVault works like a virtual fixed-rate vault.
    /// @param perSecondRate The total per second rate of growth associated with the subVault.
    /// @param conversionRate The cumulative growth factor at a point in time; acts as conversion rate between shares
    /// and assets.
    /// @param lastAccrualTimestamp The timestamp of the last accrual i.e. when the `conversionRate` was updated.
    /// @param totalShares The total shares of the subVault outstanding.
    struct SubVault {
        uint256 perSecondRate;
        uint256 conversionRate;
        uint256 lastAccrualTimestamp;
        uint256 totalShares;
    }

    /// @notice The representation of an user's position. A single user will have at most 1 position.
    /// @param originalDepositRay The amount deposited by the user before accruing any interest.
    /// @param subVaultId The ID of the subVault where the user's assets are.
    /// @param shares The shares of the user, scaled, normalized by subVault conversionRate.
    struct UserPosition {
        uint256 originalDepositRay;
        uint256 subVaultId;
        uint256 shares;
    }

    address internal immutable ASSET_REGISTRY;

    address internal immutable IOU_TOKEN_MANAGER;

    uint256 internal immutable MAX_VALID_PER_SECOND_RATE;

    address internal immutable FUNDS_HANDLER;

    address internal immutable WITHDRAWAL_POLICY;

    uint256 internal immutable MAX_ACTIVE_SUB_VAULTS;

    /// @custom:storage-location erc7201:aave.storage.BasedBoostedVault
    struct BasedBoostedVaultStorage {
        /// @dev Keeps track of the sum of all users' original deposits.
        /// @dev Does not overlap with circulating IOUs because original deposits are decremented when new issue IOUs
        /// are minted.
        uint256 globalOriginalDepositsRay;

        /// @dev The ID of the last subVault created; monotonically increasing.
        uint256 lastSubVaultId;

        /// @dev The ID of the subVault where users without existing positions' deposits are allocated to.
        uint256 defaultSubVaultId;

        /// @dev Stores a SubVault by its ID.
        mapping(uint256 subVaultId => SubVault subVault) subVaultById;

        /// @dev The IDs of the SubVaults that have liquidity i.e. some user's assets on it.
        uint256[] activeSubVaultsIds;

        /// @dev SubVault index in the `activeSubVaultsIds` array.
        mapping(uint256 subVaultId => uint256 subVaultIndex) activeSubVaultIndexById;

        /// @dev SubVault ID by subVault per-second rate.
        mapping(uint256 subVaultRate => uint256 subVaultId) subVaultIdByRate;

        /// @dev User position by user address.
        mapping(address user => UserPosition position) positions;
    }

    // keccak256(abi.encode(uint256(keccak256("aave.storage.BasedBoostedVault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT_BASED_BOOSTED_VAULT =
        0xb8df01cf10d37fdfab5674a951575d5924fe29a8ad03fbfb69e60d893a967b00;

    function $storage() private pure returns (BasedBoostedVaultStorage storage _storage) {
        assembly {
            _storage.slot := STORAGE_SLOT_BASED_BOOSTED_VAULT
        }
    }

    /// @dev Constructor.
    /// @param maxValidPerSecondRate The maximum valid per-second rate, in Ray units (27 decimals).
    /// @param assetRegistry The address of the contract managing the allowed assets.
    /// @param iouTokenManager The address of the address that manages the supply of IOUs.
    /// @param fundsHandler The address of the contract that handles funds of the accounting chain.
    /// @param transferHelper The address of the contract that helps minimize the number of transfers across flows.
    /// @param withdrawalPolicy The address of the contract ensuring protocol's withdrawal requirements are met.
    /// @param maxActiveSubVaults The maximum number of active sub-vaults allowed.
    constructor(
        uint256 maxValidPerSecondRate,
        address assetRegistry,
        address iouTokenManager,
        address fundsHandler,
        address transferHelper,
        address withdrawalPolicy,
        uint256 maxActiveSubVaults
    ) TransferHelperClient(transferHelper) {
        _disableInitializers();
        require(maxValidPerSecondRate > MathLib.RAY, InvalidRate());
        MAX_VALID_PER_SECOND_RATE = maxValidPerSecondRate;
        ASSET_REGISTRY = assetRegistry;
        IOU_TOKEN_MANAGER = iouTokenManager;
        FUNDS_HANDLER = fundsHandler;
        WITHDRAWAL_POLICY = withdrawalPolicy;
        MAX_ACTIVE_SUB_VAULTS = maxActiveSubVaults;
    }

    /// @dev Initializer.
    /// @param accessManager Address of the IAccessManager contract used for handling access control.
    /// @param defaultSubVaultPerSecondRate Base per-second rate, in Ray units (27 decimals).
    function initialize(address accessManager, uint256 defaultSubVaultPerSecondRate) external virtual initializer {
        __BasedBoostedVault_init(accessManager, defaultSubVaultPerSecondRate);
    }

    function __BasedBoostedVault_init(address accessManager, uint256 defaultSubVaultPerSecondRate)
        internal
        virtual
        onlyInitializing
    {
        __AccessManaged_init(accessManager);
        _setDefaultSubVault(_getOrCreateSubVaultWithRate(defaultSubVaultPerSecondRate), defaultSubVaultPerSecondRate);
    }

    /// @inheritdoc IBasedBoostedVault
    function deposit(address user, address asset, uint256 amount)
        external
        override
        nonReentrant
        assertingTransferHelperBalanceFor(asset)
    {
        require(IAssetRegistry(ASSET_REGISTRY).isUserDepositAllowed(asset), Errors.UnsupportedAsset(asset));
        require(amount > 0, Errors.InvalidAmount());

        uint256 subVaultId = $storage().positions[user].subVaultId;
        if (subVaultId == 0) {
            subVaultId = $storage().defaultSubVaultId;
            $storage().positions[user].subVaultId = subVaultId;
        }

        uint256 conversionRate = _accrueSubVaultConversionRate(subVaultId);

        if (!_isActiveSubVaultById(subVaultId)) {
            _addSubVaultToActive(subVaultId);
            _validateAmountOfActiveSubVaults();
        }

        _transferToTransferHelper(msg.sender, asset, amount);
        uint256 netDepositAmount = IFundsHandler(FUNDS_HANDLER).processDeposit(asset, amount);

        // Calculate the number of shares to mint based on the full amount deposited.
        // If (amount - netDepositAmount) > 0, then this ~amount will be treated as interest earned.
        // Round down the division to undershoot the amount of granted shares, favoring the protocol.
        uint256 shares = amount.assetDecimalsToRay(asset).rayDivDown(conversionRate);
        // Prevent deposits that result in 0 shares to avoid user getting nothing in return for their deposit.
        require(shares > 0, Errors.InvalidAmount());

        _mintShares(user, subVaultId, shares);
        // Increment the original deposit amount by the net deposit amount only, not the full amount.
        // This protects against the system gauranteeing the full amount of the asset deposited in the case an
        // underlying strategy suffers slippage.
        uint256 netDepositAmountInRay = netDepositAmount.assetDecimalsToRay(asset);
        $storage().positions[user].originalDepositRay += netDepositAmountInRay;
        $storage().globalOriginalDepositsRay += netDepositAmountInRay;

        emit Deposit(user, asset, amount);
        emit Transfer(address(0), user, amount.assetDecimalsToRay(asset));
    }

    /// @notice Transfers BBV balance (denominated in RAY) between users.
    /// @dev This is accounting-only (no IOUs, no assets, no WithdrawalPolicy).
    /// @dev For full balance transfers, use transferAll() instead.
    /// @dev Reverts if the remaining sender balance after transfer would be below dust threshold.
    /// @dev The sender's principal (`originalDepositRay`) is decremented by up to `amountRay` and the same principal
    /// amount is moved to the recipient. This mirrors the accounting outcome of withdraw -> transfer assets ->
    /// recipient deposit.
    /// @dev Principal is tracked as one aggregate balance per user (not by deposit lots), so transfers always consume
    /// from that aggregate principal balance.
    function transfer(address to, uint256 amountRay) external override nonReentrant returns (bool) {
        address from = msg.sender;
        require(amountRay >= Constants.MIN_WITHDRAWABLE_AMOUNT_RAY, Errors.InvalidAmount());
        require(to != address(0), Errors.InvalidParameter());
        require(to != from, Errors.InvalidParameter());

        uint256 fromSubVaultId = $storage().positions[from].subVaultId;
        require(fromSubVaultId != 0, NonExistentPosition());

        uint256 fromConversionRate = _accrueSubVaultConversionRate(fromSubVaultId);

        (uint256 guaranteedAmountRay, uint256 fromUserShares) =
            _computeTransferShares(from, amountRay, fromSubVaultId, fromConversionRate);

        uint256 toSubVaultId = _getOrAssignUserSubVaultId(to);

        uint256 toUserShares;
        if (toSubVaultId == fromSubVaultId) {
            toUserShares = amountRay.rayDivDown(fromConversionRate);
        } else {
            uint256 toConversionRate = _accrueSubVaultConversionRate(toSubVaultId);
            toUserShares = amountRay.rayDivDown(toConversionRate);
        }
        require(toUserShares > 0, Errors.InvalidAmount());

        _moveShares({
            from: from,
            to: to,
            fromSubVaultId: fromSubVaultId,
            toSubVaultId: toSubVaultId,
            sharesToBurn: fromUserShares,
            sharesToMint: toUserShares,
            guaranteedAmountToMoveRay: guaranteedAmountRay
        });

        emit Transfer(from, to, amountRay);
        return true;
    }

    /// @notice Transfers the sender's full position to another user.
    /// @dev Any remaining original deposit amount is also transferred to the recipient.
    function transferAll(address to) external override nonReentrant returns (bool) {
        address from = msg.sender;
        require(to != address(0), Errors.InvalidParameter());
        require(to != from, Errors.InvalidParameter());

        uint256 fromSubVaultId = $storage().positions[from].subVaultId;
        require(fromSubVaultId != 0, NonExistentPosition());

        uint256 fromConversionRate = _accrueSubVaultConversionRate(fromSubVaultId);

        (uint256 amountOfWithdrawalRay, uint256 guaranteedAmountRay, uint256 fromUserShares) =
            _previewFullWithdrawalRequest(from);

        uint256 toSubVaultId = _getOrAssignUserSubVaultId(to);

        uint256 toUserShares;
        if (toSubVaultId == fromSubVaultId) {
            toUserShares = fromUserShares;
        } else {
            uint256 toConversionRate = _accrueSubVaultConversionRate(toSubVaultId);
            toUserShares = fromUserShares.rayMulDown(fromConversionRate).rayDivDown(toConversionRate);
        }
        require(toUserShares > 0, Errors.InvalidAmount());

        _moveShares({
            from: from,
            to: to,
            fromSubVaultId: fromSubVaultId,
            toSubVaultId: toSubVaultId,
            sharesToBurn: fromUserShares,
            sharesToMint: toUserShares,
            guaranteedAmountToMoveRay: guaranteedAmountRay
        });

        emit Transfer(from, to, amountOfWithdrawalRay);
        return true;
    }

    /// @inheritdoc IBasedBoostedVault
    function setUserRate(UserRateData[] calldata userRateData) external override restricted {
        for (uint256 i = 0; i < userRateData.length; i++) {
            _setUserRate(userRateData[i].user, userRateData[i].newPerSecondRate);
        }
    }

    /// @inheritdoc IBasedBoostedVault
    function setSubVaultRate(uint256 subVaultId, uint256 newPerSecondRate) external override restricted {
        _validateRate(newPerSecondRate);
        require(!_existsSubVaultWithRate(newPerSecondRate), SubVaultAlreadyExists());
        uint256 oldPerSecondRate = $storage().subVaultById[subVaultId].perSecondRate;
        require(oldPerSecondRate != 0, SubVaultDoesNotExist());
        _accrueSubVaultConversionRate(subVaultId);
        delete $storage().subVaultIdByRate[oldPerSecondRate];
        $storage().subVaultById[subVaultId].perSecondRate = newPerSecondRate;
        $storage().subVaultIdByRate[newPerSecondRate] = subVaultId;
        emit SubVaultRateSet(subVaultId, newPerSecondRate);
        if ($storage().defaultSubVaultId == subVaultId) {
            emit DefaultSubVaultSet(subVaultId, newPerSecondRate);
        }
    }

    /// @inheritdoc IBasedBoostedVault
    function requestWithdrawal(address user, uint256 requestedAmountInRay)
        external
        override
        nonReentrant
        returns (uint256)
    {
        require(user == msg.sender, OnlyUser());

        uint256 subVaultId = $storage().positions[user].subVaultId;
        require(subVaultId > 0, NonExistentPosition());

        _accrueSubVaultConversionRate(subVaultId);

        uint256 actualAmountInRay;
        uint256 guaranteedAmountRay;
        uint256 redeemedShares;

        if (requestedAmountInRay == 0) {
            (actualAmountInRay, guaranteedAmountRay, redeemedShares) = _previewFullWithdrawalRequest(user);
        } else {
            (actualAmountInRay, guaranteedAmountRay, redeemedShares) =
                _previewPartialWithdrawalRequest(user, requestedAmountInRay);
            // If the remaining shares are not redeemable for at least 1 wei of 18-decimal asset,
            // perform a full withdrawal instead, avoiding leaving non-redeemable dust shares.
            if (!_areRemainingSharesRedeemable(user, redeemedShares, subVaultId)) {
                (actualAmountInRay, guaranteedAmountRay, redeemedShares) = _previewFullWithdrawalRequest(user);
            }
        }

        uint256 remainingShares = _burnShares(user, subVaultId, redeemedShares);
        if (remainingShares == 0) {
            delete $storage().positions[user];
        } else {
            // Only needed if the user has remaining balance, otherwise the whole position is deleted.
            $storage().positions[user].originalDepositRay -= guaranteedAmountRay;
        }

        // Assets in Allocator + last snapshot updates from Earning chains
        uint256 totalAssetsRay = _getVaultAggregatedBalance();
        // There is no overlap between original deposits and circulating IOUs because original deposits are decremented
        // when new issue IOUs are minted.
        uint256 guaranteedObligationsRay = _getIousInCirculation() + $storage().globalOriginalDepositsRay;
        uint256 globalWithdrawableInterestRay =
            totalAssetsRay > guaranteedObligationsRay ? totalAssetsRay - guaranteedObligationsRay : 0;
        uint256 withdrawalRequestInterestRay = actualAmountInRay - guaranteedAmountRay;
        require(
            withdrawalRequestInterestRay <= globalWithdrawableInterestRay,
            InsufficientAssets(user, actualAmountInRay, guaranteedAmountRay + globalWithdrawableInterestRay)
        );

        $storage().globalOriginalDepositsRay -= guaranteedAmountRay;

        if (!_isActiveSubVaultById(subVaultId)) {
            _removeSubVaultFromActive(subVaultId);
        }

        _mintIous(user, actualAmountInRay);

        emit WithdrawalRequested(user, subVaultId, actualAmountInRay, guaranteedAmountRay);
        emit Transfer(user, address(0), actualAmountInRay);
        return actualAmountInRay;
    }

    /// @inheritdoc IBasedBoostedVault
    function executeWithdrawal(
        address user,
        address assetOut,
        uint256 minAmountOut,
        uint256 iouAmountRay,
        bytes memory data
    ) external override nonReentrant assertingTransferHelperBalanceFor(assetOut) {
        require(user == msg.sender, OnlyUser());
        IIouTokenManager(IOU_TOKEN_MANAGER).burnTokens(user, iouAmountRay);
        uint256 amountOutRay = IWithdrawalPolicy(WITHDRAWAL_POLICY)
            .applyWithdrawalPolicy(
                IWithdrawalPolicy.WithdrawalRequest({
                    user: user, assetOut: assetOut, iouAmountRay: iouAmountRay, data: data
                })
            );
        // Note: The `rayToAssetDecimals` conversion truncates, so the user may burn slightly more IOUs than the
        // exact RAY-equivalent of the assets received. This "dust" loss is at most `10 ^ (27 - assetDecimals) - 1` RAY
        // per withdrawal, which is economically negligible (e.g., <$0.000001 for 6-decimal stablecoins; it would take
        // >1,000,000 withdrawals to accumulate $1 of loss). The gas cost of preventing this (~1,600 gas for an extra
        // conversion) exceeds the value of the dust, so we accept this minor rounding in favor of the protocol.
        uint256 assetAmount = amountOutRay.rayToAssetDecimals(assetOut);
        require(assetAmount != 0 && assetAmount >= minAmountOut, Errors.InsufficientAmountOut());
        IFundsHandler(FUNDS_HANDLER).processWithdrawal(assetOut, assetAmount);
        ITransferHelper(TRANSFER_HELPER).transfer(assetOut, assetAmount, user);
        emit WithdrawalExecuted(user, assetOut, assetAmount);
    }

    /// @inheritdoc IBasedBoostedVault
    function setDefaultSubVault(uint256 perSecondRate) external override restricted {
        _setDefaultSubVault(_getOrCreateSubVaultWithRate(perSecondRate), perSecondRate);
    }

    /// @inheritdoc IBasedBoostedVault
    function claimSurplusInterest(address[] calldata assets, uint256[] calldata amounts)
        external
        override
        restricted
        assertingTransferHelperBalanceForAssets(assets)
    {
        uint256 vaultObligationsRay = _getVaultObligations();
        uint256 vaultAssetsRay = _getVaultAggregatedBalance();
        require(vaultObligationsRay <= vaultAssetsRay, NoSurplusInterestToClaim());
        uint256 surplusInterest = vaultAssetsRay - vaultObligationsRay;
        uint256 accumulatedAmountRay;
        for (uint256 i = 0; i < assets.length; i++) {
            IFundsHandler(FUNDS_HANDLER).processWithdrawal(assets[i], amounts[i]);
            accumulatedAmountRay += amounts[i].assetDecimalsToRay(assets[i]);
        }
        require(accumulatedAmountRay <= surplusInterest, Errors.InvalidAmount());
        ITransferHelper(TRANSFER_HELPER).transfer(assets, amounts, msg.sender);
        emit SurplusInterestClaimed(assets, amounts);
    }

    ////////////////////////////////////////////////// GETTERS /////////////////////////////////////////////////////

    /// @inheritdoc IBasedBoostedVault
    function getGlobalOriginalDepositAmount() external view override returns (uint256) {
        return $storage().globalOriginalDepositsRay;
    }

    /// @inheritdoc IBasedBoostedVault
    function getActiveSubVaults() external view override returns (SubVaultData[] memory) {
        SubVaultData[] memory activeSubVaults = new SubVaultData[]($storage().activeSubVaultsIds.length);
        for (uint256 i = 0; i < $storage().activeSubVaultsIds.length; i++) {
            uint256 subVaultId = $storage().activeSubVaultsIds[i];
            uint256 perSecondRate = $storage().subVaultById[subVaultId].perSecondRate;
            activeSubVaults[i] = SubVaultData({perSecondRate: perSecondRate, id: subVaultId});
        }
        return activeSubVaults;
    }

    /// @inheritdoc IBasedBoostedVault
    function getVaultObligations() external view override returns (uint256) {
        return _getVaultObligations();
    }

    /// @inheritdoc IBasedBoostedVault
    function totalSupply() external view override returns (uint256) {
        return _getActiveSubVaultsObligations();
    }

    /// @inheritdoc IBasedBoostedVault
    function getAggregatedBalance() external view override returns (uint256) {
        return _getVaultAggregatedBalance();
    }

    /// @inheritdoc IBasedBoostedVault
    function balanceOf(address account) external view override returns (uint256) {
        return _getUserBalance(account);
    }

    /// @inheritdoc IBasedBoostedVault
    function getUserBalance(address user) external view override returns (uint256) {
        return _getUserBalance(user);
    }

    /// @inheritdoc IBasedBoostedVault
    function getUserSubVault(address user) external view override returns (SubVaultData memory) {
        uint256 subVaultId = $storage().positions[user].subVaultId;
        uint256 subVaultRate = $storage().subVaultById[subVaultId].perSecondRate;
        return SubVaultData({perSecondRate: subVaultRate, id: subVaultId});
    }

    /// @inheritdoc IBasedBoostedVault
    function getDefaultSubVault() external view override returns (SubVaultData memory) {
        uint256 subVaultId = $storage().defaultSubVaultId;
        uint256 subVaultRate = $storage().subVaultById[subVaultId].perSecondRate;
        return SubVaultData({perSecondRate: subVaultRate, id: subVaultId});
    }

    /// @inheritdoc IBasedBoostedVault
    function getSubVaultRateById(uint256 subVaultId) external view override returns (uint256) {
        return $storage().subVaultById[subVaultId].perSecondRate;
    }

    /// @inheritdoc IBasedBoostedVault
    function getSubVaultIdByRate(uint256 perSecondRate) external view override returns (uint256) {
        return $storage().subVaultIdByRate[perSecondRate];
    }

    /// @inheritdoc IBasedBoostedVault
    function getMaxValidPerSecondRate() external view override returns (uint256) {
        return MAX_VALID_PER_SECOND_RATE;
    }

    ////////////////////////////////////////////////// INTERNAL /////////////////////////////////////////////////////

    function _validateRate(uint256 perSecondRate) internal view {
        require(perSecondRate >= MathLib.RAY && perSecondRate <= MAX_VALID_PER_SECOND_RATE, InvalidRate());
    }

    function _getOrCreateSubVaultWithRate(uint256 perSecondRate) internal returns (uint256) {
        if (_existsSubVaultWithRate(perSecondRate)) {
            return $storage().subVaultIdByRate[perSecondRate];
        } else {
            return _createSubVault(perSecondRate);
        }
    }

    function _setDefaultSubVault(uint256 subVaultId, uint256 perSecondRate) internal {
        $storage().defaultSubVaultId = subVaultId;
        emit DefaultSubVaultSet(subVaultId, perSecondRate);
    }

    function _createSubVault(uint256 newPerSecondRate) internal returns (uint256) {
        _validateRate(newPerSecondRate);
        uint256 newSubVaultId = ++$storage().lastSubVaultId;
        $storage().subVaultById[newSubVaultId] = SubVault({
            perSecondRate: newPerSecondRate,
            conversionRate: MathLib.RAY,
            lastAccrualTimestamp: uint256(block.timestamp),
            totalShares: 0
        });
        $storage().subVaultIdByRate[newPerSecondRate] = newSubVaultId;
        emit SubVaultCreated(newSubVaultId, newPerSecondRate);
        return newSubVaultId;
    }

    function _migrateUserToSubVault(address user, uint256 oldSubVaultId, uint256 newSubVaultId) internal {
        uint256 oldConversionRate = _accrueSubVaultConversionRate(oldSubVaultId);
        uint256 newConversionRate = _accrueSubVaultConversionRate(newSubVaultId);
        uint256 userOldShares = $storage().positions[user].shares;
        // Round down the amount of shares after sub-vault migration, so that the rounding is in favor of the protocol.
        uint256 userNewShares = userOldShares.rayMulDown(oldConversionRate).rayDivDown(newConversionRate);
        // Do not allow the user position share quantity to deplete to zero which can happen if a user has a small
        // userOldShares quantity and newConversionRate is large.
        require(userNewShares > 0, Errors.InvalidAmount());

        _moveShares({
            from: user,
            to: user,
            fromSubVaultId: oldSubVaultId,
            toSubVaultId: newSubVaultId,
            sharesToBurn: userOldShares,
            sharesToMint: userNewShares,
            guaranteedAmountToMoveRay: 0
        });
    }

    function _moveShares(
        address from,
        address to,
        uint256 fromSubVaultId,
        uint256 toSubVaultId,
        uint256 sharesToBurn,
        uint256 sharesToMint,
        uint256 guaranteedAmountToMoveRay
    ) internal {
        uint256 remainingShares = _burnShares(from, fromSubVaultId, sharesToBurn);
        if (fromSubVaultId != toSubVaultId) {
            if (!_isActiveSubVaultById(fromSubVaultId)) {
                _removeSubVaultFromActive(fromSubVaultId);
            }
            if (!_isActiveSubVaultById(toSubVaultId)) {
                _addSubVaultToActive(toSubVaultId);
            }
        }
        _validateAmountOfActiveSubVaults();

        if (from == to) {
            // Sanity check. If the user is the same - this cannot be a partial transfer.
            require(remainingShares == 0, Errors.InvalidAmount());
            require(guaranteedAmountToMoveRay == 0, Errors.InvalidAmount());
            $storage().positions[to].subVaultId = toSubVaultId;
        } else {
            if (remainingShares == 0) {
                delete $storage().positions[from];
            } else {
                $storage().positions[from].originalDepositRay -= guaranteedAmountToMoveRay;
            }
            $storage().positions[to].originalDepositRay += guaranteedAmountToMoveRay;
        }

        _mintShares(to, toSubVaultId, sharesToMint);
    }

    /// @dev Gets the user's subVaultId or assigns a default subVaultId if the user has no position.
    /// @dev A position is created for the user if they do not have one.
    function _getOrAssignUserSubVaultId(address user) internal returns (uint256) {
        uint256 subVaultId = $storage().positions[user].subVaultId;
        if (subVaultId == 0) {
            subVaultId = $storage().defaultSubVaultId;
            $storage().positions[user].subVaultId = subVaultId;
        }
        return subVaultId;
    }

    /// @dev Computes the shares to burn from sender and guaranteed amount for a transfer.
    /// @dev Reverts if remaining shares would be below dust threshold - caller should use transferAll() instead.
    function _computeTransferShares(address from, uint256 amountRay, uint256 fromSubVaultId, uint256 fromConversionRate)
        internal
        view
        returns (uint256, uint256)
    {
        (uint256 fullAmountRay, uint256 fullGuaranteedAmountRay, uint256 fullSharesToRedeem) =
            _previewFullWithdrawalRequest(from);
        require(amountRay <= fullAmountRay, Errors.InsufficientFunds());

        if (amountRay == fullAmountRay) {
            return (fullGuaranteedAmountRay, fullSharesToRedeem);
        }

        uint256 fromUserShares = amountRay.rayDivUp(fromConversionRate);

        require(_areRemainingSharesRedeemable(from, fromUserShares, fromSubVaultId), Errors.InvalidAmount());
        uint256 guaranteedAmountRay = _getAmountTakenFromOriginalDeposit(from, amountRay);
        return (guaranteedAmountRay, fromUserShares);
    }

    function _areRemainingSharesRedeemable(address user, uint256 redeemedShares, uint256 subVaultId)
        internal
        view
        returns (bool)
    {
        // We want the remainder after a partial withdrawal to be redeemable for at least 1 wei (18-dec) of value.
        // A share balance S (in RAY units) redeems to:
        //   valueRay = rayMulDown(S * conversionRate)
        // and it is withdrawable iff:
        //   rayMulDown(S * conversionRate) >= 1e9
        // which implies:
        //   S >= rayDivUp(1e9, conversionRate)
        uint256 minSharesToRedeemOneWei =
            Constants.MIN_WITHDRAWABLE_AMOUNT_RAY.rayDivUp($storage().subVaultById[subVaultId].conversionRate);
        uint256 remainingSharesAfterRedeem = $storage().positions[user].shares - redeemedShares;
        return remainingSharesAfterRedeem >= minSharesToRedeemOneWei;
    }

    function _addSubVaultToActive(uint256 subVaultId) internal {
        $storage().activeSubVaultsIds.push(subVaultId);
        $storage().activeSubVaultIndexById[subVaultId] = $storage().activeSubVaultsIds.length - 1;
    }

    // Assumes that if it is called then `subVaultId` is indeed active, thus `$storage().activeSubVaultsIds.length > 0`
    function _removeSubVaultFromActive(uint256 subVaultId) internal {
        uint256 subVaultIndex = $storage().activeSubVaultIndexById[subVaultId];
        uint256 lastSubVaultIndex = $storage().activeSubVaultsIds.length - 1;
        if (subVaultIndex != lastSubVaultIndex) {
            uint256 lastSubVaultId = $storage().activeSubVaultsIds[lastSubVaultIndex];
            $storage().activeSubVaultsIds[subVaultIndex] = lastSubVaultId;
            $storage().activeSubVaultIndexById[lastSubVaultId] = subVaultIndex;
        }
        $storage().activeSubVaultsIds.pop();
        delete $storage().activeSubVaultIndexById[subVaultId];
    }

    function _validateAmountOfActiveSubVaults() internal view {
        require($storage().activeSubVaultsIds.length <= MAX_ACTIVE_SUB_VAULTS, TooManyActiveSubVaults());
    }

    function _previewSubVaultConversionRate(uint256 subVaultId) internal view returns (uint256) {
        uint256 secondsSinceLastAccrual = block.timestamp - $storage().subVaultById[subVaultId].lastAccrualTimestamp;
        uint256 newConversionRate = $storage().subVaultById[subVaultId].conversionRate;
        if (secondsSinceLastAccrual != 0) {
            uint256 growthFactor = $storage().subVaultById[subVaultId].perSecondRate.rpow(secondsSinceLastAccrual);
            // The conversion rate is used across different operations (e.g. converting assets to shares on deposits,
            // converting shares to assets on withdrawals, computing total vault obligations, etc.).
            // The conversion rate calculation rounds down to ensure a conservative and consistent value that subsequent
            // operations can then use to apply their context-specific rounding on top with the intention of favoring
            // the protocol.
            newConversionRate = newConversionRate.rayMulDown(growthFactor);
        }
        return newConversionRate;
    }

    function _accrueSubVaultConversionRate(uint256 subVaultId) internal returns (uint256) {
        uint256 newConversionRate = _previewSubVaultConversionRate(subVaultId);
        $storage().subVaultById[subVaultId].conversionRate = newConversionRate;
        $storage().subVaultById[subVaultId].lastAccrualTimestamp = block.timestamp;
        return newConversionRate;
    }

    function _previewFullWithdrawalRequest(address user) internal view returns (uint256, uint256, uint256) {
        uint256 subVaultId = $storage().positions[user].subVaultId;
        // The conversion rate was accrued in the higher order withdrawal function using rounding that favors the
        // protocol. We want the conversion rate's calculation to be rounded down so that we undershoot result of
        // sharesToRedeem * conversionRate.
        uint256 conversionRate = $storage().subVaultById[subVaultId].conversionRate;
        uint256 sharesToRedeem = $storage().positions[user].shares;
        // Round down the withdrawal amount, so that the rounding is in favor of the protocol.
        uint256 actualAmountOfWithdrawalRay = sharesToRedeem.rayMulDown(conversionRate);
        uint256 originalDepositRay = $storage().positions[user].originalDepositRay;
        // Due to rounding in rayDivDown (deposit) and rayMulDown (withdrawal),
        // actualAmountOfWithdrawalRay can be slightly less than originalDepositRay.
        // We guarantee the user gets at least their original deposit back.
        if (actualAmountOfWithdrawalRay < originalDepositRay) {
            actualAmountOfWithdrawalRay = originalDepositRay;
        }
        return (actualAmountOfWithdrawalRay, originalDepositRay, sharesToRedeem);
    }

    function _previewPartialWithdrawalRequest(address user, uint256 withdrawalAmountRay)
        internal
        view
        returns (uint256, uint256, uint256)
    {
        uint256 subVaultId = $storage().positions[user].subVaultId;
        // The conversion rate was accrued in the higher order withdrawal function using rounding that favors the
        // protocol. We want the conversion rate's calculation to be rounded down so that we undershoot the divisor used
        // to calculate the amount of shares to redeem/burn.
        uint256 conversionRate = $storage().subVaultById[subVaultId].conversionRate;
        // Round up the amount of shares to redeem (burn on the position) for the requested amount of assets, so that
        // the rounding is in favor of the protocol.
        uint256 sharesToRedeem = withdrawalAmountRay.rayDivUp(conversionRate);
        require(sharesToRedeem <= $storage().positions[user].shares, Errors.InvalidAmount());
        return (withdrawalAmountRay, _getAmountTakenFromOriginalDeposit(user, withdrawalAmountRay), sharesToRedeem);
    }

    function _getAmountTakenFromOriginalDeposit(address user, uint256 withdrawalAmountRay)
        internal
        view
        returns (uint256)
    {
        uint256 amountTakenFromOriginalDepositRay;
        uint256 originalDepositRay = $storage().positions[user].originalDepositRay;
        if (withdrawalAmountRay >= originalDepositRay) {
            // The remaining portion of user's withdrawable balance is not guaranteed unless user deposits more funds.
            amountTakenFromOriginalDepositRay = originalDepositRay;
        } else {
            amountTakenFromOriginalDepositRay = withdrawalAmountRay;
        }
        return amountTakenFromOriginalDepositRay;
    }

    function _burnShares(address user, uint256 subVaultId, uint256 sharesToBurn) internal returns (uint256) {
        $storage().positions[user].shares -= sharesToBurn;
        $storage().subVaultById[subVaultId].totalShares -= sharesToBurn;
        return $storage().positions[user].shares;
    }

    function _mintShares(address user, uint256 subVaultId, uint256 sharesToMint) internal {
        $storage().positions[user].shares += sharesToMint;
        $storage().subVaultById[subVaultId].totalShares += sharesToMint;
    }

    function _getUserBalance(address user) internal view returns (uint256) {
        if ($storage().positions[user].shares == 0) {
            return 0;
        }
        // Round down the user balance, so that the rounding is in favor of the protocol.
        return $storage().positions[user].shares
            .rayMulDown(_previewSubVaultConversionRate($storage().positions[user].subVaultId));
    }

    function _getActiveSubVaultsObligations() internal view returns (uint256) {
        uint256 activeSubVaultsObligations;
        for (uint256 i = 0; i < $storage().activeSubVaultsIds.length; i++) {
            // Round up the obligations, so that the rounding is in favor of the protocol.
            activeSubVaultsObligations += $storage().subVaultById[$storage().activeSubVaultsIds[i]].totalShares
                .rayMulUp(_previewSubVaultConversionRate($storage().activeSubVaultsIds[i]));
        }
        return activeSubVaultsObligations;
    }

    function _getVaultObligations() internal view returns (uint256) {
        return _getActiveSubVaultsObligations() + _getIousInCirculation();
    }

    function _getVaultAggregatedBalance() internal view returns (uint256) {
        return IFundsHandler(FUNDS_HANDLER).getAggregatedBalance();
    }

    /// @return supply of all IOU tokens across all networks
    function _getIousInCirculation() internal view returns (uint256) {
        return IERC20(IIouTokenManager(IOU_TOKEN_MANAGER).getAsset()).totalSupply();
    }

    function _mintIous(address user, uint256 amount) internal {
        IIouTokenManager(IOU_TOKEN_MANAGER).mintTokens(user, amount);
    }

    function _isActiveSubVaultById(uint256 subVaultId) internal view returns (bool) {
        return $storage().subVaultById[subVaultId].totalShares > 0;
    }

    function _existsSubVaultWithRate(uint256 perSecondRate) internal view returns (bool) {
        return $storage().subVaultIdByRate[perSecondRate] != 0;
    }

    function _setUserRate(address user, uint256 newPerSecondRate) internal {
        uint256 oldSubVaultId = $storage().positions[user].subVaultId;
        require(oldSubVaultId > 0, NonExistentPosition());
        require(newPerSecondRate != $storage().subVaultById[oldSubVaultId].perSecondRate, RedundantRate());

        uint256 newSubVaultId = _getOrCreateSubVaultWithRate(newPerSecondRate);

        _migrateUserToSubVault(user, oldSubVaultId, newSubVaultId);

        emit UserRateSet(user, newSubVaultId, newPerSecondRate);
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

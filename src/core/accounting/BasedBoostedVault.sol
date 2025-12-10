// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {IBasedBoostedVault} from "src/interfaces/IBasedBoostedVault.sol";
import {IFundsHandler} from "src/interfaces/IFundsHandler.sol";
import {IIouTokenManager} from "src/interfaces/IIouTokenManager.sol";
import {ITransferHelper} from "src/interfaces/ITransferHelper.sol";
import {IWithdrawalPolicy} from "src/interfaces/IWithdrawalPolicy.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {ErrorsLib} from "src/libraries/ErrorsLib.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {Multicall} from "src/misc/Multicall.sol";
import {RescuableAssets} from "src/misc/RescuableAssets.sol";
import {TransferHelperClient} from "src/misc/TransferHelperClient.sol";

/// @title BasedBoostedVault.
/// @author Aave Labs
/// @notice Semi-fixed rate vault.
/// @dev This contract supports batching of calls using the Multicall contract.
/// @dev Assets balances are tracked in RAY internally; conversions from and to specific asset denomination is made on
/// deposit and on withdrawal execution.
contract BasedBoostedVault is
    AccessManagedUpgradeable,
    RescuableAssets,
    TransferHelperClient,
    Multicall,
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
    /// @param iouTokenManager The address of the IOU token manager.
    /// @param fundsHandler The address of the FundsHandler contract.
    constructor(
        uint256 maxValidPerSecondRate,
        address assetRegistry,
        address iouTokenManager,
        address fundsHandler,
        address transferHelper,
        address withdrawalPolicy
    ) TransferHelperClient(transferHelper) {
        _disableInitializers();
        require(maxValidPerSecondRate > MathLib.RAY, InvalidRate());
        MAX_VALID_PER_SECOND_RATE = maxValidPerSecondRate;
        ASSET_REGISTRY = assetRegistry;
        IOU_TOKEN_MANAGER = iouTokenManager;
        FUNDS_HANDLER = fundsHandler;
        WITHDRAWAL_POLICY = withdrawalPolicy;
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
        assertingTransferHelperBalanceFor(asset)
    {
        require(IAssetRegistry(ASSET_REGISTRY).isUserDepositAllowed(asset), ErrorsLib.UnsupportedAsset(asset));
        require(amount > 0, ErrorsLib.InvalidAmount());

        uint256 subVaultId = $storage().positions[user].subVaultId;
        if (subVaultId == 0) {
            subVaultId = $storage().defaultSubVaultId;
            $storage().positions[user].subVaultId = subVaultId;
        }

        uint256 amountInRay = amount.assetDecimalsToRay(asset);
        // Round up the conversion rate used as divisor to calculate the shares the user receives. In this way, we
        // end up undershooting the amount of granted shares, favoring the protocol.
        uint256 conversionRateRoundedUp = _previewSubVaultConversionRateRoundingUp(subVaultId);
        // Round down the division with the same goal of undershooting amount of granted shares.
        uint256 shares = amountInRay.rayDivDown(conversionRateRoundedUp);
        // Prevent deposits that result in 0 shares to avoid user getting nothing in return for their deposit.
        require(shares > 0, ErrorsLib.InvalidAmount());
        _accrueSubVaultConversionRate(subVaultId);

        if (!_isActiveSubVaultById(subVaultId)) {
            _addSubVaultToActive(subVaultId);
        }

        $storage().subVaultById[subVaultId].totalShares += shares;
        $storage().positions[user].shares += shares;
        $storage().positions[user].originalDepositRay += amountInRay;
        $storage().globalOriginalDepositsRay += amountInRay;

        _transferToTransferHelper(msg.sender, asset, amount);
        IFundsHandler(FUNDS_HANDLER).processDeposit(asset, amount);

        emit Deposit(user, asset, amount);
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
    }

    /// @inheritdoc IBasedBoostedVault
    function requestWithdrawal(address user, uint256 requestedAmountInRay) external override returns (uint256) {
        require(user == msg.sender, OnlyUser());

        uint256 subVaultId = $storage().positions[user].subVaultId;
        require(subVaultId > 0, NonExistentPosition());

        _accrueSubVaultConversionRate(subVaultId);

        uint256 actualAmountInRay;
        uint256 guaranteedAmountRay;
        uint256 redeemedShares;

        if (requestedAmountInRay == 0) {
            (actualAmountInRay, guaranteedAmountRay, redeemedShares) = _fullWithdrawalRequest(user);
        } else {
            (actualAmountInRay, guaranteedAmountRay, redeemedShares) =
                _partialWithdrawalRequest(user, requestedAmountInRay);
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
        return actualAmountInRay;
    }

    /// @inheritdoc IBasedBoostedVault
    function executeWithdrawal(
        address user,
        address assetOut,
        uint256 minAmountOut,
        uint256 iouAmountRay,
        bytes memory data
    ) external override assertingTransferHelperBalanceFor(assetOut) {
        require(user == msg.sender, OnlyUser());
        IIouTokenManager(IOU_TOKEN_MANAGER).burnTokens(user, iouAmountRay);
        uint256 amountOutRay = IWithdrawalPolicy(WITHDRAWAL_POLICY)
            .applyWithdrawalPolicy(
                IWithdrawalPolicy.WithdrawalRequest({
                    user: user, assetOut: assetOut, iouAmountRay: iouAmountRay, data: data
                })
            );
        uint256 assetAmount = amountOutRay.rayToAssetDecimals(assetOut);
        require(assetAmount != 0 && assetAmount >= minAmountOut, ErrorsLib.InsufficientAmountOut());
        IFundsHandler(FUNDS_HANDLER).processWithdrawal(assetOut, assetAmount);
        ITransferHelper(TRANSFER_HELPER).transfer(assetOut, assetAmount, user);
        emit WithdrawalExecuted(user, assetOut, assetAmount);
    }

    /// @inheritdoc IBasedBoostedVault
    function setDefaultSubVault(uint256 perSecondRate) external override restricted {
        _setDefaultSubVault(_getOrCreateSubVaultWithRate(perSecondRate), perSecondRate);
    }

    /// @inheritdoc IBasedBoostedVault
    function claimFees(address[] calldata assets, uint256[] calldata amounts)
        external
        override
        restricted
        assertingTransferHelperBalanceForAssets(assets)
    {
        uint256 vaultObligationsRay = _getVaultObligations();
        uint256 vaultAssetsRay = _getVaultAggregatedBalance();
        require(vaultObligationsRay <= vaultAssetsRay, NoFeesToClaim());
        uint256 fee = vaultAssetsRay - vaultObligationsRay;
        uint256 accumulatedAmountRay;
        for (uint256 i = 0; i < assets.length; i++) {
            IFundsHandler(FUNDS_HANDLER).processWithdrawal(assets[i], amounts[i]);
            accumulatedAmountRay += amounts[i].assetDecimalsToRay(assets[i]);
        }
        require(accumulatedAmountRay <= fee, ErrorsLib.InvalidAmount());
        ITransferHelper(TRANSFER_HELPER).transfer(assets, amounts, msg.sender);
        emit FeesClaimed(assets, amounts);
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
    function getAggregatedBalance() external view override returns (uint256) {
        return _getVaultAggregatedBalance();
    }

    /// @inheritdoc IBasedBoostedVault
    function getUserBalance(address user) external view override returns (uint256) {
        if ($storage().positions[user].shares == 0) {
            return 0;
        }
        // Round down the user balance, so that the rounding is in favor of the protocol.
        return $storage().positions[user].shares
            .rayMulDown(_previewSubVaultConversionRateRoundingDown($storage().positions[user].subVaultId));
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
        _accrueSubVaultConversionRate(oldSubVaultId);
        _accrueSubVaultConversionRate(newSubVaultId);
        uint256 oldConversionRate = $storage().subVaultById[oldSubVaultId].conversionRate;
        uint256 newConversionRate = $storage().subVaultById[newSubVaultId].conversionRate;
        uint256 userOldShares = $storage().positions[user].shares;
        // Round down the amount of shares after sub-vault migration, so that the rounding is in favor of the protocol.
        uint256 userNewShares = userOldShares.rayMulDown(oldConversionRate).rayDivDown(newConversionRate);
        // Do not allow the user position share quantity to deplete to zero which can happen if a user has a small
        // userOldShares quantity and newConversionRate is large.
        require(userNewShares > 0, ErrorsLib.InvalidAmount());

        if (!_isActiveSubVaultById(newSubVaultId)) {
            _addSubVaultToActive(newSubVaultId);
        }

        $storage().subVaultById[oldSubVaultId].totalShares -= userOldShares;
        $storage().subVaultById[newSubVaultId].totalShares += userNewShares;

        $storage().positions[user].shares = userNewShares;
        $storage().positions[user].subVaultId = newSubVaultId;

        if (!_isActiveSubVaultById(oldSubVaultId)) {
            _removeSubVaultFromActive(oldSubVaultId);
        }
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

    function _previewSubVaultConversionRateRoundingDown(uint256 subVaultId) internal view returns (uint256) {
        return _previewSubVaultConversionRate({subVaultId: subVaultId, roundDown: true});
    }

    function _previewSubVaultConversionRateRoundingUp(uint256 subVaultId) internal view returns (uint256) {
        return _previewSubVaultConversionRate({subVaultId: subVaultId, roundDown: false});
    }

    /// @dev Rounding direction should be determined based on context of usage of this function.
    /// @dev To undershoot the new conversion rate `roundDown` should be true.
    /// @dev To overshoot the new conversion rate `roundDown` should be false.
    function _previewSubVaultConversionRate(uint256 subVaultId, bool roundDown) internal view returns (uint256) {
        uint256 secondsSinceLastAccrual = block.timestamp - $storage().subVaultById[subVaultId].lastAccrualTimestamp;
        uint256 newConversionRate = $storage().subVaultById[subVaultId].conversionRate;
        if (secondsSinceLastAccrual != 0) {
            uint256 growthFactor = $storage().subVaultById[subVaultId].perSecondRate.rpow(secondsSinceLastAccrual);
            if (roundDown) {
                newConversionRate = newConversionRate.rayMulDown(growthFactor);
            } else {
                newConversionRate = newConversionRate.rayMulUp(growthFactor);
            }
        }
        return newConversionRate;
    }

    function _accrueSubVaultConversionRate(uint256 subVaultId) internal {
        $storage().subVaultById[subVaultId].conversionRate = _previewSubVaultConversionRateRoundingDown(subVaultId);
        $storage().subVaultById[subVaultId].lastAccrualTimestamp = block.timestamp;
    }

    function _fullWithdrawalRequest(address user) internal returns (uint256, uint256, uint256) {
        uint256 subVaultId = $storage().positions[user].subVaultId;
        // The conversion rate was accrued in the higher order withdrawal function using rounding that favors the
        // protocol. We want the conversion rate's calculation to be rounded down so that we undershoot result of
        // sharesToRedeem * conversionRate.
        uint256 conversionRate = $storage().subVaultById[subVaultId].conversionRate;
        uint256 sharesToRedeem = $storage().positions[user].shares;
        // Round down the withdrawal amount, so that the rounding is in favor of the protocol.
        uint256 actualAmountOfWithdrawalRay = sharesToRedeem.rayMulDown(conversionRate);
        _burnShares(user, sharesToRedeem);
        uint256 originalDepositRay = $storage().positions[user].originalDepositRay;
        delete $storage().positions[user];
        // Due to rounding in rayDivDown (deposit) and rayMulDown (withdrawal),
        // actualAmountOfWithdrawalRay can be slightly less than originalDepositRay.
        // We guarantee the user gets at least their original deposit back.
        if (actualAmountOfWithdrawalRay < originalDepositRay) {
            actualAmountOfWithdrawalRay = originalDepositRay;
        }
        return (actualAmountOfWithdrawalRay, originalDepositRay, sharesToRedeem);
    }

    function _partialWithdrawalRequest(address user, uint256 requestedAmountInRay)
        internal
        returns (uint256, uint256, uint256)
    {
        uint256 subVaultId = $storage().positions[user].subVaultId;
        // The conversion rate was accrued in the higher order withdrawal function using rounding that favors the
        // protocol. We want the conversion rate's calculation to be rounded down so that we undershoot the divisor used
        // to calculate the amount of shares to redeem/burn.
        uint256 conversionRate = $storage().subVaultById[subVaultId].conversionRate;

        // Round up the amount of shares to redeem (burn on the position) for the requested amount of assets, so that
        // the rounding is in favor of the protocol.
        uint256 sharesToRedeem = requestedAmountInRay.rayDivUp(conversionRate);
        require(sharesToRedeem <= $storage().positions[user].shares, ErrorsLib.InvalidAmount());
        _burnShares(user, sharesToRedeem);
        uint256 amountTakenFromOriginalDepositRay = _decrementOriginalDeposit(user, requestedAmountInRay);

        if ($storage().positions[user].shares == 0) {
            delete $storage().positions[user];
        }

        return (requestedAmountInRay, amountTakenFromOriginalDepositRay, sharesToRedeem);
    }

    function _decrementOriginalDeposit(address user, uint256 actualAmountOfWithdrawal) internal returns (uint256) {
        uint256 amountTakenFromOriginalDepositRay;
        if (actualAmountOfWithdrawal >= $storage().positions[user].originalDepositRay) {
            // The remaining portion of user's withdrawable balance is not guaranteed unless user deposits more funds.
            amountTakenFromOriginalDepositRay = $storage().positions[user].originalDepositRay;
        } else {
            amountTakenFromOriginalDepositRay = actualAmountOfWithdrawal;
        }
        $storage().positions[user].originalDepositRay -= amountTakenFromOriginalDepositRay;
        return amountTakenFromOriginalDepositRay;
    }

    function _burnShares(address user, uint256 shares) internal {
        uint256 subVaultId = $storage().positions[user].subVaultId;
        $storage().positions[user].shares -= shares;
        $storage().subVaultById[subVaultId].totalShares -= shares;
    }

    function _getVaultObligations() internal view returns (uint256) {
        uint256 activeSubVaultsObligations;
        for (uint256 i = 0; i < $storage().activeSubVaultsIds.length; i++) {
            // Round up the obligations, so that the rounding is in favor of the protocol.
            activeSubVaultsObligations += $storage().subVaultById[$storage().activeSubVaultsIds[i]].totalShares
                .rayMulUp(_previewSubVaultConversionRateRoundingUp($storage().activeSubVaultsIds[i]));
        }
        return activeSubVaultsObligations + _getIousInCirculation();
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
        address, // asset
        uint256 // amount
    )
        internal
        virtual
        override
    {
        // Equivalent to adding the `restricted` modifier.
        _checkCanCall(_msgSender(), _msgData());
    }
}

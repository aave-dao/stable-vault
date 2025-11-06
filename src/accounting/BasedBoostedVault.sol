// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {RescuableAssets} from "../common/RescuableAssets.sol";
import {IAssetRegistry} from "../interfaces/IAssetRegistry.sol";
import {IBasedBoostedVault} from "../interfaces/IBasedBoostedVault.sol";
import {IFundsHandler} from "../interfaces/IFundsHandler.sol";
import {IIouTokenManager} from "../interfaces/IIouTokenManager.sol";
import {AssetLib} from "../libraries/AssetLib.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {MathLib} from "../libraries/MathLib.sol";

/// @title BasedBoostedVault.
/// @notice Semi-fixed rate vault.
/// @dev Assets balances are tracked in RAY internally; conversions from and to specific asset denomination is made on
/// deposit and on withdrawal execution.
contract BasedBoostedVault is AccessManagedUpgradeable, RescuableAssets, IBasedBoostedVault {
    using MathLib for uint256;
    using AssetLib for uint256;
    using SafeERC20 for IERC20;

    /// @notice A subVault works like a virtual fixed-rate vault.
    ///
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
    /// @param shares The shares of the user, scaled, normalized by `_baseConversionRate * subVault.conversionRate`.
    struct UserPosition {
        uint256 originalDepositRay;
        uint256 subVaultId;
        uint256 shares;
    }

    uint256 internal constant SECONDS_PER_YEAR = 31_536_000;

    address internal immutable IOU_TOKEN_MANAGER;

    uint256 internal immutable MAX_VALID_PER_SECOND_RATE;

    address internal immutable FUNDS_HANDLER;

    address internal _assetRegistry;

    uint256 internal _globalOriginalDepositsRay;

    /// @dev The ID of the last subVault created; monotonically increasing.
    uint256 internal _lastSubVaultId;

    /// @dev The ID of the subVault where users without existing positions' deposits are allocated to.
    uint256 internal _defaultSubVaultId;

    /// @dev Stores a SubVault by its ID.
    mapping(uint256 subVaultId => SubVault subVault) internal _subVaultById;

    /// @dev The IDs of the SubVaults that have liquidity i.e. some user's assets on it.
    uint256[] internal _activeSubVaultsIds;

    /// @dev SubVault index in the `_activeSubVaultsIds` array.
    mapping(uint256 subVaultId => uint256 subVaultIndex) internal _activeSubVaultIndexById;

    /// @dev SubVault ID by subVault per-second rate.
    mapping(uint256 subVaultRate => uint256 subVaultId) internal _subVaultIdByRate;

    /// @dev User position by user address.
    mapping(address user => UserPosition position) internal _positions;

    /// @dev Constructor.
    /// @param maxValidPerSecondRate The maximum valid per-second rate, in Ray units (27 decimals).
    /// @param iouTokenManager The address of the IOU token manager.
    /// @param fundsHandler The address of the FundsHandler contract.
    constructor(uint256 maxValidPerSecondRate, address iouTokenManager, address fundsHandler) {
        _disableInitializers();
        require(maxValidPerSecondRate > MathLib.RAY, InvalidRate());
        MAX_VALID_PER_SECOND_RATE = maxValidPerSecondRate;
        IOU_TOKEN_MANAGER = iouTokenManager;
        FUNDS_HANDLER = fundsHandler;
    }

    /// @dev Initializer.
    /// @param accessManager The address of the IAccessManager contract used for handling access control.
    /// @param defaultSubVaultPerSecondRate The base per-second rate, in Ray units (27 decimals).
    /// @param assetRegistry The address of the contract that manages the permissions for handling assets.
    function initialize(address accessManager, uint256 defaultSubVaultPerSecondRate, address assetRegistry)
        external
        virtual
        initializer
    {
        __BasedBoostedVault_init(accessManager, defaultSubVaultPerSecondRate, assetRegistry);
    }

    function __BasedBoostedVault_init(
        address accessManager,
        uint256 defaultSubVaultPerSecondRate,
        address assetRegistry
    ) internal virtual onlyInitializing {
        __AccessManaged_init(accessManager);
        _assetRegistry = assetRegistry;
        _setDefaultSubVault(_createSubVault(defaultSubVaultPerSecondRate), defaultSubVaultPerSecondRate);
    }

    /// @inheritdoc IBasedBoostedVault
    function deposit(address user, address asset, uint256 amount) external override {
        require(msg.sender == user, InvalidMsgSender());
        require(IAssetRegistry(_assetRegistry).isAllowedToDepositIntoBBV(asset), ErrorsLib.UnsupportedAsset(asset));
        require(amount > 0, ErrorsLib.InvalidAmount());
        IERC20(asset).safeTransferFrom(msg.sender, FUNDS_HANDLER, amount);

        uint256 subVaultId = _positions[user].subVaultId;
        if (subVaultId == 0) {
            subVaultId = _defaultSubVaultId;
            _positions[user].subVaultId = subVaultId;
        }

        _accrueSubVaultConversionRate(subVaultId);

        uint256 conversionRate = _subVaultById[subVaultId].conversionRate;
        uint256 amountInRay = amount.assetDecimalsToRay(asset);
        uint256 shares = amountInRay.rayDivDown(conversionRate);

        if (!_isActiveSubVaultById(subVaultId)) {
            _addSubVaultToActive(subVaultId);
        }

        _subVaultById[subVaultId].totalShares += shares;
        _positions[user].shares += shares;
        _positions[user].originalDepositRay += amountInRay;
        _globalOriginalDepositsRay += amountInRay;

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
    function setSubVaultRate(uint256 subVaultId, uint256 newPerSecondRate) external restricted {
        _validateRate(newPerSecondRate);
        require(!_existsSubVaultWithRate(newPerSecondRate), SubVaultAlreadyExists());
        require(_existsSubVaultWithId(subVaultId), SubVaultDoesNotExist());
        _accrueSubVaultConversionRate(subVaultId);
        _subVaultById[subVaultId].perSecondRate = newPerSecondRate;
        _subVaultIdByRate[newPerSecondRate] = subVaultId;
        emit SubVaultRateSet(subVaultId, newPerSecondRate);
    }

    /// @inheritdoc IBasedBoostedVault
    function requestWithdrawal(address user, uint256 requestedAmountInRay) external override returns (uint256) {
        require(msg.sender == user, InvalidMsgSender());

        uint256 subVaultId = _positions[user].subVaultId;
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
        uint256 guaranteedObligationsRay = _getIousInCirculation() + _globalOriginalDepositsRay;
        // This can underflow if Earning chain(s) have not sent back the balance update and user positions have been
        // removed (they've claimed IOUs).
        uint256 globalWithdrawableInterestRay =
            totalAssetsRay > guaranteedObligationsRay ? totalAssetsRay - guaranteedObligationsRay : 0;
        uint256 withdrawalRequestInterestRay = actualAmountInRay - guaranteedAmountRay;
        require(
            withdrawalRequestInterestRay <= globalWithdrawableInterestRay,
            DepositsNotCovered(user, actualAmountInRay, guaranteedAmountRay + globalWithdrawableInterestRay)
        );

        if (!_isActiveSubVaultById(subVaultId)) {
            _removeSubVaultFromActive(subVaultId);
        }

        _mintIous(user, actualAmountInRay);

        emit WithdrawalRequestedWithShares(user, subVaultId, redeemedShares, actualAmountInRay, guaranteedAmountRay);
        return actualAmountInRay;
    }

    /// @inheritdoc IBasedBoostedVault
    function executeWithdrawal(address user, address assetOut, uint256 iouAmountRay) external override {
        require(msg.sender == user, InvalidMsgSender());
        require(
            IAssetRegistry(_assetRegistry).isAllowedToWithdrawFromBBV(assetOut), ErrorsLib.UnsupportedAsset(assetOut)
        );
        IIouTokenManager(IOU_TOKEN_MANAGER).burnTokens(user, iouAmountRay);
        uint256 assetAmount = iouAmountRay.rayToAssetDecimals(assetOut);
        IFundsHandler(FUNDS_HANDLER).processWithdrawal(assetOut, assetAmount);
        IERC20(assetOut).safeTransferFrom(FUNDS_HANDLER, user, assetAmount);
        emit WithdrawalExecuted(user, assetOut, assetAmount);
    }

    /// @inheritdoc IBasedBoostedVault
    function setDefaultSubVault(uint256 perSecondRate) external override restricted {
        _setDefaultSubVault(_getOrCreateSubVaultWithRate(perSecondRate), perSecondRate);
    }

    // TODO(registry-config): Should we have a "fee recipient" storage field or function param?
    /// @inheritdoc IBasedBoostedVault
    function claimFees(address[] calldata assets, uint256[] calldata amounts) external override restricted {
        uint256 vaultObligationsRay = _getVaultObligations();
        uint256 vaultAssetsRay = _getVaultAggregatedBalance();
        require(vaultObligationsRay <= vaultAssetsRay, InsufficientAssets());
        uint256 fee = vaultAssetsRay - vaultObligationsRay;
        uint256 accumulatedAmountRay;
        for (uint256 i = 0; i < assets.length; i++) {
            IFundsHandler(FUNDS_HANDLER).pullFromLiquidity(assets[i], amounts[i]);
            accumulatedAmountRay += amounts[i].assetDecimalsToRay(assets[i]);
            if (amounts[i] > 0) {
                IERC20(assets[i]).safeTransferFrom(FUNDS_HANDLER, msg.sender, amounts[i]);
            }
        }
        require(accumulatedAmountRay <= fee, ErrorsLib.InvalidAmount());
        emit FeesClaimed(assets, amounts);
    }

    /// @inheritdoc RescuableAssets
    function rescueTokens(address asset, uint256 amount) public override restricted {
        super.rescueTokens(asset, amount);
    }

    ////////////////////////////////////////////////// GETTERS /////////////////////////////////////////////////////

    /// @inheritdoc IBasedBoostedVault
    function getGlobalOriginalDepositAmount() external view override returns (uint256) {
        return _globalOriginalDepositsRay;
    }

    /// @inheritdoc IBasedBoostedVault
    function getActiveSubVaults() external view override returns (SubVaultData[] memory) {
        SubVaultData[] memory activeSubVaults = new SubVaultData[](_activeSubVaultsIds.length);
        for (uint256 i = 0; i < _activeSubVaultsIds.length; i++) {
            uint256 subVaultId = _activeSubVaultsIds[i];
            uint256 perSecondRate = _subVaultById[subVaultId].perSecondRate;
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
        if (_positions[user].shares == 0) {
            return 0;
        }
        return _positions[user].shares.rayMulDown(_previewSubVaultConversionRate(_positions[user].subVaultId));
    }

    /// @inheritdoc IBasedBoostedVault
    function getUserSubVault(address user) external view override returns (SubVaultData memory) {
        uint256 subVaultId = _positions[user].subVaultId;
        uint256 subVaultRate = _subVaultById[subVaultId].perSecondRate;
        return SubVaultData({perSecondRate: subVaultRate, id: subVaultId});
    }

    /// @inheritdoc IBasedBoostedVault
    function getDefaultSubVault() external view override returns (SubVaultData memory) {
        uint256 subVaultId = _defaultSubVaultId;
        uint256 subVaultRate = _subVaultById[subVaultId].perSecondRate;
        return SubVaultData({perSecondRate: subVaultRate, id: subVaultId});
    }

    /// @inheritdoc IBasedBoostedVault
    function getSubVaultRateById(uint256 subVaultId) external view override returns (uint256) {
        return _subVaultById[subVaultId].perSecondRate;
    }

    /// @inheritdoc IBasedBoostedVault
    function getSubVaultIdByRate(uint256 perSecondRate) external view override returns (uint256) {
        return _subVaultIdByRate[perSecondRate];
    }

    function getMaxValidPerSecondRate() external view returns (uint256) {
        return MAX_VALID_PER_SECOND_RATE;
    }

    ////////////////////////////////////////////////// INTERNAL /////////////////////////////////////////////////////

    function _validateRate(uint256 perSecondRate) internal view {
        require(perSecondRate >= MathLib.RAY && perSecondRate <= MAX_VALID_PER_SECOND_RATE, InvalidRate());
    }

    function _getOrCreateSubVaultWithRate(uint256 perSecondRate) internal returns (uint256) {
        if (_existsSubVaultWithRate(perSecondRate)) {
            return _subVaultIdByRate[perSecondRate];
        } else {
            return _createSubVault(perSecondRate);
        }
    }

    function _setDefaultSubVault(uint256 subVaultId, uint256 perSecondRate) internal {
        _defaultSubVaultId = subVaultId;
        emit DefaultSubVaultSet(subVaultId, perSecondRate);
    }

    function _createSubVault(uint256 newPerSecondRate) internal returns (uint256) {
        require(!_existsSubVaultWithRate(newPerSecondRate), SubVaultAlreadyExists());
        _validateRate(newPerSecondRate);
        uint256 newSubVaultId = ++_lastSubVaultId;
        _subVaultById[newSubVaultId] = SubVault({
            perSecondRate: newPerSecondRate,
            conversionRate: MathLib.RAY,
            lastAccrualTimestamp: uint256(block.timestamp),
            totalShares: 0
        });
        _subVaultIdByRate[newPerSecondRate] = newSubVaultId;
        emit SubVaultCreated(newSubVaultId, newPerSecondRate);
        return newSubVaultId;
    }

    function _migrateUserToSubVault(address user, uint256 oldSubVaultId, uint256 newSubVaultId) internal {
        _accrueSubVaultConversionRate(oldSubVaultId);
        _accrueSubVaultConversionRate(newSubVaultId);
        uint256 oldConversionRate = _subVaultById[oldSubVaultId].conversionRate;
        uint256 newConversionRate = _subVaultById[newSubVaultId].conversionRate;
        uint256 userOldShares = _positions[user].shares;
        uint256 userNewShares = userOldShares.rayMulDown(oldConversionRate).rayDivDown(newConversionRate);

        if (!_isActiveSubVaultById(newSubVaultId)) {
            _addSubVaultToActive(newSubVaultId);
        }

        _subVaultById[oldSubVaultId].totalShares -= userOldShares;
        _subVaultById[newSubVaultId].totalShares += userNewShares;

        _positions[user].shares = userNewShares;
        _positions[user].subVaultId = newSubVaultId;

        if (!_isActiveSubVaultById(oldSubVaultId)) {
            _removeSubVaultFromActive(oldSubVaultId);
        }
    }

    function _addSubVaultToActive(uint256 subVaultId) internal {
        _activeSubVaultsIds.push(subVaultId);
        _activeSubVaultIndexById[subVaultId] = _activeSubVaultsIds.length - 1;
    }

    // Assumes that if it is called then `subVaultId` is indeed active, thus `_activeSubVaultsIds.length > 0`
    function _removeSubVaultFromActive(uint256 subVaultId) internal {
        uint256 subVaultIndex = _activeSubVaultIndexById[subVaultId];
        uint256 lastSubVaultIndex = _activeSubVaultsIds.length - 1;
        if (subVaultIndex != lastSubVaultIndex) {
            uint256 lastSubVaultId = _activeSubVaultsIds[lastSubVaultIndex];
            _activeSubVaultsIds[subVaultIndex] = lastSubVaultId;
            _activeSubVaultIndexById[lastSubVaultId] = subVaultIndex;
        }
        _activeSubVaultsIds.pop();
        delete _activeSubVaultIndexById[subVaultId];
    }

    function _previewSubVaultConversionRate(uint256 subVaultId) internal view returns (uint256) {
        uint256 secondsSinceLastAccrual = block.timestamp - _subVaultById[subVaultId].lastAccrualTimestamp;
        uint256 newConversionRate = _subVaultById[subVaultId].conversionRate;
        if (secondsSinceLastAccrual != 0) {
            uint256 growthFactor = _subVaultById[subVaultId].perSecondRate.rpow(secondsSinceLastAccrual);
            newConversionRate = _subVaultById[subVaultId].conversionRate.rayMulDown(growthFactor);
        }
        return newConversionRate;
    }

    function _accrueSubVaultConversionRate(uint256 subVaultId) internal {
        _subVaultById[subVaultId].conversionRate = _previewSubVaultConversionRate(subVaultId);
        _subVaultById[subVaultId].lastAccrualTimestamp = block.timestamp;
    }

    function _fullWithdrawalRequest(address user) internal returns (uint256, uint256, uint256) {
        uint256 subVaultId = _positions[user].subVaultId;
        uint256 conversionRate = _subVaultById[subVaultId].conversionRate;

        uint256 sharesToRedeem = _positions[user].shares;
        uint256 actualAmountOfWithdrawalRay = sharesToRedeem.rayMulDown(conversionRate);
        require(actualAmountOfWithdrawalRay > 0, ErrorsLib.InsufficientAmountOut());
        // We don't check for sharesToRedeem > 0 here because we check for actualAmountInRay > 0 below.
        _burnShares(user, sharesToRedeem);
        uint256 originalDeposit = _positions[user].originalDepositRay;
        delete _positions[user];
        if (actualAmountOfWithdrawalRay < originalDeposit) {
            // We round it up because we guarantee originalDeposit
            // TODO: Write some tests to prove that, but this should be OK
            actualAmountOfWithdrawalRay = originalDeposit;
        }

        return (actualAmountOfWithdrawalRay, originalDeposit, sharesToRedeem);
    }

    function _partialWithdrawalRequest(address user, uint256 requestedAmountInRay)
        internal
        returns (uint256, uint256, uint256)
    {
        uint256 subVaultId = _positions[user].subVaultId;
        uint256 conversionRate = _subVaultById[subVaultId].conversionRate;

        uint256 sharesToRedeem = requestedAmountInRay.rayDivUp(conversionRate);
        require(sharesToRedeem <= _positions[user].shares, ErrorsLib.InvalidAmount());
        _burnShares(user, sharesToRedeem);
        uint256 amountTakenFromOriginalDepositRay = _decrementOriginalDeposit(user, requestedAmountInRay);

        if (_positions[user].shares == 0) {
            delete _positions[user];
        }

        return (requestedAmountInRay, amountTakenFromOriginalDepositRay, sharesToRedeem);
    }

    function _decrementOriginalDeposit(address user, uint256 actualAmountOfWithdrawal) internal returns (uint256) {
        uint256 amountTakenFromOriginalDepositRay;
        if (actualAmountOfWithdrawal >= _positions[user].originalDepositRay) {
            // The remaining portion of user's withdrawable balance is not guaranteed unless user deposits more funds.
            amountTakenFromOriginalDepositRay = _positions[user].originalDepositRay;
        } else {
            amountTakenFromOriginalDepositRay = actualAmountOfWithdrawal;
        }
        _positions[user].originalDepositRay -= amountTakenFromOriginalDepositRay;
        return amountTakenFromOriginalDepositRay;
    }

    function _burnShares(address user, uint256 shares) internal {
        uint256 subVaultId = _positions[user].subVaultId;
        _positions[user].shares -= shares;
        _subVaultById[subVaultId].totalShares -= shares;
    }

    function _getVaultObligations() internal view returns (uint256) {
        uint256 vaultObligations;
        for (uint256 i = 0; i < _activeSubVaultsIds.length; i++) {
            vaultObligations += _subVaultById[_activeSubVaultsIds[i]].totalShares
                .rayMulDown(_previewSubVaultConversionRate(_activeSubVaultsIds[i]));
        }
        return vaultObligations;
    }

    function _getVaultAggregatedBalance() internal view returns (uint256) {
        return IFundsHandler(FUNDS_HANDLER).getAggregatedBalance();
    }

    /// @return supply of all IOU tokens across all networks
    function _getIousInCirculation() internal view returns (uint256) {
        // TODO: Read internal storage of tokens bridged to other chains?
        // NO => because we will lock tokens when bridging
        // When the Earning chain exchanges IOUs for assets, it will send a message back to Accounting chain
        // Once Accounting chain receives this message the locked IOUs can be burned.
        // Total supply will decrease.
        return IERC20(IIouTokenManager(IOU_TOKEN_MANAGER).getAsset()).totalSupply();
    }

    function _mintIous(address user, uint256 amount) internal {
        IIouTokenManager(IOU_TOKEN_MANAGER).mintTokens(user, amount);
    }

    function _isActiveSubVaultById(uint256 subVaultId) internal view returns (bool) {
        return _subVaultById[subVaultId].totalShares > 0;
    }

    function _existsSubVaultWithRate(uint256 perSecondRate) internal view returns (bool) {
        return _subVaultIdByRate[perSecondRate] != 0;
    }

    function _existsSubVaultWithId(uint256 subVaultId) internal view returns (bool) {
        return subVaultId > 0 && subVaultId <= _lastSubVaultId;
    }

    function _setUserRate(address user, uint256 newPerSecondRate) internal {
        uint256 oldSubVaultId = _positions[user].subVaultId;
        require(oldSubVaultId > 0, NonExistentPosition());
        require(_subVaultById[oldSubVaultId].perSecondRate != newPerSecondRate, RedundantRate());

        uint256 newSubVaultId = _getOrCreateSubVaultWithRate(newPerSecondRate);

        _migrateUserToSubVault(user, oldSubVaultId, newSubVaultId);

        emit UserRateSet(user, newSubVaultId, newPerSecondRate);
    }
}

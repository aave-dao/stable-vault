// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBasedBoostedVault} from "../interfaces/IBasedBoostedVault.sol";
import {IFundsHandler} from "../interfaces/IFundsHandler.sol";
import {AssetLib} from "../libraries/AssetLib.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";
import {MathLib} from "../libraries/MathLib.sol";

/// @dev Assets balances are tracked in RAY internally; conversions from and to specific asset denomination is made on
/// deposit and on withdrawal execution.
contract BasedBoostedVault is Ownable, IBasedBoostedVault {
    using MathLib for uint256;
    using AssetLib for uint256;
    using SafeERC20 for IERC20;

    address internal _manager;

    modifier onlyManager() {
        require(msg.sender == _manager, ErrorsLib.NotManager());
        _;
    }

    uint256 internal constant SECONDS_PER_YEAR = 31_536_000;

    /**
     * @notice A subVault works like a virtual fixed-rate vault.
     *
     * @param perSecondRate The total per second rate of growth associated with the subVault.
     * @param conversionRate The cumulative growth factor at a point in time; acts as conversion rate between shares and
     * assets.
     * @param lastAccrualTimestamp The timestamp of the last accrual i.e. when the `conversionRate` was updated.
     * @param totalShares The total shares of the subVault outstanding.
     */
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

    IFundsHandler internal _fundsHandler;

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

    /// @dev Mapping to track supported assets.
    mapping(address asset => bool supported) internal _supportedAssets;

    /// @dev Constructor.
    /// @param owner The owner of the vault, acting as an admin.
    /// @param defaultSubVaultPerSecondRate The base per-second rate, in Ray units (27 decimals).
    constructor(address owner, uint256 defaultSubVaultPerSecondRate) Ownable(owner) {
        _setDefaultSubVault(_createSubVault(defaultSubVaultPerSecondRate));
    }

    /// @inheritdoc IBasedBoostedVault
    function deposit(address user, address asset, uint256 amount) external override {
        require(msg.sender == user, InvalidMsgSender());
        require(isAssetSupported(asset), ErrorsLib.UnsupportedAsset(asset));
        require(amount > 0, ErrorsLib.InvalidAmount());
        IERC20(asset).safeTransferFrom(msg.sender, address(_fundsHandler), amount);

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

        _fundsHandler.processDeposit(asset, amount);

        emit Deposit(user, asset, amount);
    }

    /// @inheritdoc IBasedBoostedVault
    function setUserRate(UserRateData[] calldata userRateData) external override onlyManager {
        for (uint256 i = 0; i < userRateData.length; i++) {
            _setUserRate(userRateData[i].user, userRateData[i].newPerSecondRate);
        }
    }

    /// @inheritdoc IBasedBoostedVault
    function changeSubVaultRate(uint256 subVaultId, uint256 newPerSecondRate) external onlyManager {
        require(newPerSecondRate >= MathLib.RAY, InvalidRate());
        require(!_existsSubVaultWithRate(newPerSecondRate), VaultAlreadyExists());
        _accrueSubVaultConversionRate(subVaultId);
        _subVaultById[subVaultId].perSecondRate = newPerSecondRate;
        _subVaultIdByRate[newPerSecondRate] = subVaultId;
        emit SubVaultRateUpdated(subVaultId, newPerSecondRate);
    }

    /// @inheritdoc IBasedBoostedVault
    function requestWithdrawal(address user, address preferredAsset, uint256 requestedAmountInRay, bytes calldata data)
        external
        override
        returns (uint256)
    {
        require(msg.sender == user, InvalidMsgSender());

        uint256 subVaultId = _positions[user].subVaultId;
        require(subVaultId > 0, NonExistentPosition());

        _accrueSubVaultConversionRate(subVaultId);

        uint256 conversionRate = _subVaultById[subVaultId].conversionRate;
        uint256 actualAmountInRay;
        uint256 guaranteedAmountRay;
        uint256 subVaultShares;

        if (requestedAmountInRay == 0) {
            // Withdraw full balance. user's shares > 0 check already performed at the beginning
            actualAmountInRay = _positions[user].shares.rayMulDown(conversionRate);

            // TODO: should we check actualAmountInRay > 0?
            guaranteedAmountRay = _positions[user].originalDepositRay;
            // FIXME: keeping + 2 here during development; we lose 2 units of assets when going from assets -> shares
            // (the loss is baked into the shares quantity which when multiplied with the same conversion rate leads to
            // 2 unit of asset loss).
            require(actualAmountInRay + 2 >= guaranteedAmountRay, "more than 2 unit of loss - investigate");
            if (actualAmountInRay < guaranteedAmountRay) {
                guaranteedAmountRay = actualAmountInRay;
            }
            subVaultShares = _positions[user].shares;
            _subVaultById[subVaultId].totalShares -= subVaultShares;
            delete _positions[user];
        } else {
            uint256 requestedAmountInShares = requestedAmountInRay.rayDivDown(conversionRate);
            require(requestedAmountInShares <= _positions[user].shares, ErrorsLib.InvalidAmount());
            // Subtract from the subVault & clear position
            _positions[user].shares -= requestedAmountInShares;
            _subVaultById[subVaultId].totalShares -= requestedAmountInShares;
            // TODO: Don't like the double conversion, but feel safer this way
            // TODO: This needs a mathematical proof that: requestedAmountInRay <= actualAmountInRay;
            actualAmountInRay = requestedAmountInShares.rayMulDown(conversionRate);
            // TODO: Probably there is a better way to do this:
            if (actualAmountInRay >= _positions[user].originalDepositRay) {
                guaranteedAmountRay = _positions[user].originalDepositRay;
                _positions[user].originalDepositRay = 0;
            } else {
                guaranteedAmountRay = actualAmountInRay;
                _positions[user].originalDepositRay -= actualAmountInRay;
            }
        }
        if (!_isActiveSubVaultById(subVaultId)) {
            _removeSubVaultFromActive(subVaultId);
        }
        uint256 withdrawalRequestId = _fundsHandler.processWithdrawalRequest({
            recipient: user,
            amountRay: actualAmountInRay,
            guaranteedAmountRay: guaranteedAmountRay,
            preferredAsset: preferredAsset,
            data: data
        });
        emit WithdrawalRequestedWithShares(
            user,
            preferredAsset,
            withdrawalRequestId,
            subVaultId,
            subVaultShares,
            actualAmountInRay,
            guaranteedAmountRay
        );
        return withdrawalRequestId;
    }

    /// @inheritdoc IBasedBoostedVault
    function executeWithdrawal(uint256 withdrawalRequestId) external override returns (address, uint256, bytes memory) {
        (address asset, uint256 amount, address user, bytes memory returnData) =
            _fundsHandler.processWithdrawalExecution(withdrawalRequestId);
        IERC20(asset).safeTransferFrom(address(_fundsHandler), user, amount);
        emit WithdrawalExecuted(user, withdrawalRequestId, asset, amount, returnData);
        return (asset, amount, returnData);
    }

    /// @inheritdoc IBasedBoostedVault
    function setDefaultSubVault(uint256 perSecondRate) external override onlyManager {
        _setDefaultSubVault(_getOrCreateSubVaultWithRate(perSecondRate));
    }

    /// @inheritdoc IBasedBoostedVault
    function setManager(address manager) external onlyOwner {
        require(manager != address(0), ErrorsLib.ZeroAddress());
        _manager = manager;
        emit ManagerSet(manager);
    }

    // TODO: Should we allow the admin to claim fees as well?
    // TODO(registry-config): Should we have a "fee recipient" storage field or function param?
    /// @inheritdoc IBasedBoostedVault
    function claimFees(address[] calldata assets, uint256[] calldata amounts) external onlyManager {
        uint256 vaultObligationsRay = _getVaultObligations();
        uint256 vaultAssetsRay = _getVaultAggregatedBalance();
        require(vaultObligationsRay <= vaultAssetsRay, InsufficientAssets());
        uint256 fee = vaultAssetsRay - vaultObligationsRay;
        uint256 accumulatedAmountRay;
        for (uint256 i = 0; i < assets.length; i++) {
            _fundsHandler.pullFromLiquidity(assets[i], amounts[i]);
            accumulatedAmountRay += amounts[i].assetDecimalsToRay(assets[i]);
            if (amounts[i] > 0) {
                IERC20(assets[i]).safeTransferFrom(address(_fundsHandler), msg.sender, amounts[i]);
            }
        }
        require(accumulatedAmountRay <= fee, ErrorsLib.InvalidAmount());
        emit FeesClaimed(assets, amounts);
    }

    /// @inheritdoc IBasedBoostedVault
    function updateAssetSupport(address asset, bool supported) external override onlyOwner {
        require(asset != address(0), ErrorsLib.UnsupportedAsset(asset));
        if (supported) {
            require(!_supportedAssets[asset], ErrorsLib.AssetAlreadySupported(asset));
            _supportedAssets[asset] = true;
        } else {
            require(_supportedAssets[asset], ErrorsLib.UnsupportedAsset(asset));
            delete _supportedAssets[asset];
        }
        emit AssetSupported(asset, supported);
    }

    function setFundsHandler(address fundsHandler) external onlyOwner {
        _fundsHandler = IFundsHandler(fundsHandler);
    }

    ///////////////////////////////////////////////// GETTERS /////////////////////////////////////////////////////

    /// @inheritdoc IBasedBoostedVault
    function getActiveSubVaults() external view override returns (SubVaultData[] memory) {
        SubVaultData[] memory activeSubVaults = new SubVaultData[](_activeSubVaultsIds.length);
        for (uint256 i = 0; i < _activeSubVaultsIds.length; i++) {
            uint256 subVaultId = _activeSubVaultsIds[i];
            uint256 perSecondRate = _subVaultById[subVaultId].perSecondRate;
            activeSubVaults[i] = SubVaultData(perSecondRate, subVaultId);
        }
        return activeSubVaults;
    }

    /// @inheritdoc IBasedBoostedVault
    function getVaultObligations() external view override returns (uint256) {
        return _getVaultObligations();
    }

    /// @inheritdoc IBasedBoostedVault
    function getVaultAssets() external view override returns (uint256) {
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
        return SubVaultData(subVaultRate, subVaultId);
    }

    /// @inheritdoc IBasedBoostedVault
    function getDefaultSubVault() external view override returns (SubVaultData memory) {
        uint256 subVaultId = _defaultSubVaultId;
        uint256 subVaultRate = _subVaultById[subVaultId].perSecondRate;
        return SubVaultData(subVaultRate, subVaultId);
    }

    /// @inheritdoc IBasedBoostedVault
    function getSubVaultRateById(uint256 subVaultId) external view override returns (uint256) {
        return _subVaultById[subVaultId].perSecondRate;
    }

    /// @inheritdoc IBasedBoostedVault
    function getSubVaultIdByRate(uint256 perSecondRate) external view override returns (uint256) {
        return _subVaultIdByRate[perSecondRate];
    }

    /// @inheritdoc IBasedBoostedVault
    function isAssetSupported(address asset) public view returns (bool) {
        return _supportedAssets[asset];
    }

    ///////////////////////////////////////////////// INTERNAL /////////////////////////////////////////////////////

    function _getOrCreateSubVaultWithRate(uint256 perSecondRate) internal returns (uint256) {
        if (_existsSubVaultWithRate(perSecondRate)) {
            return _subVaultIdByRate[perSecondRate];
        } else {
            return _createSubVault(perSecondRate);
        }
    }

    function _setDefaultSubVault(uint256 subVaultId) internal {
        _defaultSubVaultId = subVaultId;
        emit DefaultSubVaultSet(subVaultId);
    }

    function _createSubVault(uint256 newPerSecondRate) internal returns (uint256) {
        require(!_existsSubVaultWithRate(newPerSecondRate), VaultAlreadyExists());
        require(newPerSecondRate >= MathLib.RAY, InvalidRate());
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

    function _getVaultObligations() internal view returns (uint256) {
        uint256 vaultObligations;
        for (uint256 i = 0; i < _activeSubVaultsIds.length; i++) {
            vaultObligations += _subVaultById[_activeSubVaultsIds[i]].totalShares
                .rayMulDown(_previewSubVaultConversionRate(_activeSubVaultsIds[i]));
        }
        return vaultObligations;
    }

    function _getVaultAggregatedBalance() internal view returns (uint256) {
        return _fundsHandler.getAggregatedBalance();
    }

    function _isActiveSubVaultById(uint256 subVaultId) internal view returns (bool) {
        return _subVaultById[subVaultId].totalShares > 0;
    }

    function _existsSubVaultWithRate(uint256 perSecondRate) internal view returns (bool) {
        return _subVaultIdByRate[perSecondRate] != 0;
    }

    function _setUserRate(address user, uint256 newPerSecondRate) internal {
        uint256 oldSubVaultId = _positions[user].subVaultId;
        require(oldSubVaultId > 0, NonExistentPosition());
        require(_subVaultById[oldSubVaultId].perSecondRate != newPerSecondRate, RedundantRate());

        uint256 newSubVaultId = _getOrCreateSubVaultWithRate(newPerSecondRate);

        _migrateUserToSubVault(user, oldSubVaultId, newSubVaultId);

        emit UserRateUpdated(user, newPerSecondRate);
    }
}

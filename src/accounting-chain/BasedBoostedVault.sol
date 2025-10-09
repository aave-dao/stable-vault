// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {MathLib} from "../libraries/MathLib.sol";
import {AssetLib} from "../libraries/AssetLib.sol";
import {IBasedBoostedVault} from "./interfaces/IBasedBoostedVault.sol";
import {IFundsHandler} from "./interfaces/IFundsHandler.sol";

/// @dev Assets balances are tracked in RAY internally; conversions from and to specific asset denomination is made on deposit and on withdrawal confirmation
contract BasedBoostedVault is IBasedBoostedVault, Ownable {
    using MathLib for uint256;
    using AssetLib for uint256;
    using SafeERC20 for IERC20;

    uint256 internal constant SECONDS_PER_YEAR = 31_536_000;

    /**
     * @notice A subVault works like a virtual fixed-rate vault. The rate comes from the base rate with a multiplier boost
     * being applied to it.
     *
     * @param perSecondRate The per second rate boost applied to the base rate.
     * @param conversionRate The cumulative growth at perSecondRate which works as conversion rate between
     *  shares and assets.
     * @param lastAccrualTimestamp The timestamp of the last accrual i.e. when the `conversionRate` was updated.
     * @param totalShares The total shares of the subVault, scaled, normalized by `_baseConversionRate * subVault.conversionRate`.
     */
    struct SubVault {
        uint256 perSecondRate;
        uint256 conversionRate;
        uint256 lastAccrualTimestamp;
        uint256 totalShares;
    }

    /**
     * @notice The representation of an user's position. A single user will have at most 1 position.
     *
     * @param originalDeposit The amount deposited by the user before accruing any interest.
     * @param subVaultId The ID of the subVault where the user's assets are.
     * @param shares The shares of the user, scaled, normalized by `_baseConversionRate * subVault.conversionRate`.
     */
    struct UserPosition {
        uint256 originalDeposit;
        uint256 subVaultId;
        uint256 shares;
    }

    IFundsHandler internal _fundsHandler;

    // TODO: Idea, having the default subVault as an isolated special case, that cannot become active/inactive
    // SubVault internal _defaultSubVault;

    /**
     * @dev SubVaults that have liquidity i.e. some user's assets on it.
     */
    SubVault[] internal _activeSubVaults;

    /**
     * @dev The ID of the last subVault created.
     */
    uint256 internal _lastSubVaultId;

    /**
     * @dev SubVault index in the `_activeSubVaults` array by subVault boost per-second rate.
     */
    mapping(uint256 subVaultId => uint256 subVaultIndex) _subVaultIndexById;

    /**
     * @dev SubVault ID by subVault per-second rate.
     */
    mapping(uint256 subVaultRate => uint256 subVaultId) _subVaultIdByRate;

    /**
     * @dev User position by user address.
     */
    mapping(address user => UserPosition position) _positions;

    /**
     * @dev Mapping to track supported assets.
     */
    mapping(address asset => bool supported) _supportedAssets;

    /**
     * @dev Constructor.
     * @param owner The owner of the vault, acting as an admin.
     * @param defaultSubVaultPerSecondRate The base per-second rate, in Ray units (27 decimals).
     */
    constructor(address owner, uint256 defaultSubVaultPerSecondRate) Ownable(owner) {
        // Creates a subVault that gets ID #1 and that will be used as default subVault for new deposits
        _createSubVault(defaultSubVaultPerSecondRate);
    }

    function _createSubVault(uint256 newPerSecondRate) internal returns (uint256) {
        require(!_isActiveSubVaultByRate(newPerSecondRate), VaultAlreadyExists());
        _activeSubVaults.push(
            SubVault({
                perSecondRate: newPerSecondRate,
                conversionRate: MathLib.RAY,
                lastAccrualTimestamp: uint256(block.timestamp),
                totalShares: 0
            })
        );
        uint256 newSubVaultId = ++_lastSubVaultId;
        _subVaultIdByRate[newPerSecondRate] = newSubVaultId;
        _subVaultIndexById[newSubVaultId] = _activeSubVaults.length - 1;
        return newSubVaultId;
    }

    function changeSubVaultRate(uint256 subVaultId, uint256 newPerSecondRate) external onlyOwner {
        // TODO: do we have to check if subVaultId 1 and recreate the base vault if its inactive
        require(newPerSecondRate >= MathLib.RAY, InvalidRate());
        require(_isActiveSubVaultById(subVaultId), InactiveVault());
        require(_isActiveSubVaultByRate(newPerSecondRate) == false, VaultAlreadyExists());
        _accrueSubVaultConversionRate(_subVaultIndexById[subVaultId]);
        _activeSubVaults[_subVaultIndexById[subVaultId]].perSecondRate = newPerSecondRate;
        _subVaultIdByRate[newPerSecondRate] = subVaultId;
        emit SubVaultRateUpdated(subVaultId, newPerSecondRate);
    }

    function getActiveSubVaults() external view override returns (SubVaultData[] memory) {
        SubVaultData[] memory activeSubVaults = new SubVaultData[](_activeSubVaults.length);
        for (uint256 i = 0; i < _activeSubVaults.length; i++) {
            uint256 perSecondRate = _activeSubVaults[i].perSecondRate;
            activeSubVaults[i] = SubVaultData(perSecondRate, _subVaultIdByRate[perSecondRate]);
        }
        return activeSubVaults;
    }

    function _deleteSubVault(uint256 subVaultId) internal {
        require(_isActiveSubVaultById(subVaultId), InactiveVault());
        uint256 subVaultIndex = _subVaultIndexById[subVaultId];
        uint256 subVaultPerSecondRate = _activeSubVaults[subVaultIndex].perSecondRate;

        if (subVaultIndex == _activeSubVaults.length - 1) {
            _activeSubVaults.pop();
            delete _subVaultIndexById[subVaultId];
            delete _subVaultIdByRate[subVaultPerSecondRate];
        } else {
            SubVault storage moved = _activeSubVaults[_activeSubVaults.length - 1];
            uint256 movedSubVaultId = _subVaultIdByRate[moved.perSecondRate];
            _activeSubVaults[subVaultIndex] = moved;
            _subVaultIndexById[movedSubVaultId] = subVaultIndex;

            _activeSubVaults.pop();
            delete _subVaultIndexById[subVaultId];
            delete _subVaultIdByRate[subVaultPerSecondRate];
        }
    }

    function updateAssetSupport(address asset, bool supported) external onlyOwner {
        require(asset != address(0), InvalidAsset(asset));
        if (supported) {
            require(!_supportedAssets[asset], AssetAlreadySupported(asset));
            _supportedAssets[asset] = true;
        } else {
            require(_supportedAssets[asset], AssetNotSupported(asset));
            delete _supportedAssets[asset];
        }
        emit AssetSupported(asset, supported);
    }

    function isAssetSupported(address asset) public view returns (bool) {
        return _supportedAssets[asset];
    }

    function setUserRate(address user, uint256 newPerSecondRate) external override onlyOwner {
        require(newPerSecondRate >= MathLib.RAY, InvalidRate());
        uint256 userOldShares = _positions[user].shares;
        require(userOldShares > 0, NonExistentPosition());
        uint256 oldSubVaultIndex = _subVaultIndexById[_positions[user].subVaultId];
        require(_activeSubVaults[oldSubVaultIndex].perSecondRate != newPerSecondRate, RedundantRate());

        uint256 newSubVaultId;
        if (_isActiveSubVaultByRate(newPerSecondRate)) {
            newSubVaultId = _subVaultIdByRate[newPerSecondRate];
        } else {
            newSubVaultId = _createSubVault(newPerSecondRate);
        }

        _migrateUserToSubVault({
            user: user,
            userOldShares: userOldShares,
            newSubVaultId: newSubVaultId,
            oldSubVaultIndex: oldSubVaultIndex,
            newSubVaultIndex: _subVaultIndexById[newSubVaultId]
        });

        emit UserRateUpdated(user, newPerSecondRate);
    }

    function _migrateUserToSubVault(
        address user,
        uint256 userOldShares,
        uint256 newSubVaultId,
        uint256 oldSubVaultIndex,
        uint256 newSubVaultIndex
    ) internal {
        _accrueSubVaultConversionRate(oldSubVaultIndex);
        _accrueSubVaultConversionRate(newSubVaultIndex);
        uint256 oldConversionRate = _activeSubVaults[oldSubVaultIndex].conversionRate;
        uint256 newConversionRate = _activeSubVaults[newSubVaultIndex].conversionRate;

        uint256 userNewShares = userOldShares.rayMulDown(oldConversionRate).rayDivDown(newConversionRate);

        _activeSubVaults[oldSubVaultIndex].totalShares -= userOldShares;
        _activeSubVaults[newSubVaultIndex].totalShares += userNewShares;

        _positions[user].shares = userNewShares;
        _positions[user].subVaultId = newSubVaultId;
    }

    function deposit(address user, address asset, uint256 amount) external override {
        require(msg.sender == user, InvalidMsgSender());
        require(isAssetSupported(asset), UnsupportedAsset(asset));
        IERC20(asset).safeTransferFrom(msg.sender, address(_fundsHandler), amount);

        uint256 subVaultIndex;
        if (_positions[user].shares > 0) {
            subVaultIndex = _subVaultIndexById[_positions[user].subVaultId];
        } else {
            if (!_isActiveSubVaultById(1)) {
                // TODO: The default subVault could become inactive, we need to bring it back to active
            }
            subVaultIndex = _subVaultIndexById[1];
            _positions[user].subVaultId = subVaultIndex;
        }

        _accrueSubVaultConversionRate(subVaultIndex);

        uint256 conversionRate = _activeSubVaults[subVaultIndex].conversionRate;
        uint256 amountInRay = amount.assetDecimalsToRay(asset);
        uint256 shares = amountInRay.rayDivDown(conversionRate);

        _activeSubVaults[subVaultIndex].totalShares += shares;
        _positions[user].shares += shares;
        _positions[user].originalDeposit += amountInRay;

        _fundsHandler.processDeposit(user, asset, amount);

        emit Deposit(user, asset, amount);
    }

    /**
     * @notice Requests a withdrawal of assets from the vault.
     * @param user The address of the user requesting the withdrawal
     * @param preferredAsset The asset the withdrawal is requested in
     * @param requestedAmountInRay The amount of assets requested to withdraw (normalized to RAY units)
     */
    function requestWithdrawal(address user, address preferredAsset, uint256 requestedAmountInRay)
        external
        override
        returns (uint256)
    {
        require(msg.sender == user, InvalidMsgSender());
        require(_positions[user].shares > 0, NonExistentPosition());

        uint256 subVaultIndex = _subVaultIndexById[_positions[user].subVaultId];

        _accrueSubVaultConversionRate(subVaultIndex);

        uint256 conversionRate = _activeSubVaults[subVaultIndex].conversionRate;
        uint256 actualAmountInRay;
        uint256 guaranteedAmount;

        if (requestedAmountInRay == 0) {
            // Withdraw full balance. user's shares > 0 check already performed at the beginning
            actualAmountInRay = _positions[user].shares.rayMulDown(conversionRate);

            // TODO: should we check actualAmountInRay > 0?
            guaranteedAmount = _positions[user].originalDeposit;
            // FIXME: keeping + 2 here during development; we lose 2 units of assets when going from assets -> shares (the loss is baked into the shares quantity which when multiplied with the same conversion rate leads to 2 unit of asset loss).
            require(actualAmountInRay + 2 >= guaranteedAmount, "more than 2 unit of loss - investigate");
            if (actualAmountInRay < guaranteedAmount) {
                guaranteedAmount = actualAmountInRay;
            }
            delete _positions[user];
        } else {
            uint256 requestedAmountInShares = requestedAmountInRay.rayDivDown(conversionRate);
            require(requestedAmountInShares <= _positions[user].shares, InvalidAmount());
            // Subtract from the subVault & clear position
            _positions[user].shares -= requestedAmountInShares;
            _activeSubVaults[subVaultIndex].totalShares -= requestedAmountInShares;
            // TODO: Don't like the double conversion, but feel safer this way
            // TODO: This needs a mathematical proof that: requestedAmountInRay <= actualAmountInRay;
            actualAmountInRay = requestedAmountInShares.rayMulDown(conversionRate);
            _positions[user].shares -= requestedAmountInShares;
            // TODO: Probably there is a better way to do this:
            if (actualAmountInRay >= _positions[user].originalDeposit) {
                guaranteedAmount = _positions[user].originalDeposit;
                _positions[user].originalDeposit = 0;
            } else {
                guaranteedAmount = actualAmountInRay;
                _positions[user].originalDeposit -= actualAmountInRay;
            }
        }
        _activeSubVaults[subVaultIndex].totalShares -= _positions[user].shares;
        // TODO: Handle preferred asset properly
        uint256 withdrawalRequestId = _fundsHandler.processWithdrawalRequest({
            user: user,
            amount: actualAmountInRay,
            guaranteedAmount: guaranteedAmount,
            preferredAsset: preferredAsset,
            data: ""
        });
        emit WithdrawalRequested(user, preferredAsset, actualAmountInRay, guaranteedAmount);
        return withdrawalRequestId;
    }

    function executeWithdrawal(uint256 withdrawalRequestId, bytes calldata data)
        external
        override
        returns (uint256, bytes memory)
    {
        (uint256 amount, bytes memory returnData) = _fundsHandler.processWithdrawalExecution(withdrawalRequestId, data);
        emit WithdrawalExecuted(withdrawalRequestId, amount, returnData);
        return (amount, returnData);
    }

    function getVaultObligations() external view override returns (uint256) {
        return _getVaultObligations();
    }

    function _getVaultObligations() internal view returns (uint256) {
        uint256 vaultObligations;
        for (uint256 i = 0; i < _activeSubVaults.length; i++) {
            vaultObligations += _activeSubVaults[i].totalShares.rayMulDown(_previewSubVaultConversionRate(i));
        }
        return vaultObligations;
    }

    function getVaultAssets() external pure override returns (uint256) {
        // TODO: Implement by checking latest earning strategy balances
        return 0;
    }

    /// @dev returns underlying assets denomination in RAY decimal places
    function getUserBalance(address user) external view override returns (uint256) {
        if (_positions[user].shares == 0) {
            return 0;
        }
        uint256 subVaultIndex = _subVaultIndexById[_positions[user].subVaultId];
        return _positions[user].shares.rayMulDown(_previewSubVaultConversionRate(subVaultIndex));
    }

    function getUserSubVault(address user) external view override returns (SubVaultData memory) {
        uint256 subVaultId = _positions[user].subVaultId;
        uint256 subVaultRate = _activeSubVaults[_subVaultIndexById[subVaultId]].perSecondRate;
        return SubVaultData(subVaultRate, subVaultId);
    }

    function _previewSubVaultConversionRate(uint256 subVaultIndex) internal view returns (uint256) {
        uint256 secondsSinceLastAccrual = block.timestamp - _activeSubVaults[subVaultIndex].lastAccrualTimestamp;
        uint256 newConversionRate = _activeSubVaults[subVaultIndex].conversionRate;
        if (secondsSinceLastAccrual != 0) {
            uint256 growthFactor = _activeSubVaults[subVaultIndex].perSecondRate.rpow(secondsSinceLastAccrual);
            newConversionRate = _activeSubVaults[subVaultIndex].conversionRate.rayMulDown(growthFactor);
        }
        return newConversionRate;
    }

    function _accrueSubVaultConversionRate(uint256 subVaultIndex) internal {
        _activeSubVaults[subVaultIndex].conversionRate = _previewSubVaultConversionRate(subVaultIndex);
        _activeSubVaults[subVaultIndex].lastAccrualTimestamp = block.timestamp;
    }

    function _isActiveSubVaultById(uint256 subVaultId) internal view returns (bool) {
        return
            _subVaultIndexById[subVaultId] != 0 || (_activeSubVaults.length > 0 && _activeSubVaults[0].totalShares > 0);
    }

    function _isActiveSubVaultByRate(uint256 perSecondRate) internal view returns (bool) {
        return _subVaultIdByRate[perSecondRate] != 0;
    }
}

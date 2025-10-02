// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {MathLib} from "../libraries/MathLib.sol";
import {AssetLib} from "../libraries/AssetLib.sol";
import {IBasedBoostedVault} from "./interfaces/IBasedBoostedVault.sol";
import {IVaultFundsHandler} from "./interfaces/IVaultFundsHandler.sol";

/// @dev Assets balances are tracked in RAY internally; conversions from and to specific asset denomination is made on deposit and on withdrawal confirmation
contract BasedBoostedVault is IBasedBoostedVault, Ownable {
    using MathLib for uint256;
    using AssetLib for uint256;
    using SafeERC20 for IERC20;

    uint256 internal constant SECONDS_PER_YEAR = 365 days;

    event WithdrawalRequested(
        address indexed account, address indexed asset, uint256 requestedAmount, uint256 guaranteedAmount
    );
    event WithdrawalExecuted(uint256 indexed withdrawalRequestId, uint256 amount, bytes returnData);
    event Deposit(address indexed account, address indexed asset, uint256 amount);
    event BaseRateUpdated(uint256 baseRate);
    event BoostSet(address indexed account, uint256 boostRate);

    error InvalidRate();
    error InexistentPosition();
    error RedundantBoost();
    error InvalidMsgSender();
    error InvalidAmount();
    error UnsupportedAsset();

    /**
     * @notice A bucket works like a virtual fixed-rate vault. The rate comes from the base rate with a multiplier boost
     * being applied to it.
     *
     * @param perSecondRateBoost The per second rate boost applied to the base rate.
     * @param conversionRate The cumulative growth at perSecondRateBoost which works as conversion rate between
     *  shares and assets.
     * @param lastAccrualTimestamp The timestamp of the last accrual i.e. when the `conversionRate` was updated.
     * @param totalShares The total shares of the bucket, scaled, normalized by `_baseConversionRate * bucket.conversionRate`.
     */
    struct Bucket {
        uint256 perSecondRateBoost;
        uint256 conversionRate;
        uint256 lastAccrualTimestamp;
        uint256 totalShares;
    }

    /**
     * @notice The representation of an account's position. A single account will have at most 1 position.
     *
     * @param originalDeposit The amount deposited by the account before accruing any interest.
     * @param boostRate The `perSecondRateBoost` of the bucket where the account's assets are.
     * @param shares The shares of the account, scaled, normalized by `_baseConversionRate * bucket.conversionRate`.
     */
    struct AccountPosition {
        uint256 originalDeposit;
        uint256 boostRate;
        uint256 shares;
    }

    IVaultFundsHandler internal _fundsHandler;

    /**
     * @dev The base per second rate, the fixed rate that all accounts earn by default.
     */
    uint256 internal _basePerSecondRate;

    /**
     * @dev The cumulative growth at `_basePerSecondRate` which works as conversion rate between
     *  shares and assets.
     */
    uint256 internal _baseConversionRate;

    /**
     * @dev The timestamp of the last accrual of `_baseConversionRate`.
     */
    uint256 internal _lastBaseConversionRateAccrualTimestamp;

    /**
     * @dev Buckets that have liquidity i.e. some account's assets on it.
     */
    Bucket[] internal _activeBuckets;

    /**
     * @dev Bucket index in the `_activeBuckets` array by bucket boost per-second rate.
     */
    mapping(uint256 boostRate => uint256 bucketIndex) _bucketIndexByBoostRate;

    /**
     * @dev Account position by account address.
     */
    mapping(address account => AccountPosition position) _positions;

    /// TODO: Decide what to do and how to handle the invariant of _activeBuckets[0] == "no-boost" bucket. Some ideas:
    /// - Do it an edge case and do not remove from active buckets when shares get down to 0
    /// - Lock some initial deposit in the constructor so it can never reach 0 liquidity, then its fixed at 0 index
    /// - Do all generic code, do not assume the invariant, treat it as all the rest of the buckets
    ///      + In this case we need to check how to handle some edge cases, like the isActiveBucket function to be like:
    ///      + _activeBuckets[_bucketIndexByBoostRate[perSecondRateBoost]].perSecondRateBoost == perSecondRateBoost

    /**
     * @dev Constructor.
     * @param owner The owner of the vault, acting as an admin.
     * @param basePerSecondRate The base per-second rate, in Ray units (27 decimals).
     */
    constructor(address owner, uint256 basePerSecondRate) Ownable(owner) {
        // Initialize base conversion rate at 1
        _baseConversionRate = MathLib.RAY;
        // Base conversion rate was just accrued
        _lastBaseConversionRateAccrualTimestamp = uint256(block.timestamp);
        _setBasePerSecondRate(basePerSecondRate);

        // TODO: Do we need to accrue() the base conversion rate? I don't think so because it's the same timestamp

        // TODO: Do we need an initial "lock" deposit for the base rate bucket? research inflation attack

        // Create the default bucket which has no boost and just grows at the base rate
        _activeBuckets.push(
            Bucket({
                perSecondRateBoost: MathLib.RAY,
                conversionRate: MathLib.RAY,
                lastAccrualTimestamp: uint256(block.timestamp),
                totalShares: 0
            })
        );
        _bucketIndexByBoostRate[MathLib.RAY] = 0;
    }

    function setBasePerSecondRate(uint256 newBasePerSecondRate) external override onlyOwner {
        _accrueBaseConversionRate();
        _setBasePerSecondRate(newBasePerSecondRate);
    }

    function _setBasePerSecondRate(uint256 newBasePerSecondRate) internal {
        require(newBasePerSecondRate >= MathLib.RAY, InvalidRate());
        _basePerSecondRate = newBasePerSecondRate;
        emit BaseRateUpdated(newBasePerSecondRate);
    }

    function setBoost(address account, uint256 newPerSecondRateBoost) external override onlyOwner {
        uint256 accountOldShares = _positions[account].shares;
        require(accountOldShares > 0, InexistentPosition());

        uint256 oldBoostRate = _positions[account].boostRate;
        require(oldBoostRate != newPerSecondRateBoost, RedundantBoost());

        uint256 oldBucketIndex = _bucketIndexByBoostRate[oldBoostRate];

        _accrueBaseConversionRate();
        _accrueBucketConversionRate(oldBucketIndex);

        uint256 newBucketIndex;
        if (_isActiveBucket(newPerSecondRateBoost)) {
            newBucketIndex = _bucketIndexByBoostRate[newPerSecondRateBoost];
            _accrueBucketConversionRate(newBucketIndex);
        } else {
            // Create bucket and store it into the active buckets
            _activeBuckets.push(
                Bucket({
                    perSecondRateBoost: newPerSecondRateBoost,
                    conversionRate: MathLib.RAY,
                    lastAccrualTimestamp: uint256(block.timestamp),
                    totalShares: 0
                })
            );
            newBucketIndex = _activeBuckets.length - 1;
            _bucketIndexByBoostRate[newPerSecondRateBoost] = newBucketIndex;
        }

        uint256 oldBoostConversionRate = _activeBuckets[oldBucketIndex].conversionRate;
        uint256 newBoostConversionRate = _activeBuckets[newBucketIndex].conversionRate;

        uint256 accountNewShares =
            MathLib.rayMulDown(accountOldShares, MathLib.rayDivDown(oldBoostConversionRate, newBoostConversionRate));

        _activeBuckets[oldBucketIndex].totalShares -= accountOldShares;
        _activeBuckets[newBucketIndex].totalShares += accountNewShares;

        if (_activeBuckets[oldBucketIndex].totalShares == 0) {
            uint256 lastBucketIndex = _activeBuckets.length - 1;
            if (oldBucketIndex != lastBucketIndex) {
                Bucket memory moved = _activeBuckets[lastBucketIndex];
                _activeBuckets[oldBucketIndex] = moved;
                _bucketIndexByBoostRate[moved.perSecondRateBoost] = oldBucketIndex;
            }
            _activeBuckets.pop();
            delete _bucketIndexByBoostRate[oldBoostRate];
        }

        _positions[account].boostRate = newPerSecondRateBoost;
        _positions[account].shares = accountNewShares;

        emit BoostSet(account, newPerSecondRateBoost);
    }

    function deposit(address account, address asset, uint256 amount) external override {
        require(msg.sender == account, InvalidMsgSender());
        require(amount > 0, InvalidAmount());
        require(_isAssetSupported(asset), UnsupportedAsset());
        IERC20(asset).safeTransferFrom(msg.sender, address(_fundsHandler), amount);

        _accrueBaseConversionRate();

        // TODO: We assume the invariant of _activeBuckets[0] being the "no-boost" bucket
        // If account does not have any deposited assets yet, assign it to the "no-boost" base rate bucket
        uint256 bucketIndex;
        if (_positions[account].shares > 0) {
            bucketIndex = _bucketIndexByBoostRate[_positions[account].boostRate];
        } else {
            _positions[account].boostRate = MathLib.RAY;
        }

        _accrueBucketConversionRate(bucketIndex);

        uint256 conversionRate = _baseConversionRate.rayMulDown(_activeBuckets[bucketIndex].conversionRate);
        uint256 amountInRay = amount.assetDecimalsToRay(asset);
        uint256 shares = amountInRay.rayDivDown(conversionRate);

        _activeBuckets[bucketIndex].totalShares += shares;
        _positions[account].shares += shares;
        _positions[account].originalDeposit += amountInRay;

        _fundsHandler.processDeposit(account, asset, amount);

        emit Deposit(account, asset, amount);
    }

    /**
     * @notice Requests a withdrawal of assets from the vault.
     * @param account The address of the account requesting the withdrawal
     * @param preferredAsset The asset the withdrawal is requested in
     * @param requestedAmountInRay The amount of assets requested to withdraw (normalized to RAY units)
     */
    function requestWithdrawal(address account, address preferredAsset, uint256 requestedAmountInRay)
        external
        override
        returns (uint256)
    {
        require(msg.sender == account, InvalidMsgSender());
        require(_positions[account].shares > 0, InexistentPosition());

        uint256 bucketIndex = _bucketIndexByBoostRate[_positions[account].boostRate];

        _accrueBaseConversionRate();
        _accrueBucketConversionRate(bucketIndex);

        uint256 conversionRate = _baseConversionRate.rayMulDown(_activeBuckets[bucketIndex].conversionRate);
        uint256 actualAmountInRay;
        uint256 guaranteedAmount;

        if (requestedAmountInRay == 0) {
            // Withdraw full balance. Account's shares > 0 check already performed at the beginning
            actualAmountInRay = _positions[account].shares.rayMulDown(conversionRate);
            guaranteedAmount = _positions[account].originalDeposit;
            require(actualAmountInRay + 1 >= guaranteedAmount, "something went wrong - investigate"); // TODO: Remove this, but first try to find more test cases first
            if (actualAmountInRay < guaranteedAmount) {
                guaranteedAmount = actualAmountInRay;
            }
            delete _positions[account];
        } else {
            uint256 requestedAmountInShares = requestedAmountInRay.rayDivDown(conversionRate);
            require(requestedAmountInShares <= _positions[account].shares, InvalidAmount());
            // Subtract from the bucket & clear position
            _positions[account].shares -= requestedAmountInShares;
            _activeBuckets[bucketIndex].totalShares -= requestedAmountInShares;
            // TODO: Don't like the double conversion, but feel safer this way
            // TODO: This needs a mathematical proof that: requestedAmountInRay <= actualAmountInRay;
            actualAmountInRay = requestedAmountInShares.rayMulDown(conversionRate);
            _positions[account].shares -= requestedAmountInShares;
            // TODO: Probably there is a better way to do this:
            if (actualAmountInRay >= _positions[account].originalDeposit) {
                guaranteedAmount = _positions[account].originalDeposit;
                _positions[account].originalDeposit = 0;
            } else {
                guaranteedAmount = actualAmountInRay;
                _positions[account].originalDeposit -= actualAmountInRay;
            }
        }
        _activeBuckets[bucketIndex].totalShares -= _positions[account].shares;
        // TODO: Handle preferred asset properly
        uint256 withdrawalRequestId = _fundsHandler.processWithdrawalRequest({
            account: account,
            amount: actualAmountInRay,
            guaranteedAmount: guaranteedAmount,
            preferredAsset: preferredAsset,
            data: ""
        });
        emit WithdrawalRequested(account, preferredAsset, actualAmountInRay, guaranteedAmount);
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
        for (uint256 i = 0; i < _activeBuckets.length; i++) {
            // TODO: Implement
        }
        return 0;
    }

    function getVaultAssets() external pure override returns (uint256) {
        // TODO: Implement by checking latest earning strategy balances
        return 0;
    }

    function getAccountBalance(address account) external view override returns (uint256) {
        if (_positions[account].shares == 0) {
            return 0;
        }
        uint256 bucketIndex = _bucketIndexByBoostRate[_positions[account].boostRate];
        uint256 conversionRate = _previewBaseConversionRate().rayMulDown(_previewBucketConversionRate(bucketIndex));
        return _positions[account].shares.rayMulDown(conversionRate);
    }

    function getRateData(address account) external view returns (RateData memory) {
        Bucket memory bucket = _activeBuckets[_bucketIndexByBoostRate[_positions[account].boostRate]];
        return RateData({
            // TODO: need to return composite of base rate and boost rate
            perSecondRate: bucket.perSecondRateBoost,
            conversionRate: bucket.conversionRate,
            lastAccrualTimestamp: bucket.lastAccrualTimestamp
        });
    }

    function _isAssetSupported(address /* asset */ ) internal pure returns (bool) {
        // TODO: Implement whitelist for assets
        return true;
    }

    function _previewBaseConversionRate() internal view returns (uint256) {
        uint256 secondsSinceLastAccrual = block.timestamp - _lastBaseConversionRateAccrualTimestamp;
        uint256 newBaseConversionRate = _baseConversionRate;
        if (secondsSinceLastAccrual != 0) {
            uint256 growthFactor = _basePerSecondRate.rpow(secondsSinceLastAccrual);
            newBaseConversionRate = _baseConversionRate.rayMulDown(growthFactor);
        }
        return newBaseConversionRate;
    }

    function _previewBucketConversionRate(uint256 bucketIndex) internal view returns (uint256) {
        uint256 secondsSinceLastAccrual = block.timestamp - _activeBuckets[bucketIndex].lastAccrualTimestamp;
        uint256 newConversionRate = _activeBuckets[bucketIndex].conversionRate;
        if (secondsSinceLastAccrual != 0) {
            uint256 growthFactor = _activeBuckets[bucketIndex].perSecondRateBoost.rpow(secondsSinceLastAccrual);
            newConversionRate = _activeBuckets[bucketIndex].conversionRate.rayMulDown(growthFactor);
        }
        return newConversionRate;
    }

    function _accrueBaseConversionRate() internal {
        uint256 secondsSinceLastAccrual = block.timestamp - _lastBaseConversionRateAccrualTimestamp;
        if (secondsSinceLastAccrual != 0) {
            uint256 growthFactor = _basePerSecondRate.rpow(secondsSinceLastAccrual);
            _baseConversionRate = _baseConversionRate.rayMulDown(growthFactor);
            _lastBaseConversionRateAccrualTimestamp = block.timestamp;
        }
    }

    function _accrueBucketConversionRate(uint256 bucketIndex) internal {
        // TODO: Maybe if _activeBuckets[bucketIndex].perSecondRateBoost == 1 we skip the accrual?
        uint256 secondsSinceLastAccrual = block.timestamp - _activeBuckets[bucketIndex].lastAccrualTimestamp;
        if (secondsSinceLastAccrual != 0) {
            uint256 growthFactor = _activeBuckets[bucketIndex].perSecondRateBoost.rpow(secondsSinceLastAccrual);
            _activeBuckets[bucketIndex].conversionRate =
                _activeBuckets[bucketIndex].conversionRate.rayMulDown(growthFactor);
            _activeBuckets[bucketIndex].lastAccrualTimestamp = block.timestamp;
        }
    }

    function _isActiveBucket(uint256 perSecondRateBoost) internal view returns (bool) {
        return _bucketIndexByBoostRate[perSecondRateBoost] != 0
            || (_activeBuckets.length > 0 && _activeBuckets[0].perSecondRateBoost == perSecondRateBoost);
    }
}

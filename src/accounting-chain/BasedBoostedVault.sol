// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IBasedBoostedVault} from "./IBasedBoostedVault.sol";

contract BasedBoostedVault is IBasedBoostedVault, Ownable {
    using SafeERC20 for IERC20;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;

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

    /**
     * @dev Constructor.
     * @param owner The admin/manager of the vault.
     */
    constructor(address owner, uint256 basePerSecondRate) Ownable(owner) {
        // Initialize base conversion rate at 1
        _baseConversionRate = RAY;
        // Base conversion rate was just accrued
        _lastBaseConversionRateAccrualTimestamp = uint256(block.timestamp);

        require(basePerSecondRate >= RAY);
        _basePerSecondRate = basePerSecondRate;

        // TODO: Do we need to accrue() the base conversion rate? I don't think so because it's the same timestamp

        // TODO: Do we need an initial "lock" deposit for the base rate bucket? research inflation attack

        // Create the default bucket which has no boost and just grows at the base rate
        _activeBuckets.push(
            Bucket({
                perSecondRateBoost: RAY,
                conversionRate: RAY,
                lastAccrualTimestamp: uint256(block.timestamp),
                totalShares: 0
            })
        );
        _bucketIndexByBoostRate[RAY] = 0;
    }

    function setBasePerSecondRate(uint256 newBasePerSecondRate) external override onlyOwner {
        _accrueBaseConversionRate();
        _basePerSecondRate = newBasePerSecondRate;
        // TODO: event?
    }

    function setBoost(address account, uint256 newPerSecondRateBoost) external override onlyOwner {
        require(_positions[account].shares > 0);
        uint256 currentBoostRate = _positions[account].boostRate;
        require(currentBoostRate != newPerSecondRateBoost);

        _accrueBaseConversionRate();
        _accrueBucketConversionRate(currentBoostRate);

        if (_isActiveBucket(newPerSecondRateBoost)) {
            _accrueBucketConversionRate(newPerSecondRateBoost);
        } else {
            // Create bucket and store it into the active buckets
            _activeBuckets.push(
                Bucket({
                    perSecondRateBoost: newPerSecondRateBoost,
                    conversionRate: RAY,
                    lastAccrualTimestamp: uint256(block.timestamp),
                    totalShares: 0
                })
            );
            _bucketIndexByBoostRate[newPerSecondRateBoost] = _activeBuckets.length - 1;
        }

        // Calculate current account balance including the accrued interest
        uint256 currentTotalConversionRate = _rayMul(_baseConversionRate, currentBoostRate);
        uint256 accountBalance = _wadMulByRay(_positions[account].shares, currentTotalConversionRate);

        // Get account out of his current bucket
        uint256 currentBucketIndex = _bucketIndexByBoostRate[currentBoostRate];
        _activeBuckets[currentBucketIndex].totalShares -= _positions[account].shares;

        if (_activeBuckets[currentBucketIndex].totalShares == 0) {
            // No liquidity left in the bucket, remove it from the active ones through swapping with the last bucket
            _activeBuckets[currentBucketIndex] = _activeBuckets[_activeBuckets.length - 1];
            _activeBuckets.pop();
            delete _bucketIndexByBoostRate[currentBoostRate];
            _bucketIndexByBoostRate[_activeBuckets[currentBucketIndex].perSecondRateBoost] = currentBucketIndex;
        }

        // Put account in the new corresponding bucket
        uint256 newTotalConversionRate = _rayMul(_baseConversionRate, newPerSecondRateBoost);
        uint256 newShares = _wadDivByRay(accountBalance, newTotalConversionRate);
        _activeBuckets[_bucketIndexByBoostRate[newPerSecondRateBoost]].totalShares += newShares;
        _positions[account].boostRate = newPerSecondRateBoost;
        _positions[account].shares = newShares;
    }

    function deposit(address account, address asset, uint256 amount) external override {
        require(msg.sender == account);
    }

    function withdraw(address account, address asset, uint256 amount) external override {
        require(msg.sender == account);
    }

    function getTotalObligations() external view override returns (uint256) {
        // TODO: Implement
        return 0;
    }

    function getTotalAssets() external view override returns (uint256) {
        // TODO: Implement
        return 0;
    }

    function getBalance(address account) external view override returns (uint256) {
        // TODO: Implement
        return 0;
    }

    function getRateData(address account) external view returns (RateData memory) {
        Bucket memory bucket = _activeBuckets[_bucketIndexByBoostRate[_positions[account].boostRate]];
        return RateData({
            perSecondRate: bucket.perSecondRateBoost,
            conversionRate: bucket.conversionRate,
            lastAccrualTimestamp: bucket.lastAccrualTimestamp
        });
    }

    function _accrueBaseConversionRate() internal {
        uint256 secondsSinceLastAccrual = block.timestamp - _lastBaseConversionRateAccrualTimestamp;
        if (secondsSinceLastAccrual != 0) {
            uint256 growthFactor = _rpow(_basePerSecondRate, secondsSinceLastAccrual);
            _baseConversionRate = _rayMul(_baseConversionRate, growthFactor);
            _lastBaseConversionRateAccrualTimestamp = block.timestamp;
            // TODO: add accrual event
        }
    }

    function _accrueBucketConversionRate(uint256 bucketIndex) internal {
        uint256 secondsSinceLastAccrual = block.timestamp - _activeBuckets[bucketIndex].lastAccrualTimestamp;
        if (secondsSinceLastAccrual != 0) {
            uint256 growthFactor = _rpow(_activeBuckets[bucketIndex].perSecondRateBoost, secondsSinceLastAccrual);
            _activeBuckets[bucketIndex].conversionRate =
                _rayMul(_activeBuckets[bucketIndex].conversionRate, growthFactor);
            _activeBuckets[bucketIndex].lastAccrualTimestamp = block.timestamp;
            // TODO: add accrual event
        }
    }

    function _isActiveBucket(uint256 perSecondRateBoost) internal view returns (bool) {
        // TODO: Second part could maybe even be optimized to perSecondRateBoost == 1, if we assume the invariant of
        // the _activeBuckets[0] being always the "no-boost" bucket, which must hold...
        return _bucketIndexByBoostRate[perSecondRateBoost] != 0
            || _activeBuckets[0].perSecondRateBoost == perSecondRateBoost;
    }

    /////////////////////////////// MATH HELPERS ///////////////////////////////

    function _rayMul(uint256 a, uint256 b) internal pure returns (uint256) {
        unchecked {
            return (a * b + RAY / 2) / RAY; // bankers' rounding
        }
    }

    function _wadMulByRay(uint256 wadAmount, uint256 rayFactor) internal pure returns (uint256) {
        unchecked {
            return (wadAmount * rayFactor + RAY / 2) / RAY;
        }
    }

    function _wadDivByRay(uint256 wadAmount, uint256 rayDivisor) internal pure returns (uint256) {
        require(rayDivisor != 0, "DIV_BY_ZERO");
        unchecked {
            return (wadAmount * RAY + rayDivisor / 2) / rayDivisor;
        }
    }

    function _rpow(uint256 x, uint256 n) internal pure returns (uint256 z) {
        assembly {
            switch x
            case 0 {
                switch n
                case 0 { z := RAY }
                default { z := 0 }
            }
            default {
                switch mod(n, 2)
                case 0 { z := RAY }
                default { z := x }
                let half := div(RAY, 2)
                for { n := div(n, 2) } n { n := div(n, 2) } {
                    let xx := mul(x, x)
                    if iszero(eq(div(xx, x), x)) { revert(0, 0) }
                    let xxRound := add(xx, half)
                    if lt(xxRound, xx) { revert(0, 0) }
                    x := div(xxRound, RAY)
                    if mod(n, 2) {
                        let zx := mul(z, x)
                        if and(iszero(iszero(x)), iszero(eq(div(zx, x), z))) { revert(0, 0) }
                        let zxRound := add(zx, half)
                        if lt(zxRound, zx) { revert(0, 0) }
                        z := div(zxRound, RAY)
                    }
                }
            }
        }
    }
}

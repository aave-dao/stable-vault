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

    /// TODO: Decide what to do and how to handle the invariant of _activeBuckets[0] == "no-boost" bucket. Some ideas:
    /// - Do it an edge case and do not remove from active buckets when shares get down to 0
    /// - Lock some initial deposit in the constructor so it can never reach 0 liquidity, then its fixed at 0 index
    /// - Do all generic code, do not assume the invariant, treat it as all the rest of the buckets
    ///      + In this case we need to check how to handle some edge cases, like the isActiveBucket function to be like:
    ///      + _activeBuckets[_bucketIndexByBoostRate[perSecondRateBoost]].perSecondRateBoost == perSecondRateBoost

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

        uint256 currentBucketIndex = _bucketIndexByBoostRate[currentBoostRate];

        // Calculate current account balance including the accrued interest
        uint256 currentConversionRate = _rayMul(_baseConversionRate, _activeBuckets[currentBucketIndex].conversionRate);
        uint256 accountBalance = _wadMulByRay(_positions[account].shares, currentConversionRate);

        // Get account out of his current bucket
        _activeBuckets[currentBucketIndex].totalShares -= _positions[account].shares;

        if (_activeBuckets[currentBucketIndex].totalShares == 0) {
            // No liquidity left in the bucket, remove it from the active ones through swapping with the last bucket
            _activeBuckets[currentBucketIndex] = _activeBuckets[_activeBuckets.length - 1];
            _activeBuckets.pop();
            delete _bucketIndexByBoostRate[currentBoostRate];
            _bucketIndexByBoostRate[_activeBuckets[currentBucketIndex].perSecondRateBoost] = currentBucketIndex;
        }

        // Put account in the new corresponding bucket
        uint256 newConversionRate = _rayMul(_baseConversionRate, newPerSecondRateBoost);
        uint256 newShares = _wadDivByRay(accountBalance, newConversionRate);
        _activeBuckets[_bucketIndexByBoostRate[newPerSecondRateBoost]].totalShares += newShares;
        _positions[account].boostRate = newPerSecondRateBoost;
        _positions[account].shares = newShares;
    }

    function deposit(address account, address asset, uint256 amount) external override {
        require(msg.sender == account);
        require(amount > 0);
        require(_isAssetSupported(asset));

        _accrueBaseConversionRate();

        // TODO: We assume the invariant of _activeBuckets[0] being the "no-boost" bucket
        // If account does not have any deposited assets yet, assign it to the "no-boost" base rate bucket
        uint256 bucketIndex;
        if (_positions[account].shares > 0) {
            bucketIndex = _bucketIndexByBoostRate[_positions[account].boostRate];
        } else {
            _positions[account].boostRate = RAY;
        }

        _accrueBucketConversionRate(bucketIndex);

        uint256 conversionRate = _rayMul(_baseConversionRate, _activeBuckets[bucketIndex].conversionRate);
        uint256 shares = _wadDivByRay(amount, conversionRate);

        _activeBuckets[bucketIndex].totalShares += shares;
        _positions[account].shares += shares;

        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
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

    function _isAssetSupported(address asset) internal view returns (bool) {
        // TODO: Implement whitelist for assets
        return true;
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
        // TODO: Maybe if _activeBuckets[bucketIndex].perSecondRateBoost == 1 we skip the accrual?
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
        // TODO: We assume the invariant of _activeBuckets[0] == "no-boost" bucket
        return _bucketIndexByBoostRate[perSecondRateBoost] != 0 || perSecondRateBoost == RAY;
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

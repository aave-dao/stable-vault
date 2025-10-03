// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MathLib} from "../../src/libraries/MathLib.sol";
import {BasedBoostedVault} from "../../src/accounting-chain/BasedBoostedVault.sol";
import {IVaultFundsHandler} from "../../src/accounting-chain/interfaces/IVaultFundsHandler.sol";

contract ExtendedBasedBoostedVault is BasedBoostedVault {
    using MathLib for uint256;

    constructor(address owner, uint256 initialBasePerSecondRate, address[] memory initialSupportedAssets)
        BasedBoostedVault(owner, initialBasePerSecondRate, initialSupportedAssets)
    {}

    function getLastBaseConversionRateAccrualTimestamp() public view returns (uint256) {
        return _lastBaseConversionRateAccrualTimestamp;
    }

    function getBasePerSecondRate() public view returns (uint256) {
        return _basePerSecondRate;
    }

    function getBaseConversionRate() public view returns (uint256) {
        return _baseConversionRate;
    }

    /// @notice APR can be converted to APY/AEY given 365 compounding periods (similar to Spark)
    function getBaseApr() public view returns (uint256) {
        return (getBasePerSecondRate() - MathLib.RAY) * SECONDS_PER_YEAR;
    }

    function forceAccrueBaseConversionRate() public {
        _accrueBaseConversionRate();
    }

    function setFundsHandler(address fundsHandler) public {
        _fundsHandler = IVaultFundsHandler(fundsHandler);
    }

    function getBoostTotalApy(uint256 perSecondBoostMiltiplier) public view returns (uint256) {
        uint256 a = getBasePerSecondRate().rayMulDown(perSecondBoostMiltiplier);
        return a.rpow(SECONDS_PER_YEAR) - MathLib.RAY;
    }
}

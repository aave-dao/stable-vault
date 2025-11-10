// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {BasedBoostedVault} from "../../src/accounting/BasedBoostedVault.sol";
import {MathLib} from "../../src/libraries/MathLib.sol";

contract ExtendedBasedBoostedVault is BasedBoostedVault {
    using MathLib for uint256;

    constructor(uint256 maxPerSecondRate, address iouTokenManager, address fundsHandler, address transferHelper)
        BasedBoostedVault(maxPerSecondRate, iouTokenManager, fundsHandler, transferHelper)
    {}

    function getDefaultConversionRate() public view returns (uint256) {
        SubVault storage defaultVault = $BasedBoostedVault().subVaultById[$BasedBoostedVault().defaultSubVaultId];
        return defaultVault.conversionRate;
    }

    function getBaseApr() public view returns (uint256) {
        // The "default" subvault that has the effective base rate will always have id 1
        SubVault storage defaultVault = $BasedBoostedVault().subVaultById[$BasedBoostedVault().defaultSubVaultId];
        return (defaultVault.perSecondRate - MathLib.RAY) * SECONDS_PER_YEAR;
    }

    function forceAccrueSubVaultConversionRate() public {
        _accrueSubVaultConversionRate($BasedBoostedVault().defaultSubVaultId);
    }
}

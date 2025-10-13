// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {MathLib} from "../../src/libraries/MathLib.sol";
import {BasedBoostedVault} from "../../src/accounting/BasedBoostedVault.sol";
import {IFundsHandler} from "../../src/interfaces/IFundsHandler.sol";

contract ExtendedBasedBoostedVault is BasedBoostedVault {
    using MathLib for uint256;

    constructor(address owner, uint256 initialBasePerSecondRate) BasedBoostedVault(owner, initialBasePerSecondRate) {}

    function setFundsHandler(address fundsHandler) public {
        _fundsHandler = IFundsHandler(fundsHandler);
    }

    function getDefaultConversionRate() public view returns (uint256) {
        SubVault storage defaultVault = _activeSubVaults[_subVaultIndexById[1]];
        return defaultVault.conversionRate;
    }

    function getBaseApr() public view returns (uint256) {
        // The "default" subvault that has the effective base rate will always have id 1
        SubVault storage defaultVault = _activeSubVaults[_subVaultIndexById[1]];
        return (defaultVault.perSecondRate - MathLib.RAY) * SECONDS_PER_YEAR;
    }

    function forceAccrueSubVaultConversionRate() public {
        _accrueSubVaultConversionRate(_subVaultIndexById[1]);
    }
}

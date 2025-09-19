// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

interface IBasedBoostedVault {
    struct RateData {
        uint256 perSecondRate;
        uint256 conversionRate;
        uint256 lastAccrualTimestamp;
    }

    function setBasePerSecondRate(uint256 newBasePerSecondRate) external;

    function setBoost(address account, uint256 perSecondRateBoost) external;

    function deposit(address account, address asset, uint256 amount) external;

    function withdraw(address account, address asset, uint256 amount) external;

    function getTotalObligations() external view returns (uint256);

    function getTotalAssets() external view returns (uint256);

    function getBalance(address account) external view returns (uint256);

    // function emergencyWithdraw(address account, uint256 amount) external;

    function getRateData(address account) external view returns (RateData memory);
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IBasedBoostedVault {
    event WithdrawalRequested(
        address indexed account, address indexed asset, uint256 requestedAmount, uint256 guaranteedAmount
    );
    event WithdrawalExecuted(uint256 indexed withdrawalRequestId, uint256 amount, bytes returnData);
    event Deposit(address indexed account, address indexed asset, uint256 amount);
    event BaseRateUpdated(uint256 baseRate);
    event BoostSet(address indexed account, uint256 boostRate);
    event AssetSupported(address indexed asset, bool supported);

    error InvalidRate();
    error InexistentPosition();
    error RedundantBoost();
    error InvalidMsgSender();
    error InvalidAmount();
    error UnsupportedAsset(address asset);
    error InvalidAsset(address asset);
    error AssetAlreadySupported(address asset);
    error AssetNotSupported(address asset);

    struct RateData {
        uint256 perSecondRate;
        uint256 conversionRate;
        uint256 lastAccrualTimestamp;
    }

    function setBasePerSecondRate(uint256 newBasePerSecondRate) external;

    function setBoost(address account, uint256 perSecondRateBoost) external;

    function deposit(address account, address asset, uint256 amount) external;

    function requestWithdrawal(address account, address asset, uint256 amount) external returns (uint256);

    function executeWithdrawal(uint256 withdrawalRequestId, bytes calldata data)
        external
        returns (uint256, bytes memory);

    // function emergencyWithdraw(address account, uint256 amount) external;

    function getVaultObligations() external view returns (uint256);

    function getVaultAssets() external view returns (uint256);

    function getAccountBalance(address account) external view returns (uint256);

    function getRateData(address account) external view returns (RateData memory);

    function addSupportedAsset(address asset) external;

    function removeSupportedAsset(address asset) external;

    function isAssetSupported(address asset) external view returns (bool);
}

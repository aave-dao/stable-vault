// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IBasedBoostedVault {
    struct SubVaultData {
        uint256 perSecondRate;
        uint256 id;
    }

    // TODO: after initial testing we can fallbabck to using WithdrawalRequested
    //event WithdrawalRequested(address indexed user, address indexed asset, uint256 indexed withdrawalRequestId,
    // uint256 requestedAmount, uint256 guaranteedAmount);
    event WithdrawalRequestedWithShares(
        address indexed user,
        address indexed asset,
        uint256 indexed withdrawalRequestId,
        uint256 subVaultId,
        uint256 subVaultShares,
        uint256 requestedAmount,
        uint256 guaranteedAmount
    );
    event WithdrawalExecuted(
        address indexed user, uint256 indexed withdrawalRequestId, address asset, uint256 amount, bytes returnData
    );
    event Deposit(address indexed user, address indexed asset, uint256 amount);
    event UserRateUpdated(address indexed user, uint256 newRate);
    event SubVaultRateUpdated(uint256 indexed subVaultId, uint256 newRate);
    event SubVaultCreated(uint256 indexed subVaultId, uint256 perSecondRate);
    event DefaultSubVaultSet(uint256 indexed subVaultId);
    event AssetSupported(address indexed asset, bool supported);
    event ManagerSet(address manager);
    event FeesClaimed(address[] assets, uint256[] amounts);

    error InvalidRate();
    error NonExistentPosition();
    error RedundantRate();
    error InvalidMsgSender();
    error InvalidAmount();
    error UnsupportedAsset(address asset);
    error InvalidAsset(address asset);
    error AssetAlreadySupported(address asset);
    error AssetNotSupported(address asset);
    error VaultAlreadyExists();
    error InactiveVault();
    error InsufficientAssets();

    function setDefaultSubVault(uint256 perSecondRate) external;

    function changeSubVaultRate(uint256 subVaultId, uint256 newPerSecondRate) external;

    function getActiveSubVaults() external view returns (SubVaultData[] memory);

    function getUserSubVault(address user) external view returns (SubVaultData memory);

    function getDefaultSubVault() external view returns (SubVaultData memory);

    function getSubVaultRateById(uint256 subVaultId) external view returns (uint256);

    function getSubVaultIdByRate(uint256 perSecondRate) external view returns (uint256);

    function setUserRate(address user, uint256 perSecondRate) external;

    function deposit(address user, address asset, uint256 amount) external;

    function requestWithdrawal(address user, address asset, uint256 amount) external returns (uint256);

    function executeWithdrawal(uint256 withdrawalRequestId, bytes calldata data)
        external
        returns (address, uint256, bytes memory);

    function getVaultObligations() external view returns (uint256);

    function getVaultAssets() external view returns (uint256);

    function getUserBalance(address user) external view returns (uint256);

    function updateAssetSupport(address asset, bool supported) external;

    function isAssetSupported(address asset) external view returns (bool);
}

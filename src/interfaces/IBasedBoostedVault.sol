// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface IBasedBoostedVault {
    struct SubVaultData {
        uint256 perSecondRate;
        uint256 id;
    }

    struct UserRateData {
        address user;
        uint256 newPerSecondRate;
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
    error VaultAlreadyExists();
    error InactiveVault();
    error InsufficientAssets();

    function setDefaultSubVault(uint256 perSecondRate) external;

    function changeSubVaultRate(uint256 subVaultId, uint256 newPerSecondRate) external;

    function claimFees(address[] calldata assets, uint256[] calldata amounts) external;

    function setUserRate(UserRateData[] calldata userRateData) external;

    function setManager(address manager) external;

    /// @dev Updates the support status of an asset.
    /// @param asset Address of the asset.
    /// @param supported New support status of the asset.
    function updateAssetSupport(address asset, bool supported) external;

    function deposit(address user, address asset, uint256 amount) external;

    /// @notice Requests a withdrawal of assets from the vault.
    /// @dev User shares are burned; the amount requested to withdraw stops accruing yield.
    /// @param user The address of the user requesting the withdrawal
    /// @param preferredAsset The asset the withdrawal is requested in
    /// @param requestedAmountInRay The amount of assets requested to withdraw (normalized to RAY units)
    /// @param data Arbitrary data can be used to inform withdrawal execution behavior.
    function requestWithdrawal(address user, address preferredAsset, uint256 requestedAmountInRay, bytes calldata data)
        external
        returns (uint256);

    /// @notice Executes a previously requested withdrawal by pulling funds from the liquidity source and transferring
    /// them to the recipient.
    /// @dev The withdrawal request is deleted from storage after execution.
    /// @param withdrawalRequestId The id of the withdrawal request as is stored.
    function executeWithdrawal(uint256 withdrawalRequestId) external returns (address, uint256, bytes memory);

    /// @return Aggregated obligations to depositors in RAY of denomination asset.
    function getVaultObligations() external view returns (uint256);

    /// @return Aggregated amount of assets either idle or allocated to strategies in RAY of denomination asset.
    function getVaultAssets() external view returns (uint256);

    /// @return Balance of a user in RAY of denomination asset.
    function getUserBalance(address user) external view returns (uint256);

    /// @return Active subVaults.
    function getActiveSubVaults() external view returns (SubVaultData[] memory);

    /// @param user Address of the user.
    /// @return SubVaultData struct of vault.
    function getUserSubVault(address user) external view returns (SubVaultData memory);

    /// @param asset Address of the asset.
    /// @return Support status of the asset.
    function isAssetSupported(address asset) external view returns (bool);
}

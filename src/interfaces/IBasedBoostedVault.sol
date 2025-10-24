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
    // event WithdrawalRequested(address indexed user, address indexed asset, uint256 indexed withdrawalRequestId,
    // uint256 requestedAmount, uint256 guaranteedAmount);
    event WithdrawalRequestedWithShares(
        address indexed user,
        uint256 subVaultId,
        uint256 subVaultShares,
        uint256 requestedAmount,
        uint256 guaranteedAmount
    );
    event WithdrawalExecuted(address indexed user, address asset, uint256 amount);
    event Deposit(address indexed user, address indexed asset, uint256 amount);
    event UserRateUpdated(address indexed user, uint256 indexed subVaultId, uint256 newRate);
    event SubVaultRateUpdated(uint256 indexed subVaultId, uint256 newRate);
    event SubVaultCreated(uint256 indexed subVaultId, uint256 perSecondRate);
    event DefaultSubVaultSet(uint256 indexed subVaultId, uint256 perSecondRate);
    event ManagerSet(address manager);
    event FeesClaimed(address[] assets, uint256[] amounts);

    error InvalidRate();
    error NonExistentPosition();
    error RedundantRate();
    error InvalidMsgSender();
    error VaultAlreadyExists();
    error InactiveVault();
    error InsufficientAssets();
    error DepositsNotCovered(address withdrawalRequester, uint256 amountRequestedRay, uint256 amountAvailableRay);

    function setDefaultSubVault(uint256 perSecondRate) external;

    function changeSubVaultRate(uint256 subVaultId, uint256 newPerSecondRate) external;

    function claimFees(address[] calldata assets, uint256[] calldata amounts) external;

    function setUserRate(UserRateData[] calldata userRateData) external;

    function getDefaultSubVault() external view returns (SubVaultData memory);

    function getSubVaultRateById(uint256 subVaultId) external view returns (uint256);

    function getSubVaultIdByRate(uint256 perSecondRate) external view returns (uint256);

    /// @dev Sets the manager of the vault.
    /// @param manager Address of the manager.
    function setManager(address manager) external;

    /// @dev Deposits assets into the vault.
    /// @param user Address of the user depositing the assets.
    /// @param asset Address of the asset being deposited.
    /// @param amount Amount of assets being deposited.
    function deposit(address user, address asset, uint256 amount) external;

    /// @notice Requests a withdrawal of assets from the vault.
    /// @dev User shares are burned; the amount requested to withdraw stops accruing yield.
    /// @dev User is minted units of IOUs which can be used to claim assets.
    /// @param user The address of the user requesting the withdrawal
    /// @param requestedAmountInRay The amount of assets requested to withdraw (normalized to RAY units)
    /// @return amount of IOU tokens minted to the user
    function requestWithdrawal(address user, uint256 requestedAmountInRay) external returns (uint256);

    /// @notice Exchanges IOUs for a supported asset.
    /// @param user Address of the user executing the withdrawal.
    /// @param tokenOut Address of the token to withdraw.
    /// @param iouAmountRay Amount of the IOU tokens to exchange as part of the withdrawal execution.
    function executeWithdrawal(address user, address tokenOut, uint256 iouAmountRay) external;

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

    /// @return Value of global original deposit amount in RAY of denomination asset.
    function getGlobalOriginalDepositAmount() external view returns (uint256);
}

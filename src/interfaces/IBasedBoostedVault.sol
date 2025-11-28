// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

/// @title IBasedBoostedVault
/// @author Aave Labs
/// @notice Interface for the BasedBoostedVault.
interface IBasedBoostedVault {
    /// @notice The representation of a sub-vault.
    /// @param perSecondRate Per-second rate for the sub-vault.
    /// @param id ID of the sub-vault.
    struct SubVaultData {
        uint256 perSecondRate;
        uint256 id;
    }

    /// @notice The representation of a user's rate.
    /// @param user Address of the user.
    /// @param newPerSecondRate New per-second rate for the user.
    struct UserRateData {
        address user;
        uint256 newPerSecondRate;
    }

    event WithdrawalRequested(
        address indexed user,
        uint256 subVaultId,
        uint256 redeemedIouTokenAmountRay,
        uint256 guaranteedWithdrawableAmountRay
    );

    event WithdrawalExecuted(address indexed user, address asset, uint256 amount);

    event Deposit(address indexed user, address indexed asset, uint256 amount);

    event UserRateSet(address indexed user, uint256 indexed subVaultId, uint256 newPerSecondRate);

    event SubVaultRateSet(uint256 indexed subVaultId, uint256 newPerSecondRate);

    event SubVaultCreated(uint256 indexed subVaultId, uint256 perSecondRate);

    event DefaultSubVaultSet(uint256 indexed subVaultId, uint256 perSecondRate);

    event FeesClaimed(address[] assets, uint256[] amounts);

    /// @notice Thrown when the amount requested to withdraw is greater than the amount available.
    /// @dev It is possible the system does not have enough profits i.e. balances over 'original deposits' to cover a
    /// user's withdrawal request.
    /// @custom:selector 0xf9ff070e
    error InsufficientAssets(address user, uint256 amountRequestedRay, uint256 amountAvailableRay);

    /// @notice Thrown when checked rate is invalid i.e. is out of bounds.
    /// @custom:selector 0x6a43f8d1
    error InvalidRate();

    /// @notice Thrown when a position does not exist for a user.
    /// @custom:selector 0x6668308f
    error NonExistentPosition();

    /// @notice Thrown when there are no fees to claim.
    /// @custom:selector 0x846d8c5c
    error NoFeesToClaim();

    /// @notice Thrown when checked address is not the message sender.
    /// @custom:selector 0x9b3a19e9
    error OnlyUser();

    /// @notice Thrown when checked rate is already set.
    /// @custom:selector 0xb4a82df7
    error RedundantRate();

    /// @notice Thrown when a sub-vault already exists for a given rate.
    /// @custom:selector 0xdd81131b
    error SubVaultAlreadyExists();

    /// @notice Thrown when a sub-vault does not exist for a given id.
    /// @custom:selector 0xcac93e89
    error SubVaultDoesNotExist();

    /// @notice Sets the default sub-vault.
    /// @dev The default sub-vault is the sub-vault that is used when a depositing user does not have a specific
    /// sub-vault set.
    /// @param perSecondRate Per-second rate associated with the sub-vault to be set as the default
    /// sub-vault.
    function setDefaultSubVault(uint256 perSecondRate) external;

    /// @notice Sets the rate for a sub-vault.
    /// @param subVaultId ID of the existing sub-vault to set the rate for.
    /// @param newPerSecondRate New per-second rate for the sub-vault.
    function setSubVaultRate(uint256 subVaultId, uint256 newPerSecondRate) external;

    /// @notice Claims fees from the vault.
    /// @dev Funds requested are pulled from downstream components and transferred to the msg.sender.
    /// @param assets Assets to claim fees for.
    /// @param amounts Amounts of assets to claim fees for in their respective asset units.
    function claimFees(address[] calldata assets, uint256[] calldata amounts) external;

    /// @notice Sets the rate for a batch of users.
    /// @param userRateData Batch of user rates to set.
    /// @param userRateData.user Address of the user.
    /// @param userRateData.newPerSecondRate New per-second rate for the user.
    function setUserRate(UserRateData[] calldata userRateData) external;

    /// @notice Returns the default sub-vault data.
    function getDefaultSubVault() external view returns (SubVaultData memory);

    /// @notice Returns the maximum valid per-second rate that can be set for a sub-vault.
    function getMaxValidPerSecondRate() external view returns (uint256);

    /// @notice Returns the rate for a sub-vault.
    /// @param subVaultId ID of the sub-vault to return the rate for.
    function getSubVaultRateById(uint256 subVaultId) external view returns (uint256);

    /// @notice Returns the ID of a sub-vault for a given rate.
    /// @param perSecondRate Rate of the sub-vault to return the ID for.
    function getSubVaultIdByRate(uint256 perSecondRate) external view returns (uint256);

    /// @notice Deposits assets into the vault.
    /// @param user Address of the user depositing the assets.
    /// @param asset Address of the asset being deposited.
    /// @param amount Amount of assets being deposited.
    function deposit(address user, address asset, uint256 amount) external;

    /// @notice Requests a withdrawal of assets from the vault.
    /// @notice Returns the amount of IOU tokens minted to the user.
    /// @dev User shares are burned; the amount requested to withdraw stops accruing yield.
    /// @dev User is minted units of IOUs which can be used to claim assets.
    /// @param user The address of the user requesting the withdrawal
    /// @param requestedAmountInRay The amount of assets requested to withdraw (normalized to RAY units)
    function requestWithdrawal(address user, uint256 requestedAmountInRay) external returns (uint256);

    /// @notice Exchanges IOUs for a supported asset.
    /// @param user Address of the user executing the withdrawal.
    /// @param tokenOut Address of the token to withdraw.
    /// @param iouAmountRay Amount of the IOU tokens to exchange as part of the withdrawal execution.
    /// @param data Additional data for the withdrawal execution.
    function executeWithdrawal(address user, address tokenOut, uint256 iouAmountRay, bytes memory data) external;

    /// @notice Returns the aggregated obligations owned to depositors in RAY of denomination asset.
    function getVaultObligations() external view returns (uint256);

    /// @notice Returns the aggregated balance of the vault in RAY of denomination asset.
    function getAggregatedBalance() external view returns (uint256);

    /// @notice Returns the balance of a user in RAY of denomination asset.
    /// @param user Address of the user.
    function getUserBalance(address user) external view returns (uint256);

    /// @notice Returns the active sub-vaults.
    function getActiveSubVaults() external view returns (SubVaultData[] memory);

    /// @notice Returns the sub-vault data for a user.
    /// @param user Address of the user.
    function getUserSubVault(address user) external view returns (SubVaultData memory);

    /// @notice Returns the global original deposit amount in RAY of denomination asset.
    /// @dev Original deposits are the invested principal from users (not including accrued interest).
    function getGlobalOriginalDepositAmount() external view returns (uint256);
}

// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

/// @title IStableVault
/// @author Aave Labs
/// @notice Interface for the StableVault.
interface IStableVault {
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

    /// @notice Emitted on Stable Vault balance transfers (amount is denominated in RAY).
    event Transfer(address indexed from, address indexed to, uint256 amountRay);

    event UserRateSet(address indexed user, uint256 indexed subVaultId, uint256 newPerSecondRate);

    event SubVaultRateSet(uint256 indexed subVaultId, uint256 newPerSecondRate);

    event SubVaultCreated(uint256 indexed subVaultId, uint256 perSecondRate);

    event DefaultSubVaultSet(uint256 indexed subVaultId, uint256 perSecondRate);

    event SurplusInterestClaimed(address[] assets, uint256[] amounts);

    event TreasurySet(address indexed treasury);

    event SubVaultActivated(uint256 indexed subVaultId);

    event SubVaultDeactivated(uint256 indexed subVaultId);

    /// @notice Emitted when the deposit policy address is updated.
    event DepositPolicySet(address indexed oldPolicy, address indexed newPolicy);

    /// @notice Emitted when the withdrawal-request policy address is updated.
    event WithdrawalRequestPolicySet(address indexed oldPolicy, address indexed newPolicy);

    /// @notice Emitted when the transfer policy address is updated.
    event TransferPolicySet(address indexed oldPolicy, address indexed newPolicy);

    /// @notice Emitted when the surplus-claim policy address is updated.
    event SurplusClaimPolicySet(address indexed oldPolicy, address indexed newPolicy);

    /// @notice Emitted when the bridge policy address is updated.
    event BridgePolicySet(address indexed oldPolicy, address indexed newPolicy);

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

    /// @notice Thrown when checked address is not the message sender.
    /// @custom:selector 0x9b3a19e9
    error OnlyUser();

    /// @notice Thrown when the new rate equals the user's current rate.
    /// @custom:selector 0xa58adfa8
    error RedundantRate(address user, uint256 newPerSecondRate);

    /// @notice Thrown when a sub-vault already exists for a given rate.
    /// @custom:selector 0xdd81131b
    error SubVaultAlreadyExists();

    /// @notice Thrown when a sub-vault does not exist for a given id.
    /// @custom:selector 0xcac93e89
    error SubVaultDoesNotExist();

    /// @notice Thrown when the claimed surplus would render the vault insolvent.
    /// @custom:selector 0xca48b8ff
    error SurplusInterestClaimLeadsToInsolvency();

    /// @notice Thrown when the maximum number of active sub-vaults is reached.
    /// @custom:selector 0xff731b5f
    error TooManyActiveSubVaults();

    /// @notice Thrown when claiming surplus interest while the treasury address is set to address(0).
    /// @custom:selector 0xb2c4cce9
    error TreasuryNotSet();

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

    /// @notice Sets the treasury address, where claimed surplus interest is sent to.
    /// @param treasury Address of the treasury. If set to address(0), surplus interest claiming will revert.
    function setTreasury(address treasury) external;

    /// @notice Sets the deposit policy. `address(0)` disables the policy.
    function setDepositPolicy(address policy) external;

    /// @notice Sets the withdrawal-request policy. `address(0)` disables the policy.
    function setWithdrawalRequestPolicy(address policy) external;

    /// @notice Sets the transfer policy. `address(0)` disables the policy.
    function setTransferPolicy(address policy) external;

    /// @notice Sets the surplus-claim policy. `address(0)` disables the policy.
    function setSurplusClaimPolicy(address policy) external;

    /// @notice Sets the bridge policy. `address(0)` disables the policy.
    function setBridgePolicy(address policy) external;

    /// @notice Getter for the deposit policy address.
    function getDepositPolicy() external view returns (address);

    /// @notice Getter for the withdrawal-request policy address.
    function getWithdrawalRequestPolicy() external view returns (address);

    /// @notice Getter for the transfer policy address.
    function getTransferPolicy() external view returns (address);

    /// @notice Getter for the surplus-claim policy address.
    function getSurplusClaimPolicy() external view returns (address);

    /// @notice Getter for the bridge policy address.
    function getBridgePolicy() external view returns (address);

    /// @notice Claims surplus interest from the vault.
    /// @dev If funds requested can be covered by the system's surplus interest, the funds are pulled from downstream
    /// components and transferred to a Treasury address.
    /// @param assets Assets to claim surplus interest for.
    /// @param amounts Amounts of assets to claim surplus interest for in their respective asset units.
    function claimSurplusInterest(address[] calldata assets, uint256[] calldata amounts) external;

    /// @notice Sets the rate for a batch of users.
    /// @param userRateData Batch of user rates to set.
    function setUserRate(UserRateData[] calldata userRateData) external;

    /// @notice Getter for the default sub-vault.
    /// @return defaultSubVault Default sub-vault data.
    function getDefaultSubVault() external view returns (SubVaultData memory defaultSubVault);

    /// @notice Getter for the maximum rate that can be set for a sub-vault.
    /// @return maxValidPerSecondRate Maximum valid per-second rate that can be set for a sub-vault.
    function getMaxValidPerSecondRate() external view returns (uint256);

    /// @notice Getter for the treasury address.
    /// @return treasury The address of the treasury, where claimed surplus interest is sent to.
    function getTreasury() external view returns (address);

    /// @notice Getter for the rate for a sub-vault.
    /// @param subVaultId ID of the sub-vault to get the rate for.
    /// @return rate per-second rate of the sub-vault or 0 if the sub-vault does not exist.
    function getSubVaultRateById(uint256 subVaultId) external view returns (uint256);

    /// @notice Getter for the ID of a sub-vault for a given rate.
    /// @dev Only one sub-vault can have a given rate.
    /// @param perSecondRate Rate of the sub-vault to get the ID for.
    /// @return subVaultId ID of the sub-vault for the given rate or 0 if no sub-vault exists for the given rate.
    function getSubVaultIdByRate(uint256 perSecondRate) external view returns (uint256);

    /// @notice Deposits assets into the vault.
    /// @param user Address of the user depositing the assets.
    /// @param asset Address of the asset being deposited.
    /// @param amount Amount of assets being deposited.
    /// @param extraData Additional data for the deposit policy.
    function deposit(address user, address asset, uint256 amount, bytes calldata extraData) external;

    /// @notice Bridges IOU tokens to a destination chain.
    /// @param destinationChainId The chain id of the chain to publish the message to.
    /// @param iouTokenRecipient The address to send the IOU tokens to on the destination chain.
    /// @param iouTokenAmountRay The amount of IOU tokens to bridge.
    /// @param bridgeAdapter The whitelisted bridge adapter to use for the message.
    /// @param bridgeParamsEncoded Opaque bridge parameters blob consumed by the adapter.
    /// @param extraData Additional data for the bridge policy.
    function bridgeIouTokens(
        uint256 destinationChainId,
        address iouTokenRecipient,
        uint256 iouTokenAmountRay,
        address bridgeAdapter,
        bytes calldata bridgeParamsEncoded,
        bytes calldata extraData
    ) external payable;

    /// @notice ERC20-style total Stable Vault position supply in RAY.
    /// @dev Excludes IOU supply; includes only active Stable Vault position obligations.
    /// @return supplyRay Total Stable Vault position supply in RAY.
    function totalSupply() external view returns (uint256 supplyRay);

    /// @notice ERC20-style Stable Vault balance in RAY for a given account.
    /// @param account Address of the account.
    /// @return balanceRay Account's Stable Vault balance in RAY.
    function balanceOf(address account) external view returns (uint256 balanceRay);

    /// @notice ERC20-style name of the Stable Vault position token.
    /// @return name Human-readable name (e.g. "Aave USD Stable Vault").
    function name() external view returns (string memory);

    /// @notice ERC20-style symbol of the Stable Vault position token.
    /// @return symbol Short ticker (e.g. "ASV-USD").
    function symbol() external view returns (string memory);

    /// @notice ERC20-style decimals for the Stable Vault position token.
    /// @dev Exposing this lets explorers and wallets display balances with correct decimal alignment.
    /// @return decimals Number of decimals.
    function decimals() external pure returns (uint8);

    /// @notice Transfers Stable Vault balance (denominated in RAY) to another user.
    /// @param to Address of the recipient.
    /// @param amountRay Amount of Stable Vault balance to transfer, denominated in RAY.
    /// @return success True if the transfer was successful.
    function transfer(address to, uint256 amountRay) external returns (bool success);

    /// @notice Transfers Stable Vault balance (denominated in RAY) to another user, with policy data.
    /// @param to Address of the recipient.
    /// @param amountRay Amount of Stable Vault balance to transfer, denominated in RAY.
    /// @param extraData Additional data for the transfer policy.
    /// @return success True if the transfer was successful.
    function transfer(address to, uint256 amountRay, bytes calldata extraData) external returns (bool success);

    /// @notice Transfers the sender's full Stable Vault balance (denominated in RAY) to another user.
    /// @param to Address of the recipient.
    /// @param extraData Additional data for the transfer policy.
    /// @return success True if the transfer was successful.
    function transferAll(address to, bytes calldata extraData) external returns (bool success);

    /// @notice Requests a withdrawal of assets from the vault.
    /// @dev User shares are burned; the amount requested to withdraw stops accruing yield.
    /// @dev User is minted units of IOUs which can be used to claim assets.
    /// @param user The address of the user requesting the withdrawal
    /// @param requestedAmountInRay The amount of assets requested to withdraw (normalized to RAY units)
    /// @param extraData Additional data for the withdrawal-request policy.
    /// @return amountOfIouTokensMinted Amount of IOU tokens minted to the user.
    function requestWithdrawal(address user, uint256 requestedAmountInRay, bytes calldata extraData)
        external
        returns (uint256);

    /// @notice Exchanges IOUs for a supported asset.
    /// @param user Address of the user executing the withdrawal.
    /// @param assetOut Address of the asset to withdraw.
    /// @param minAmountOut Minimum amount of `assetOut` to receive in exchange of `iouAmountRay` IOUs.
    /// @param iouAmountRay Amount of the IOU tokens to exchange as part of the withdrawal execution.
    /// @param withdrawalPolicyData Additional data for the withdrawal policy.
    function executeWithdrawal(
        address user,
        address assetOut,
        uint256 minAmountOut,
        uint256 iouAmountRay,
        bytes memory withdrawalPolicyData
    ) external;

    /// @notice Getter for the aggregated obligations owed to depositors in RAY of the denominating currency.
    /// @dev Includes the total supply of IOU tokens across all chains (circulating + locked for bridging).
    /// @return obligations Aggregated obligations owed to depositors in RAY of the denominating currency.
    function getVaultObligations() external view returns (uint256);

    /// @notice Getter for the aggregated balance on the local Allocator and the Allocator on Earning Chains.
    /// @dev May underestimate when trust or freshness guarantees cannot be satisfied for a given contribution
    /// (conservative by design). See the implementation for specific policies.
    /// @return aggregatedBalance Aggregated balance of the vault in RAY of the denominating currency.
    function getAggregatedBalance() external view returns (uint256);

    /// @notice Getter for the balance of a user in RAY of the denominating currency including accrued interest.
    /// @param user Address of the user.
    /// @return balance Balance of the user in RAY of the denominating currency.
    function getUserBalance(address user) external view returns (uint256);

    /// @notice Getter for the sub-vaults that have user positions.
    /// @return activeSubVaults Array of active sub-vaults.
    function getActiveSubVaults() external view returns (SubVaultData[] memory);

    /// @notice Getter for the sub-vault data for a user.
    /// @param user Address of the user.
    /// @return subVaultData Sub-vault data for the user.
    function getUserSubVault(address user) external view returns (SubVaultData memory subVaultData);

    /// @notice Getter for the global original deposit amount in RAY of the denominating currency.
    /// @dev Original deposits are the invested principal from users (not including accrued interest).
    /// @return globalOriginalDepositAmount Global original deposit amount in RAY of the denominating currency.
    function getGlobalOriginalDepositAmount() external view returns (uint256 globalOriginalDepositAmount);

    /// @notice Getter for the surplus interest that can be claimed in RAY of the denominating currency.
    /// @dev Returns 0 if the system is underfunded (obligations >= assets).
    /// @return surplusInterestRay The claimable surplus in RAY.
    function getClaimableSurplusInterest() external view returns (uint256 surplusInterestRay);

    /// @notice Getter for the accrued conversion rate of a sub-vault, computed to the current block timestamp.
    /// @param subVaultId ID of the sub-vault.
    /// @return conversionRate The conversion rate in RAY, reflecting interest accrued up to now.
    function getSubVaultConversionRate(uint256 subVaultId) external view returns (uint256 conversionRate);
}

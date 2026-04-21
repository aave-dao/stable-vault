// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {
    AccessManagedUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/manager/AccessManagedUpgradeable.sol";
import {
    ReentrancyGuardTransientUpgradeable
} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardTransientUpgradeable.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IAssetRegistry} from "src/interfaces/IAssetRegistry.sol";
import {IFundsHandler} from "src/interfaces/IFundsHandler.sol";
import {IIouTokenManager} from "src/interfaces/IIouTokenManager.sol";
import {IPriceOracle} from "src/interfaces/IPriceOracle.sol";
import {IStableVault} from "src/interfaces/IStableVault.sol";
import {ITransferHelper} from "src/interfaces/ITransferHelper.sol";
import {IWithdrawalPolicy} from "src/interfaces/IWithdrawalPolicy.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {Multicall} from "src/misc/Multicall.sol";
import {RescuableNative} from "src/misc/RescuableNative.sol";
import {RescuableToken} from "src/misc/RescuableToken.sol";
import {TransferHelperClient} from "src/misc/TransferHelperClient.sol";
import {Constants} from "src/types/Constants.sol";
import {Errors} from "src/types/Errors.sol";

/// @title StableVault.
/// @author Aave Labs
/// @notice Semi-fixed rate vault.
/// @dev This contract supports batching of calls using the Multicall contract.
/// @dev Assets balances are tracked in RAY internally; conversions from and to specific asset denomination is made on
/// deposit and on withdrawal execution.
/// @custom:upgradeable
contract StableVault is
    AccessManagedUpgradeable,
    RescuableNative,
    RescuableToken,
    TransferHelperClient,
    Multicall,
    ReentrancyGuardTransientUpgradeable,
    IStableVault
{
    using MathLib for uint256;
    using AssetLib for uint256;
    using SafeERC20 for IERC20;

    /// @notice A subVault works like a virtual fixed-rate vault.
    /// @param perSecondRate The total per second rate of growth associated with the subVault.
    /// @param conversionRate The cumulative growth factor at a point in time; acts as conversion rate between shares
    /// and assets.
    /// @param lastAccrualTimestamp The timestamp of the last accrual i.e. when the `conversionRate` was updated.
    /// @param totalShares The total shares of the subVault outstanding.
    struct SubVault {
        uint256 perSecondRate;
        uint256 conversionRate;
        uint256 lastAccrualTimestamp;
        uint256 totalShares;
    }

    /// @notice The representation of a user's position. A single user will have at most 1 position.
    /// @param originalDepositRay The amount deposited by the user before accruing any interest.
    /// @param subVaultId The ID of the subVault where the user's assets are.
    /// @param shares The shares of the user, scaled, normalized by subVault conversionRate.
    struct UserPosition {
        uint256 originalDepositRay;
        uint256 subVaultId;
        uint256 shares;
    }

    address internal immutable ASSET_REGISTRY;

    address internal immutable IOU_TOKEN_MANAGER;

    uint256 internal immutable MAX_VALID_PER_SECOND_RATE;

    address internal immutable FUNDS_HANDLER;

    address internal immutable WITHDRAWAL_POLICY;

    address internal immutable PRICE_ORACLE;

    uint256 internal immutable MAX_ACTIVE_SUB_VAULTS;

    /// @custom:storage-location erc7201:aave.storage.StableVault
    struct StableVaultStorage {
        /// @dev Keeps track of the sum of all users' original deposits.
        /// @dev Does not overlap with circulating IOUs because original deposits are decremented when newly issued IOUs
        /// are minted.
        uint256 globalOriginalDepositsRay;

        /// @dev The ID of the last subVault created; monotonically increasing.
        uint256 lastSubVaultId;

        /// @dev The ID of the subVault where users without existing positions' deposits are allocated to.
        uint256 defaultSubVaultId;

        /// @dev Stores a SubVault by its ID.
        mapping(uint256 subVaultId => SubVault subVault) subVaultById;

        /// @dev The IDs of the SubVaults that have liquidity i.e. some user's assets on it.
        uint256[] activeSubVaultsIds;

        /// @dev SubVault index in the `activeSubVaultsIds` array.
        mapping(uint256 subVaultId => uint256 subVaultIndex) activeSubVaultIndexById;

        /// @dev SubVault ID by subVault per-second rate.
        mapping(uint256 subVaultRate => uint256 subVaultId) subVaultIdByRate;

        /// @dev User position by user address.
        mapping(address user => UserPosition position) positions;

        /// @dev The address of the treasury, where claimed surplus interest is sent to.
        address treasury;

        /// @dev ERC20-style name of the Stable Vault position token.
        string name;

        /// @dev ERC20-style symbol of the Stable Vault position token.
        string symbol;
    }

    // keccak256(abi.encode(uint256(keccak256("aave.storage.StableVault")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant STORAGE_SLOT_STABLE_VAULT =
        0x68b01cacb7d6669149a4ad1250da89e05e32d392d0489a11336faf07d474fb00;

    function $storage() private pure returns (StableVaultStorage storage _storage) {
        assembly {
            _storage.slot := STORAGE_SLOT_STABLE_VAULT
        }
    }

    function $StableVault() internal pure returns (StableVaultStorage storage) {
        return $storage();
    }

    /// @dev Constructor.
    /// @param maxValidPerSecondRate The maximum valid per-second rate, in Ray units (27 decimals).
    /// @param assetRegistry The address of the contract managing the allowed assets.
    /// @param iouTokenManager The address of the address that manages the supply of IOUs.
    /// @param fundsHandler The address of the contract that handles funds of the accounting chain.
    /// @param transferHelper The address of the contract that helps minimize the number of transfers across flows.
    /// @param withdrawalPolicy The address of the contract ensuring protocol's withdrawal requirements are met.
    /// @param priceOracle The address of the PriceOracle contract.
    /// @param maxActiveSubVaults The maximum number of active sub-vaults allowed.
    constructor(
        uint256 maxValidPerSecondRate,
        address assetRegistry,
        address iouTokenManager,
        address fundsHandler,
        address transferHelper,
        address withdrawalPolicy,
        address priceOracle,
        uint256 maxActiveSubVaults
    ) TransferHelperClient(transferHelper) {
        require(assetRegistry != address(0), Errors.ZeroAddress());
        require(iouTokenManager != address(0), Errors.ZeroAddress());
        require(fundsHandler != address(0), Errors.ZeroAddress());
        require(withdrawalPolicy != address(0), Errors.ZeroAddress());
        require(priceOracle != address(0), Errors.ZeroAddress());
        require(maxValidPerSecondRate > MathLib.RAY, InvalidRate());
        require(maxActiveSubVaults > 0, Errors.InvalidParameter());
        _disableInitializers();
        ASSET_REGISTRY = assetRegistry;
        IOU_TOKEN_MANAGER = iouTokenManager;
        FUNDS_HANDLER = fundsHandler;
        WITHDRAWAL_POLICY = withdrawalPolicy;
        PRICE_ORACLE = priceOracle;
        MAX_VALID_PER_SECOND_RATE = maxValidPerSecondRate;
        MAX_ACTIVE_SUB_VAULTS = maxActiveSubVaults;
    }

    /// @dev Initializer.
    /// @param accessManager Address of the IAccessManager contract used for handling access control.
    /// @param treasury Address of the treasury, where surplus interest is sent to.
    /// @param defaultSubVaultPerSecondRate Base per-second rate, in Ray units (27 decimals).
    /// @param name_ ERC20-style name of the Stable Vault position token (e.g. "Aave USD Stable Vault").
    /// @param symbol_ ERC20-style symbol of the Stable Vault position token (e.g. "ASV-USD").
    function initialize(
        address accessManager,
        address treasury,
        uint256 defaultSubVaultPerSecondRate,
        string memory name_,
        string memory symbol_
    ) external virtual initializer {
        __StableVault_init(accessManager, treasury, defaultSubVaultPerSecondRate, name_, symbol_);
    }

    function __StableVault_init(
        address accessManager,
        address treasury,
        uint256 defaultSubVaultPerSecondRate,
        string memory name_,
        string memory symbol_
    ) internal virtual onlyInitializing {
        // Empty name/symbol would render as blank in explorers and wallets — reject up front to catch deployment
        // mistakes early. ERC20 metadata is set once and immutable thereafter.
        require(bytes(name_).length > 0, Errors.InvalidParameter());
        require(bytes(symbol_).length > 0, Errors.InvalidParameter());
        IAccessManager(accessManager).canCall(address(0), address(0), bytes4(0));
        __AccessManaged_init(accessManager);
        _setTreasury(treasury);
        _setDefaultSubVault(_getOrCreateSubVaultWithRate(defaultSubVaultPerSecondRate), defaultSubVaultPerSecondRate);
        $storage().name = name_;
        $storage().symbol = symbol_;
    }

    /// @inheritdoc IStableVault
    function deposit(address user, address asset, uint256 amount)
        external
        virtual
        override
        nonReentrant
        assertingTransferHelperBalanceFor(asset)
    {
        require(IAssetRegistry(ASSET_REGISTRY).isUserDepositAllowed(asset), Errors.UnsupportedAsset(asset));
        require(amount > 0, Errors.InvalidAmount());

        IPriceOracle(PRICE_ORACLE).validatePrice(asset);

        uint256 subVaultId = $storage().positions[user].subVaultId;
        if (subVaultId == 0) {
            subVaultId = $storage().defaultSubVaultId;
            $storage().positions[user].subVaultId = subVaultId;
        }

        uint256 conversionRate = _accrueSubVaultConversionRate(subVaultId);

        if (!_isActiveSubVaultById(subVaultId)) {
            _addSubVaultToActive(subVaultId);
            _validateAmountOfActiveSubVaults();
        }

        _transferToTransferHelper(msg.sender, asset, amount);
        uint256 netDepositAmount = IFundsHandler(FUNDS_HANDLER).processDeposit(asset, amount);

        // Calculate the number of shares to mint based on the full amount deposited.
        // If (amount - netDepositAmount) > 0, then this ~amount will be treated as interest earned.
        // Round down the division to undershoot the amount of granted shares, favoring the protocol.
        uint256 shares = amount.assetDecimalsToRay(asset).rayDivDown(conversionRate);
        // Prevent deposits that result in 0 shares to avoid user getting nothing in return for their deposit.
        require(shares > 0, Errors.InvalidAmount());

        _issueShares(user, subVaultId, shares);
        // Increment the original deposit amount by the net deposit amount only, not the full amount.
        // This protects against the system guaranteeing the full amount of the asset deposited in the case an
        // underlying strategy suffers slippage.
        uint256 netDepositAmountInRay = netDepositAmount.assetDecimalsToRay(asset);
        $storage().positions[user].originalDepositRay += netDepositAmountInRay;
        $storage().globalOriginalDepositsRay += netDepositAmountInRay;

        emit Deposit(user, asset, amount);
        emit Transfer(address(0), user, amount.assetDecimalsToRay(asset));
    }

    /// @notice Transfers Stable Vault balance (denominated in RAY) between users.
    /// @dev This is accounting-only (no IOUs, no assets, no WithdrawalPolicy).
    /// @dev For full balance transfers, use transferAll() instead.
    /// @dev Reverts if the remaining sender balance after transfer would be below dust threshold.
    /// @dev The sender's principal (`originalDepositRay`) is decremented by up to `amountRay` and the same principal
    /// amount is moved to the recipient. This is a simplified accounting-only operation that bypasses withdrawal fees,
    /// oracle checks, solvency gating, and slippage.
    /// @dev Principal is tracked as one aggregate balance per user (not by deposit lots), so transfers always consume
    /// from that aggregate principal balance.
    function transfer(address to, uint256 amountRay) external virtual override nonReentrant returns (bool) {
        address from = msg.sender;
        require(amountRay >= Constants.MIN_WITHDRAWABLE_AMOUNT_RAY, Errors.InvalidAmount());
        require(to != address(0), Errors.InvalidParameter());
        require(to != from, Errors.InvalidParameter());

        uint256 fromSubVaultId = $storage().positions[from].subVaultId;
        require(fromSubVaultId != 0, NonExistentPosition());

        uint256 fromConversionRate = _accrueSubVaultConversionRate(fromSubVaultId);

        (uint256 guaranteedAmountRay, uint256 fromUserShares) =
            _computeTransferShares(from, amountRay, fromSubVaultId, fromConversionRate);

        uint256 toSubVaultId = _getOrAssignUserSubVaultId(to);

        uint256 toUserShares;
        if (toSubVaultId == fromSubVaultId) {
            toUserShares = fromUserShares;
        } else {
            uint256 toConversionRate = _accrueSubVaultConversionRate(toSubVaultId);
            toUserShares = amountRay.rayDivDown(toConversionRate);
        }
        require(toUserShares > 0, Errors.InvalidAmount());

        _moveShares({
            from: from,
            to: to,
            fromSubVaultId: fromSubVaultId,
            toSubVaultId: toSubVaultId,
            sharesToBurn: fromUserShares,
            sharesToIssue: toUserShares,
            guaranteedAmountToMoveRay: guaranteedAmountRay
        });

        emit Transfer(from, to, amountRay);
        return true;
    }

    /// @notice Transfers the sender's full position to another user.
    /// @dev Any remaining original deposit amount is also transferred to the recipient.
    function transferAll(address to) external virtual override nonReentrant returns (bool) {
        address from = msg.sender;
        require(to != address(0), Errors.InvalidParameter());
        require(to != from, Errors.InvalidParameter());

        uint256 fromSubVaultId = $storage().positions[from].subVaultId;
        require(fromSubVaultId != 0, NonExistentPosition());

        uint256 fromConversionRate = _accrueSubVaultConversionRate(fromSubVaultId);

        (uint256 amountOfWithdrawalRay, uint256 guaranteedAmountRay, uint256 fromUserShares) =
            _previewFullWithdrawalRequest(from);

        uint256 toSubVaultId = _getOrAssignUserSubVaultId(to);

        uint256 toUserShares;
        if (toSubVaultId == fromSubVaultId) {
            toUserShares = fromUserShares;
        } else {
            uint256 toConversionRate = _accrueSubVaultConversionRate(toSubVaultId);
            toUserShares = fromUserShares.rayMulDown(fromConversionRate).rayDivDown(toConversionRate);
        }
        require(toUserShares > 0, Errors.InvalidAmount());

        _moveShares({
            from: from,
            to: to,
            fromSubVaultId: fromSubVaultId,
            toSubVaultId: toSubVaultId,
            sharesToBurn: fromUserShares,
            sharesToIssue: toUserShares,
            guaranteedAmountToMoveRay: guaranteedAmountRay
        });

        emit Transfer(from, to, amountOfWithdrawalRay);
        return true;
    }

    /// @inheritdoc IStableVault
    function setUserRate(UserRateData[] calldata userRateData) external override restricted {
        for (uint256 i = 0; i < userRateData.length; i++) {
            _setUserRate(userRateData[i].user, userRateData[i].newPerSecondRate);
        }
    }

    /// @inheritdoc IStableVault
    function setSubVaultRate(uint256 subVaultId, uint256 newPerSecondRate) external override restricted {
        _validateRate(newPerSecondRate);
        require(!_existsSubVaultWithRate(newPerSecondRate), SubVaultAlreadyExists());
        uint256 oldPerSecondRate = $storage().subVaultById[subVaultId].perSecondRate;
        require(oldPerSecondRate != 0, SubVaultDoesNotExist());
        _accrueSubVaultConversionRate(subVaultId);
        delete $storage().subVaultIdByRate[oldPerSecondRate];
        $storage().subVaultById[subVaultId].perSecondRate = newPerSecondRate;
        $storage().subVaultIdByRate[newPerSecondRate] = subVaultId;
        emit SubVaultRateSet(subVaultId, newPerSecondRate);
        if ($storage().defaultSubVaultId == subVaultId) {
            emit DefaultSubVaultSet(subVaultId, newPerSecondRate);
        }
    }

    /// @inheritdoc IStableVault
    function requestWithdrawal(address user, uint256 requestedAmountInRay)
        external
        virtual
        override
        nonReentrant
        returns (uint256)
    {
        require(user == msg.sender, OnlyUser());

        uint256 subVaultId = $storage().positions[user].subVaultId;
        require(subVaultId > 0, NonExistentPosition());

        _accrueSubVaultConversionRate(subVaultId);

        uint256 actualAmountInRay;
        uint256 guaranteedAmountRay;
        uint256 redeemedShares;

        if (requestedAmountInRay == 0) {
            (actualAmountInRay, guaranteedAmountRay, redeemedShares) = _previewFullWithdrawalRequest(user);
        } else {
            (actualAmountInRay, guaranteedAmountRay, redeemedShares) =
                _previewPartialWithdrawalRequest(user, requestedAmountInRay);
            // If the remaining shares are not redeemable for at least 1 wei of 18-decimal asset,
            // perform a full withdrawal instead, avoiding leaving non-redeemable dust shares.
            if (!_areRemainingSharesRedeemable(user, redeemedShares, subVaultId)) {
                (actualAmountInRay, guaranteedAmountRay, redeemedShares) = _previewFullWithdrawalRequest(user);
            }
        }

        uint256 remainingShares = _burnShares(user, subVaultId, redeemedShares);
        if (remainingShares == 0) {
            delete $storage().positions[user];
        } else {
            $storage().positions[user].originalDepositRay -= guaranteedAmountRay;
        }

        // Assets in Allocator + last snapshot updates from Earning chains
        uint256 totalAssetsRay = _getVaultAggregatedBalance();
        // There is no overlap between original deposits and circulating IOUs because original deposits are decremented
        // when new issue IOUs are minted.
        uint256 guaranteedObligationsRay = _getIousInCirculation() + $storage().globalOriginalDepositsRay;
        uint256 globalWithdrawableInterestRay =
            totalAssetsRay > guaranteedObligationsRay ? totalAssetsRay - guaranteedObligationsRay : 0;
        uint256 withdrawalRequestInterestRay = actualAmountInRay - guaranteedAmountRay;
        require(
            withdrawalRequestInterestRay <= globalWithdrawableInterestRay,
            InsufficientAssets(user, actualAmountInRay, guaranteedAmountRay + globalWithdrawableInterestRay)
        );

        $storage().globalOriginalDepositsRay -= guaranteedAmountRay;

        if (!_isActiveSubVaultById(subVaultId)) {
            _removeSubVaultFromActive(subVaultId);
        }

        _mintIous(user, actualAmountInRay);

        emit WithdrawalRequested(user, subVaultId, actualAmountInRay, guaranteedAmountRay);
        emit Transfer(user, address(0), actualAmountInRay);
        return actualAmountInRay;
    }

    /// @inheritdoc IStableVault
    function executeWithdrawal(
        address user,
        address assetOut,
        uint256 minAmountOut,
        uint256 iouAmountRay,
        bytes memory data
    ) external virtual override nonReentrant assertingTransferHelperBalanceFor(assetOut) {
        require(user == msg.sender, OnlyUser());
        IIouTokenManager(IOU_TOKEN_MANAGER).burnTokens(user, iouAmountRay);
        uint256 amountOutRay = IWithdrawalPolicy(WITHDRAWAL_POLICY)
            .applyWithdrawalPolicy(
                IWithdrawalPolicy.WithdrawalRequest({
                    user: user, assetOut: assetOut, iouAmountRay: iouAmountRay, data: data
                })
            );
        // Note: The `rayToAssetDecimals` conversion truncates, so the user may burn slightly more IOUs than the
        // exact RAY-equivalent of the assets received. This "dust" loss is at most `10 ^ (27 - assetDecimals) - 1` RAY
        // per withdrawal, which is economically negligible (e.g., <$0.000001 for 6-decimal stablecoins; it would take
        // >1,000,000 withdrawals to accumulate $1 of loss). The gas cost of preventing this (~1,600 gas for an extra
        // conversion) exceeds the value of the dust, so we accept this minor rounding in favor of the protocol.
        uint256 assetAmount = amountOutRay.rayToAssetDecimals(assetOut);
        require(assetAmount != 0 && assetAmount >= minAmountOut, Errors.InsufficientAmountOut());
        IFundsHandler(FUNDS_HANDLER).processWithdrawal(assetOut, assetAmount);
        ITransferHelper(TRANSFER_HELPER).transfer(assetOut, assetAmount, user);
        emit WithdrawalExecuted(user, assetOut, assetAmount);
    }

    /// @inheritdoc IStableVault
    function setDefaultSubVault(uint256 perSecondRate) external override restricted {
        _setDefaultSubVault(_getOrCreateSubVaultWithRate(perSecondRate), perSecondRate);
    }

    /// @inheritdoc IStableVault
    function claimSurplusInterest(address[] calldata assets, uint256[] calldata amounts)
        external
        override
        restricted
        assertingTransferHelperBalanceForAssets(assets)
    {
        for (uint256 i = 0; i < assets.length; i++) {
            IFundsHandler(FUNDS_HANDLER).processWithdrawal(assets[i], amounts[i]);
        }
        // NOTE: Due to oracle-bridge propagation asymmetry, the aggregated balance may temporarily be lower than the
        // actual system value after an IOU exchange on an Earning Chain (the oracle reflects the balance reduction in
        // seconds, while the BURN_IOU_TOKEN message reducing obligations may take longer depending on the source
        // chain). Operators should avoid calling claimSurplusInterest() during these transient windows to prevent
        // unnecessary reverts.
        require(_getVaultObligations() <= _getVaultAggregatedBalance(), SurplusInterestClaimLeadsToInsolvency());
        address treasury = $storage().treasury;
        require(treasury != address(0), TreasuryNotSet());
        ITransferHelper(TRANSFER_HELPER).transfer(assets, amounts, treasury);
        emit SurplusInterestClaimed(assets, amounts);
    }

    /// @inheritdoc IStableVault
    function setTreasury(address treasury) external override restricted {
        _setTreasury(treasury);
    }

    ////////////////////////////////////////////////// GETTERS /////////////////////////////////////////////////////

    /// @inheritdoc IStableVault
    function getGlobalOriginalDepositAmount() external view override returns (uint256) {
        return $storage().globalOriginalDepositsRay;
    }

    /// @inheritdoc IStableVault
    function getClaimableSurplusInterest() external view override returns (uint256) {
        uint256 obligations = _getVaultObligations();
        uint256 assets = _getVaultAggregatedBalance();
        return assets > obligations ? assets - obligations : 0;
    }

    /// @inheritdoc IStableVault
    function getSubVaultConversionRate(uint256 subVaultId) external view override returns (uint256) {
        return _previewSubVaultConversionRate(subVaultId);
    }

    /// @inheritdoc IStableVault
    function getActiveSubVaults() external view override returns (SubVaultData[] memory) {
        SubVaultData[] memory activeSubVaults = new SubVaultData[]($storage().activeSubVaultsIds.length);
        for (uint256 i = 0; i < $storage().activeSubVaultsIds.length; i++) {
            uint256 subVaultId = $storage().activeSubVaultsIds[i];
            uint256 perSecondRate = $storage().subVaultById[subVaultId].perSecondRate;
            activeSubVaults[i] = SubVaultData({perSecondRate: perSecondRate, id: subVaultId});
        }
        return activeSubVaults;
    }

    /// @inheritdoc IStableVault
    function getVaultObligations() external view override returns (uint256) {
        return _getVaultObligations();
    }

    /// @inheritdoc IStableVault
    function totalSupply() external view override returns (uint256) {
        return _getActiveSubVaultsObligations();
    }

    /// @inheritdoc IStableVault
    function getAggregatedBalance() external view override returns (uint256) {
        return _getVaultAggregatedBalance();
    }

    /// @inheritdoc IStableVault
    function balanceOf(address account) external view override returns (uint256) {
        return _getUserBalance(account);
    }

    /// @inheritdoc IStableVault
    function name() external view override returns (string memory) {
        return $storage().name;
    }

    /// @inheritdoc IStableVault
    function symbol() external view override returns (string memory) {
        return $storage().symbol;
    }

    /// @inheritdoc IStableVault
    function decimals() external pure override returns (uint8) {
        return Constants.RAY_DECIMALS;
    }

    /// @inheritdoc IStableVault
    function getUserBalance(address user) external view override returns (uint256) {
        return _getUserBalance(user);
    }

    /// @inheritdoc IStableVault
    function getUserSubVault(address user) external view override returns (SubVaultData memory) {
        uint256 subVaultId = $storage().positions[user].subVaultId;
        uint256 subVaultRate = $storage().subVaultById[subVaultId].perSecondRate;
        return SubVaultData({perSecondRate: subVaultRate, id: subVaultId});
    }

    /// @inheritdoc IStableVault
    function getDefaultSubVault() external view override returns (SubVaultData memory) {
        uint256 subVaultId = $storage().defaultSubVaultId;
        uint256 subVaultRate = $storage().subVaultById[subVaultId].perSecondRate;
        return SubVaultData({perSecondRate: subVaultRate, id: subVaultId});
    }

    /// @inheritdoc IStableVault
    function getSubVaultRateById(uint256 subVaultId) external view override returns (uint256) {
        return $storage().subVaultById[subVaultId].perSecondRate;
    }

    /// @inheritdoc IStableVault
    function getSubVaultIdByRate(uint256 perSecondRate) external view override returns (uint256) {
        return $storage().subVaultIdByRate[perSecondRate];
    }

    /// @inheritdoc IStableVault
    function getMaxValidPerSecondRate() external view override returns (uint256) {
        return MAX_VALID_PER_SECOND_RATE;
    }

    /// @inheritdoc IStableVault
    function getTreasury() external view override returns (address) {
        return $storage().treasury;
    }

    ////////////////////////////////////////////////// INTERNAL /////////////////////////////////////////////////////

    function _validateRate(uint256 perSecondRate) internal view {
        require(perSecondRate >= MathLib.RAY && perSecondRate <= MAX_VALID_PER_SECOND_RATE, InvalidRate());
    }

    function _getOrCreateSubVaultWithRate(uint256 perSecondRate) internal returns (uint256) {
        if (_existsSubVaultWithRate(perSecondRate)) {
            return $storage().subVaultIdByRate[perSecondRate];
        } else {
            return _createSubVault(perSecondRate);
        }
    }

    function _setDefaultSubVault(uint256 subVaultId, uint256 perSecondRate) internal {
        $storage().defaultSubVaultId = subVaultId;
        emit DefaultSubVaultSet(subVaultId, perSecondRate);
    }

    function _createSubVault(uint256 newPerSecondRate) internal returns (uint256) {
        _validateRate(newPerSecondRate);
        uint256 newSubVaultId = ++$storage().lastSubVaultId;
        $storage().subVaultById[newSubVaultId] = SubVault({
            perSecondRate: newPerSecondRate,
            conversionRate: MathLib.RAY,
            lastAccrualTimestamp: uint256(block.timestamp),
            totalShares: 0
        });
        $storage().subVaultIdByRate[newPerSecondRate] = newSubVaultId;
        emit SubVaultCreated(newSubVaultId, newPerSecondRate);
        return newSubVaultId;
    }

    function _migrateUserToSubVault(address user, uint256 oldSubVaultId, uint256 newSubVaultId) internal {
        uint256 oldConversionRate = _accrueSubVaultConversionRate(oldSubVaultId);
        uint256 newConversionRate = _accrueSubVaultConversionRate(newSubVaultId);
        uint256 userOldShares = $storage().positions[user].shares;
        // Round down the amount of shares after sub-vault migration, so that the rounding is in favor of the protocol.
        uint256 userNewShares = userOldShares.rayMulDown(oldConversionRate).rayDivDown(newConversionRate);
        // Do not allow the user position share quantity to deplete to zero which can happen if a user has a small
        // userOldShares quantity and newConversionRate is large.
        require(userNewShares > 0, Errors.InvalidAmount());

        _moveShares({
            from: user,
            to: user,
            fromSubVaultId: oldSubVaultId,
            toSubVaultId: newSubVaultId,
            sharesToBurn: userOldShares,
            sharesToIssue: userNewShares,
            guaranteedAmountToMoveRay: 0
        });
    }

    function _moveShares(
        address from,
        address to,
        uint256 fromSubVaultId,
        uint256 toSubVaultId,
        uint256 sharesToBurn,
        uint256 sharesToIssue,
        uint256 guaranteedAmountToMoveRay
    ) internal {
        uint256 remainingShares = _burnShares(from, fromSubVaultId, sharesToBurn);
        if (fromSubVaultId != toSubVaultId) {
            if (!_isActiveSubVaultById(fromSubVaultId)) {
                _removeSubVaultFromActive(fromSubVaultId);
            }
            if (!_isActiveSubVaultById(toSubVaultId)) {
                _addSubVaultToActive(toSubVaultId);
            }
        }
        _validateAmountOfActiveSubVaults();

        if (from == to) {
            // Sanity check. If the user is the same - this cannot be a partial transfer.
            require(remainingShares == 0, Errors.InvalidAmount());
            require(guaranteedAmountToMoveRay == 0, Errors.InvalidAmount());
            $storage().positions[to].subVaultId = toSubVaultId;
        } else {
            if (remainingShares == 0) {
                delete $storage().positions[from];
            } else {
                $storage().positions[from].originalDepositRay -= guaranteedAmountToMoveRay;
            }
            $storage().positions[to].originalDepositRay += guaranteedAmountToMoveRay;
        }

        _issueShares(to, toSubVaultId, sharesToIssue);
    }

    /// @dev Gets the user's subVaultId or assigns a default subVaultId if the user has no position.
    /// @dev A position is created for the user if they do not have one.
    function _getOrAssignUserSubVaultId(address user) internal returns (uint256) {
        uint256 subVaultId = $storage().positions[user].subVaultId;
        if (subVaultId == 0) {
            subVaultId = $storage().defaultSubVaultId;
            $storage().positions[user].subVaultId = subVaultId;
        }
        return subVaultId;
    }

    /// @dev Computes the shares to burn from sender and guaranteed amount for a transfer.
    /// @dev Reverts if remaining shares would be below dust threshold - caller should use transferAll() instead.
    function _computeTransferShares(address from, uint256 amountRay, uint256 fromSubVaultId, uint256 fromConversionRate)
        internal
        view
        returns (uint256, uint256)
    {
        (uint256 fullAmountRay, uint256 fullGuaranteedAmountRay, uint256 fullSharesToRedeem) =
            _previewFullWithdrawalRequest(from);
        require(amountRay <= fullAmountRay, Errors.InsufficientFunds());

        if (amountRay == fullAmountRay) {
            return (fullGuaranteedAmountRay, fullSharesToRedeem);
        }

        uint256 fromUserShares = amountRay.rayDivUp(fromConversionRate);

        require(_areRemainingSharesRedeemable(from, fromUserShares, fromSubVaultId), Errors.InvalidAmount());
        uint256 guaranteedAmountRay = _getAmountTakenFromOriginalDeposit(from, amountRay);
        return (guaranteedAmountRay, fromUserShares);
    }

    function _areRemainingSharesRedeemable(address user, uint256 redeemedShares, uint256 subVaultId)
        internal
        view
        returns (bool)
    {
        // We want the remainder after a partial withdrawal to be redeemable for at least 1 wei (18-dec) of value.
        // A share balance S (in RAY units) redeems to:
        //   valueRay = rayMulDown(S * conversionRate)
        // and it is withdrawable iff:
        //   rayMulDown(S * conversionRate) >= 1e9
        // which implies:
        //   S >= rayDivUp(1e9, conversionRate)
        uint256 minSharesToRedeemOneWei =
            Constants.MIN_WITHDRAWABLE_AMOUNT_RAY.rayDivUp($storage().subVaultById[subVaultId].conversionRate);
        uint256 remainingSharesAfterRedeem = $storage().positions[user].shares - redeemedShares;
        return remainingSharesAfterRedeem >= minSharesToRedeemOneWei;
    }

    function _addSubVaultToActive(uint256 subVaultId) internal {
        $storage().activeSubVaultsIds.push(subVaultId);
        $storage().activeSubVaultIndexById[subVaultId] = $storage().activeSubVaultsIds.length - 1;
    }

    // Assumes that if it is called then `subVaultId` is indeed active, thus `$storage().activeSubVaultsIds.length > 0`
    function _removeSubVaultFromActive(uint256 subVaultId) internal {
        uint256 subVaultIndex = $storage().activeSubVaultIndexById[subVaultId];
        uint256 lastSubVaultIndex = $storage().activeSubVaultsIds.length - 1;
        if (subVaultIndex != lastSubVaultIndex) {
            uint256 lastSubVaultId = $storage().activeSubVaultsIds[lastSubVaultIndex];
            $storage().activeSubVaultsIds[subVaultIndex] = lastSubVaultId;
            $storage().activeSubVaultIndexById[lastSubVaultId] = subVaultIndex;
        }
        $storage().activeSubVaultsIds.pop();
        delete $storage().activeSubVaultIndexById[subVaultId];
    }

    function _validateAmountOfActiveSubVaults() internal view {
        require($storage().activeSubVaultsIds.length <= MAX_ACTIVE_SUB_VAULTS, TooManyActiveSubVaults());
    }

    function _previewSubVaultConversionRate(uint256 subVaultId) internal view returns (uint256) {
        SubVault storage subVault = $storage().subVaultById[subVaultId];
        uint256 secondsSinceLastAccrual = block.timestamp - subVault.lastAccrualTimestamp;
        if (secondsSinceLastAccrual == 0) {
            return subVault.conversionRate;
        }
        return _computeSubVaultConversionRate(subVault.conversionRate, subVault.perSecondRate, secondsSinceLastAccrual);
    }

    function _accrueSubVaultConversionRate(uint256 subVaultId) internal returns (uint256) {
        SubVault storage subVault = $storage().subVaultById[subVaultId];
        uint256 secondsSinceLastAccrual = block.timestamp - subVault.lastAccrualTimestamp;
        if (secondsSinceLastAccrual == 0) {
            return subVault.conversionRate;
        }
        uint256 newConversionRate =
            _computeSubVaultConversionRate(subVault.conversionRate, subVault.perSecondRate, secondsSinceLastAccrual);
        subVault.conversionRate = newConversionRate;
        subVault.lastAccrualTimestamp = block.timestamp;
        return newConversionRate;
    }

    function _computeSubVaultConversionRate(
        uint256 conversionRate,
        uint256 perSecondRate,
        uint256 secondsSinceLastAccrual
    ) internal pure returns (uint256) {
        uint256 growthFactor = perSecondRate.rpow(secondsSinceLastAccrual);
        // The conversion rate is used across different operations (e.g. converting assets to shares on deposits,
        // converting shares to assets on withdrawals, computing total vault obligations, etc.).
        // The conversion rate calculation rounds down to ensure a conservative and consistent value that subsequent
        // operations can then use to apply their context-specific rounding on top with the intention of favoring
        // the protocol.
        return conversionRate.rayMulDown(growthFactor);
    }

    function _previewFullWithdrawalRequest(address user) internal view returns (uint256, uint256, uint256) {
        uint256 subVaultId = $storage().positions[user].subVaultId;
        // The conversion rate was accrued in the higher order withdrawal function using rounding that favors the
        // protocol. We want the conversion rate's calculation to be rounded down so that we undershoot result of
        // sharesToRedeem * conversionRate.
        uint256 conversionRate = $storage().subVaultById[subVaultId].conversionRate;
        uint256 sharesToRedeem = $storage().positions[user].shares;
        // Round down the withdrawal amount, so that the rounding is in favor of the protocol.
        uint256 actualAmountOfWithdrawalRay = sharesToRedeem.rayMulDown(conversionRate);
        uint256 originalDepositRay = $storage().positions[user].originalDepositRay;
        // Due to rounding in rayDivDown (deposit) and rayMulDown (withdrawal),
        // actualAmountOfWithdrawalRay can be slightly less than originalDepositRay.
        // We guarantee the user gets at least their original deposit back.
        if (actualAmountOfWithdrawalRay < originalDepositRay) {
            actualAmountOfWithdrawalRay = originalDepositRay;
        }
        return (actualAmountOfWithdrawalRay, originalDepositRay, sharesToRedeem);
    }

    function _previewPartialWithdrawalRequest(address user, uint256 withdrawalAmountRay)
        internal
        view
        returns (uint256, uint256, uint256)
    {
        uint256 subVaultId = $storage().positions[user].subVaultId;
        // The conversion rate was accrued in the higher order withdrawal function using rounding that favors the
        // protocol. We want the conversion rate's calculation to be rounded down so that we undershoot the divisor used
        // to calculate the amount of shares to redeem/burn.
        uint256 conversionRate = $storage().subVaultById[subVaultId].conversionRate;
        // Round up the amount of shares to redeem (burn on the position) for the requested amount of assets, so that
        // the rounding is in favor of the protocol.
        uint256 sharesToRedeem = withdrawalAmountRay.rayDivUp(conversionRate);
        require(sharesToRedeem <= $storage().positions[user].shares, Errors.InvalidAmount());
        return (withdrawalAmountRay, _getAmountTakenFromOriginalDeposit(user, withdrawalAmountRay), sharesToRedeem);
    }

    function _getAmountTakenFromOriginalDeposit(address user, uint256 withdrawalAmountRay)
        internal
        view
        returns (uint256)
    {
        uint256 amountTakenFromOriginalDepositRay;
        uint256 originalDepositRay = $storage().positions[user].originalDepositRay;
        if (withdrawalAmountRay >= originalDepositRay) {
            // The remaining portion of user's withdrawable balance is not guaranteed unless user deposits more funds.
            amountTakenFromOriginalDepositRay = originalDepositRay;
        } else {
            amountTakenFromOriginalDepositRay = withdrawalAmountRay;
        }
        return amountTakenFromOriginalDepositRay;
    }

    function _burnShares(address user, uint256 subVaultId, uint256 sharesToBurn) internal returns (uint256) {
        $storage().positions[user].shares -= sharesToBurn;
        $storage().subVaultById[subVaultId].totalShares -= sharesToBurn;
        return $storage().positions[user].shares;
    }

    function _issueShares(address user, uint256 subVaultId, uint256 sharesToMint) internal {
        $storage().positions[user].shares += sharesToMint;
        $storage().subVaultById[subVaultId].totalShares += sharesToMint;
    }

    function _getUserBalance(address user) internal view returns (uint256) {
        uint256 shares = $storage().positions[user].shares;
        if (shares == 0) {
            return 0;
        }
        // Round down the user balance, so that the rounding is in favor of the protocol.
        return shares.rayMulDown(_previewSubVaultConversionRate($storage().positions[user].subVaultId));
    }

    function _getActiveSubVaultsObligations() internal view returns (uint256) {
        uint256 activeSubVaultsObligations;
        for (uint256 i = 0; i < $storage().activeSubVaultsIds.length; i++) {
            // Round up the obligations to avoid understating liabilities.
            activeSubVaultsObligations += $storage().subVaultById[$storage().activeSubVaultsIds[i]].totalShares
                .rayMulUp(_previewSubVaultConversionRate($storage().activeSubVaultsIds[i]));
        }
        return activeSubVaultsObligations;
    }

    function _getVaultObligations() internal view returns (uint256) {
        return _getActiveSubVaultsObligations() + _getIousInCirculation();
    }

    function _getVaultAggregatedBalance() internal view returns (uint256) {
        return IFundsHandler(FUNDS_HANDLER).getAggregatedBalance();
    }

    /// @return supply of all IOU tokens across all networks
    function _getIousInCirculation() internal view returns (uint256) {
        return IERC20(IIouTokenManager(IOU_TOKEN_MANAGER).getAsset()).totalSupply();
    }

    function _mintIous(address user, uint256 amount) internal {
        IIouTokenManager(IOU_TOKEN_MANAGER).mintTokens(user, amount);
    }

    function _isActiveSubVaultById(uint256 subVaultId) internal view returns (bool) {
        return $storage().subVaultById[subVaultId].totalShares > 0;
    }

    function _existsSubVaultWithRate(uint256 perSecondRate) internal view returns (bool) {
        return $storage().subVaultIdByRate[perSecondRate] != 0;
    }

    function _setUserRate(address user, uint256 newPerSecondRate) internal {
        uint256 oldSubVaultId = $storage().positions[user].subVaultId;
        // Skip users without a position (e.g., withdrew or transferred out between batch
        // preparation and execution) to avoid reverting the entire batch.
        if (oldSubVaultId != 0) {
            require(
                newPerSecondRate != $storage().subVaultById[oldSubVaultId].perSecondRate,
                RedundantRate(user, newPerSecondRate)
            );
            uint256 newSubVaultId = _getOrCreateSubVaultWithRate(newPerSecondRate);
            _migrateUserToSubVault(user, oldSubVaultId, newSubVaultId);
            emit UserRateSet(user, newSubVaultId, newPerSecondRate);
        }
    }

    function _setTreasury(address treasury) internal {
        $storage().treasury = treasury;
        emit TreasurySet(treasury);
    }

    function _beforeRescueTokens(
        address, // token
        uint256 // amount
    )
        internal
        virtual
        override
    {
        // Equivalent to adding the `restricted` modifier.
        _checkCanCall(_msgSender(), _msgData());
    }

    function _beforeRescueNative(uint256) internal virtual override {
        // Equivalent to adding the `restricted` modifier.
        _checkCanCall(_msgSender(), _msgData());
    }
}

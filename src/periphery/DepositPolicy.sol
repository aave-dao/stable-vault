// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {AccessManaged} from "@openzeppelin/contracts/access/manager/AccessManaged.sol";
import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";

import {IDepositPolicy} from "src/interfaces/IDepositPolicy.sol";
import {RateLimitWindowLib} from "src/libraries/RateLimitWindowLib.sol";
import {Errors} from "src/types/Errors.sol";

/// @title DepositPolicy
/// @author Aave Labs
/// @notice Per-asset rate-limited deposit policy. Each asset has a window with a max capacity and a per-second refill
/// rate; deposits consume from the available capacity and revert when it is exhausted. Assets without a configured
/// window are unrestricted.
contract DepositPolicy is AccessManaged, IDepositPolicy {
    using RateLimitWindowLib for RateLimitWindowLib.Window;

    event DepositWindowSet(address indexed asset, uint128 maxAmount, uint128 refillRate);

    address internal immutable DEPOSIT_POLICY_APPLIER;

    mapping(address asset => RateLimitWindowLib.Window window) internal _windows;

    modifier onlyDepositPolicyApplier() {
        require(msg.sender == DEPOSIT_POLICY_APPLIER, Errors.NotAuthorized());
        _;
    }

    constructor(address accessManager, address depositPolicyApplier) AccessManaged(accessManager) {
        IAccessManager(accessManager).canCall(address(0), address(0), bytes4(0));
        require(depositPolicyApplier != address(0), Errors.ZeroAddress());
        DEPOSIT_POLICY_APPLIER = depositPolicyApplier;
    }

    /// @inheritdoc IDepositPolicy
    function applyDepositPolicy(DepositRequest calldata request)
        external
        override
        onlyDepositPolicyApplier
        returns (bool)
    {
        RateLimitWindowLib.Window storage window = _windows[request.asset];
        if (window.maxAmount != 0) {
            window.consume(request.amount);
        }
        emit DepositPolicyApplied(request.caller, request.user, request.asset, request.amount);
        return true;
    }

    /// @inheritdoc IDepositPolicy
    function previewDepositPolicy(DepositRequest calldata request) external view override returns (bool) {
        RateLimitWindowLib.Window storage window = _windows[request.asset];
        if (window.maxAmount == 0) {
            return true;
        }
        return window.preview() >= request.amount;
    }

    function getAvailableAmount(address asset) external view returns (uint256) {
        RateLimitWindowLib.Window storage window = _windows[asset];
        if (window.maxAmount == 0) {
            // Unconfigured asset: no limit.
            return type(uint256).max;
        }
        return window.preview();
    }

    function getDepositWindow(address asset) external view returns (RateLimitWindowLib.Window memory) {
        return _windows[asset];
    }

    function setDepositWindow(address asset, uint128 maxAmount, uint128 refillRate) external restricted {
        require(asset != address(0), Errors.ZeroAddress());
        _windows[asset].configure(maxAmount, refillRate);
        emit DepositWindowSet(asset, maxAmount, refillRate);
    }
}

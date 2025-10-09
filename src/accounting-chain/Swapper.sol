// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {ISwapper} from "./interfaces/ISwapper.sol";
import {ErrorsLib} from "../libraries/ErrorsLib.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";

/// @title Swapper
/// @notice Executes swaps through approved routers and selectors with slippage & access control.
contract Swapper is ISwapper, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using Address for address;

    address public override admin;

    // Allowed routers for (fromAsset → toAsset)
    mapping(address => mapping(address => mapping(address => bool))) private _allowedRouters;

    // Allowed function selectors (e.g. bytes4(keccak256("swapExactTokensForTokens(...)")))
    mapping(bytes4 => bool) private _allowedSelectors;

    modifier onlyAdmin() {
        if (msg.sender != admin) revert ErrorsLib.NotAdmin();
        _;
    }

    constructor(address _admin) {
        require(_admin != address(0), ErrorsLib.ZeroAddress());
        admin = _admin;
    }

    function isAllowedRouter(address fromAsset, address toAsset, address router) external view returns (bool) {
        return _allowedRouters[fromAsset][toAsset][router];
    }

    /// @inheritdoc ISwapper
    function execute(
        address fromAsset,
        uint256 fromAmount,
        address toAsset,
        uint16 minSlippageBps,
        address router,
        bytes memory routerData
    ) external nonReentrant returns (uint256 toAmount) {
        require(_allowedRouters[fromAsset][toAsset][router], RouterNotAllowed(router));

        bytes4 selector;
        assembly {
            selector := mload(add(routerData, 32))
        }
        require(_allowedSelectors[selector], SelectorNotAllowed(selector));

        // Pull tokens from caller
        IERC20(fromAsset).safeTransferFrom(msg.sender, address(this), fromAmount);

        // Approve router to spend
        IERC20(fromAsset).forceApprove(router, fromAmount);

        toAmount = _executeSwap(toAsset, router, routerData);

        // Slippage check
        uint256 expectedMinOut = (fromAmount * (10_000 - minSlippageBps)) / 10_000;
        require(toAmount >= expectedMinOut, SlippageTooHigh(expectedMinOut, toAmount));

        // Cleanup approvals
        IERC20(fromAsset).forceApprove(router, 0);

        // Return funds to caller
        IERC20(toAsset).safeTransfer(msg.sender, toAmount);

        emit SwapExecuted(msg.sender, fromAsset, toAsset, router, fromAmount, toAmount);
    }

    function setAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ErrorsLib.ZeroAddress();
        emit AdminUpdated(admin, newAdmin);
        admin = newAdmin;
    }

    function setAllowedRouter(address fromAsset, address toAsset, address router, bool allowed) external onlyAdmin {
        _allowedRouters[fromAsset][toAsset][router] = allowed;
        emit RouterPermissionUpdated(fromAsset, toAsset, router, allowed);
    }

    function setAllowedSelector(bytes4 selector, bool allowed) external onlyAdmin {
        _allowedSelectors[selector] = allowed;
        emit SelectorPermissionUpdated(selector, allowed);
    }

    function _executeSwap(address toAsset, address router, bytes memory routerData)
        private
        returns (uint256 toAmount)
    {
        uint256 balanceBefore = IERC20(toAsset).balanceOf(address(this));
        (bool success, bytes memory data) = router.call(routerData);
        require(success, LowLevelCallFailed(data));
        uint256 balanceAfter = IERC20(toAsset).balanceOf(address(this));
        return balanceAfter - balanceBefore;
    }
}

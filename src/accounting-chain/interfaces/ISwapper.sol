// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

interface ISwapper {
    event AdminUpdated(address indexed oldAdmin, address indexed newAdmin);
    event RouterPermissionUpdated(address indexed from, address indexed to, address indexed router, bool allowed);
    event SelectorPermissionUpdated(bytes4 indexed selector, bool allowed);
    event MinimumSlippageUpdated(address indexed from, address indexed to, uint16 bps);
    event SwapExecuted(
        address indexed caller,
        address indexed fromAsset,
        address indexed toAsset,
        address router,
        uint256 fromAmount,
        uint256 toAmount
    );

    error LowLevelCallFailed(bytes data);
    error InvalidBPS();
    error RouterNotAllowed(address router);
    error SelectorNotAllowed(bytes4 selector);
    error SlippageTooHigh(uint256 expectedMinOut, uint256 actualOut);

    function admin() external view returns (address);

    /// @param fromAsset input asset
    /// @param toAsset output asset
    /// @param router the router to use to swap fromAsset to toAsset
    /// @dev returns true if the router is allowed to swap fromAsset to toAsset
    function isAllowedRouter(address fromAsset, address toAsset, address router) external view returns (bool);

    /// @dev The Swapper must take possession of the fromAsset to perform the swap.
    /// @dev The Swapper must take possession of the toAsset to check slippage constraints before sending it to the msg.sender.
    /// @param routerData is the selector + data to pass to the router
    /// @param fromAsset the asset transferred to the swapper that must be approved to be spent by the router
    /// @param fromAmount the amount of fromAsset to approve the router to spend
    /// @param toAsset the asset to swap to
    /// @param slippageToleranceBps the minimum slippage in basis points (100 = 1%)
    /// @param router the router to use to swap fromAsset to toAsset
    /// @param routerData the selector + data to pass to the router
    function execute(
        address fromAsset,
        uint256 fromAmount,
        address toAsset,
        uint16 slippageToleranceBps,
        address router,
        bytes memory routerData
    ) external returns (uint256 toAmount);
}

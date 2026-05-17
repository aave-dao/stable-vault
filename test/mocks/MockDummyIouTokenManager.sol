// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IIouTokenManager} from "src/interfaces/IIouTokenManager.sol";

contract MockDummyIouTokenManager is IIouTokenManager {
    mapping(address account => uint256 amount) public burnedAmount;
    uint256 public totalBurned;

    function getAsset() external view override returns (address) {}

    function getLockedBalance() external view override returns (uint256) {}

    function bridgeTokens(
        uint256, // destinationChainId
        address, // iouTokenRecipient
        uint256, // iouTokenAmountRay
        address, // bridgeAdapter
        uint256, // gasLimit
        bytes calldata // bridgeAdapterData
    )
        external
        payable
        override
    {}

    function mintTokens(address to, uint256 amount) external override {}

    function burnTokens(address from, uint256 amount) external override {
        burnedAmount[from] += amount;
        totalBurned += amount;
    }

    function burnLockedTokens(uint256 amount) external override {}

    function releaseTokens(address to, uint256 amount) external override {}
}

// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IIouTokenManager} from "src/interfaces/IIouTokenManager.sol";
import {IMintableBurnableIERC20} from "src/interfaces/IMintableBurnableIERC20.sol";

contract MockIouTokenManager is IIouTokenManager {
    using SafeERC20 for IERC20;

    address internal _IOU_TOKEN;

    uint256 internal _lockedBalance;

    bool internal _isCanonicalChain;

    function mockIsCanonicalChain(bool isCanonicalChain) external {
        _isCanonicalChain = isCanonicalChain;
    }

    function mockIouToken(address iouToken) external {
        _IOU_TOKEN = iouToken;
    }

    function mockLockedBalance(uint256 lockedBalance) external {
        _lockedBalance = lockedBalance;
        uint256 currentBalance = IERC20(_IOU_TOKEN).balanceOf(address(this));
        if (currentBalance < lockedBalance) {
            IMintableBurnableIERC20(_IOU_TOKEN).mint(address(this), lockedBalance - currentBalance);
        } else if (currentBalance > lockedBalance) {
            IMintableBurnableIERC20(_IOU_TOKEN).burn(address(this), currentBalance - lockedBalance);
        }
    }

    function getAsset() external view override returns (address) {
        return _IOU_TOKEN;
    }

    function getLockedBalance() external view override returns (uint256) {
        return _lockedBalance;
    }

    function bridgeTokensFrom(
        address from,
        uint256, // destinationChainId
        address, // iouTokenRecipient
        uint256 iouTokenAmountRay,
        address, // bridgeAdapter
        address, // feePayer
        bytes calldata // bridgeParamsEncoded
    ) external payable override {
        if (_isCanonicalChain) {
            _lockTokens(from, iouTokenAmountRay);
        } else {
            _burnTokens(from, iouTokenAmountRay);
        }
    }

    function mintTokens(address to, uint256 amount) external override {
        IMintableBurnableIERC20(_IOU_TOKEN).mint(to, amount);
    }

    function burnTokens(address from, uint256 amount) external override {
        IMintableBurnableIERC20(_IOU_TOKEN).burn(from, amount);
    }

    function burnLockedTokens(uint256 amount) external override {
        require(_lockedBalance >= amount, InsufficientLockedBalance());
        _lockedBalance -= amount;
        _burnTokens(address(this), amount);
    }

    function releaseTokens(address to, uint256 amount) external override {
        require(_lockedBalance >= amount, InsufficientLockedBalance());
        _lockedBalance -= amount;
        IERC20(_IOU_TOKEN).safeTransfer(to, amount);
    }

    function _lockTokens(address from, uint256 amount) internal {
        _lockedBalance += amount;
        IERC20(_IOU_TOKEN).safeTransferFrom(from, address(this), amount);
    }

    function _burnTokens(address from, uint256 amount) internal {
        IMintableBurnableIERC20(_IOU_TOKEN).burn(from, amount);
    }
}

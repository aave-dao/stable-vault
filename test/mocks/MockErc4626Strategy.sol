// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

contract MockErc4626Strategy is ERC4626 {
    using SafeERC20 for IERC20;
    using Math for uint256;

    bool private _mockMaxWithdraw;
    uint256 private _maxWithdraw;
    bool private _withdrawShouldRevert;
    string private _withdrawRevertErrorMsg;
    bool private _redeemShouldRevert;
    string private _redeemRevertErrorMsg;

    constructor(IERC20 asset) ERC4626(asset) ERC20("Mock Erc4626 Strategy", "MOCK4626") {}

    function mockMaxWithdraw(uint256 maxWithdrawValue) external {
        _mockMaxWithdraw = true;
        _maxWithdraw = maxWithdrawValue;
    }

    function discardMaxWithdrawMock() external {
        _mockMaxWithdraw = false;
        _maxWithdraw = 0;
    }

    function mockWithdrawToRevert(string memory errorMsg) external {
        _withdrawShouldRevert = true;
        _withdrawRevertErrorMsg = errorMsg;
    }

    function mockRedeemToRevert(string memory errorMsg) external {
        _redeemShouldRevert = true;
        _redeemRevertErrorMsg = errorMsg;
    }

    function maxWithdraw(address owner) public view override returns (uint256) {
        if (_mockMaxWithdraw) {
            return _maxWithdraw;
        }
        return super.maxWithdraw(owner);
    }

    // Overridden to allow bypassing maxWithdraw check when custom maxWithdraw is set to 0.
    // This simulates strategies where maxWithdraw returns 0 but withdrawal is still possible
    function withdraw(uint256 assets, address receiver, address owner) public override returns (uint256) {
        if (_withdrawShouldRevert) {
            revert(_withdrawRevertErrorMsg);
        }

        // If custom maxWithdraw is set, bypass the standard maxWithdraw check
        // This allows testing the scenario where maxWithdraw returns 0 but withdrawal still succeeds
        if (_mockMaxWithdraw) {
            uint256 shares = previewWithdraw(assets);
            _withdraw(_msgSender(), receiver, owner, assets, shares);
            return shares;
        }

        return super.withdraw(assets, receiver, owner);
    }

    function redeem(uint256 shares, address receiver, address owner) public override returns (uint256) {
        if (_redeemShouldRevert) {
            revert(_redeemRevertErrorMsg);
        }

        return super.redeem(shares, receiver, owner);
    }
}

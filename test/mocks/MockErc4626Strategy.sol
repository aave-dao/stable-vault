// SPDX-License-Identifier: MIT
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
    bool private _mockMaxRedeem;
    uint256 private _maxRedeem;
    bool private _withdrawShouldRevert;
    string private _withdrawRevertErrorMsg;
    bool private _redeemShouldRevert;
    string private _redeemRevertErrorMsg;
    bool private _mockPreviewRedeem;
    uint256 private _previewRedeem;
    bool private _previewRedeemShouldRevert;
    string private _previewRedeemRevertErrorMsg;

    constructor(IERC20 asset) ERC4626(asset) ERC20("Mock Erc4626 Strategy", "MOCK4626") {}

    function mockMaxWithdraw(uint256 maxWithdrawValue) external {
        _mockMaxWithdraw = true;
        _maxWithdraw = maxWithdrawValue;
    }

    function mockMaxRedeem(uint256 maxRedeemValue) external {
        _mockMaxRedeem = true;
        _maxRedeem = maxRedeemValue;
    }

    function mockPreviewRedeem(uint256 previewRedeemValue) external {
        _mockPreviewRedeem = true;
        _previewRedeem = previewRedeemValue;
    }

    function discardMaxWithdrawMock() external {
        _mockMaxWithdraw = false;
        _maxWithdraw = 0;
    }

    function discardMaxRedeemMock() external {
        _mockMaxRedeem = false;
        _maxRedeem = 0;
    }

    function discardPreviewRedeemMock() external {
        _mockPreviewRedeem = false;
        _previewRedeem = 0;
    }

    function mockWithdrawToRevert(string memory errorMsg) external {
        _withdrawShouldRevert = true;
        _withdrawRevertErrorMsg = errorMsg;
    }

    function mockPreviewRedeemToRevert(string memory errorMsg) external {
        _previewRedeemShouldRevert = true;
        _previewRedeemRevertErrorMsg = errorMsg;
    }

    function discardPreviewRedeemRevertMock() external {
        _previewRedeemShouldRevert = false;
        _previewRedeemRevertErrorMsg = "";
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

    function maxRedeem(address owner) public view override returns (uint256) {
        if (_mockMaxRedeem) {
            return _maxRedeem;
        }
        return super.maxRedeem(owner);
    }

    function previewRedeem(uint256 shares) public view override returns (uint256) {
        if (_previewRedeemShouldRevert) {
            revert(_previewRedeemRevertErrorMsg);
        }
        if (_mockPreviewRedeem) {
            return _previewRedeem;
        }
        return super.previewRedeem(shares);
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

        // Allow bypassing maxRedeem checks when mocked so tests can assert callers respect the value themselves.
        if (_mockMaxRedeem) {
            uint256 assets = previewRedeem(shares);
            _withdraw(_msgSender(), receiver, owner, assets, shares);
            return assets;
        }

        return super.redeem(shares, receiver, owner);
    }
}

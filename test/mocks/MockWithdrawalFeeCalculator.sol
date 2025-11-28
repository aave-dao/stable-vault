// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IWithdrawalFeeCalculator} from "../../src/interfaces/IWithdrawalFeeCalculator.sol";

contract MockWithdrawalFeeCalculator is IWithdrawalFeeCalculator {
    function getAssetFeeBpsConfig(address asset) external view override returns (AssetFeeBpsConfig memory) {}
    function getBasicFeeBps() external view override returns (uint256) {}
    function isSigner(address signer) external view override returns (bool) {}
    function calculateWithdrawalFee(address user, address assetOut, uint256 iouAmountRay, bytes memory data)
        external
        view
        override
        returns (uint256)
    {}
    function setAssetFeeBps(address asset, uint256 newAssetFeeBps, bool isSet) external override {}
    function setBasicFeeBps(uint256 newBasicFeeBps) external override {}
    function setSigner(address signer, bool whitelistedSigner) external override {}
}

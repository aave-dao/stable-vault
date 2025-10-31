// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IIouTokenManager} from "../../src/interfaces/IIouTokenManager.sol";

contract MockIouTokenManager is IIouTokenManager {
    function getAsset() external view override returns (address) {}
    function getLockedBalance() external view override returns (uint256) {}
    function bridgeTokens(
        uint256 destinationChainId,
        address iouTokenRecipient,
        uint256 iouTokenAmountRay,
        address bridgeFeePayer,
        address bridgeFeeToken,
        uint256 bridgeFeeAmount
    ) external payable override {}
    function mintTokens(address to, uint256 amount) external override {}
    function burnTokens(address from, uint256 amount) external override {}
    function burnLockedTokens(uint256 amount) external override {}

    function releaseTokens(address to, uint256 amount) external override {}
    function setAllowedMinter(address minter, bool allowed) external override {}
    function setAllowedBurner(address burner, bool allowed) external override {}
    function setAllowedReleaser(address releaser, bool allowed) external override {}
}

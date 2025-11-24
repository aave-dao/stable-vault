// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IBridgeAdapter} from "../../src/interfaces/IBridgeAdapter.sol";
import {IIouTokenManager} from "../../src/interfaces/IIouTokenManager.sol";

contract MockDummyIouTokenManager is IIouTokenManager {
    function getAsset() external view override returns (address) {}

    function getLockedBalance() external view override returns (uint256) {}

    function bridgeTokens(
        uint256, // destinationChainId
        address, // iouTokenRecipient
        uint256 iouTokenAmountRay,
        IBridgeAdapter.BridgeParams memory bridgeParams // bridgeParams
    )
        external
        payable
        override
    {}

    function mintTokens(address to, uint256 amount) external override {}

    function burnTokens(address from, uint256 amount) external override {}

    function burnLockedTokens(uint256 amount) external override {}

    function releaseTokens(address to, uint256 amount) external override {}
}

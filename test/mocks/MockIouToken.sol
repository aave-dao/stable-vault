// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IouToken} from "src/core/ious/IouToken.sol";

contract MockIouToken is IouToken {
    constructor(address owner) IouToken(owner) {}

    function mockMint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function mockBurn(address from, uint256 amount) external {
        _burn(from, amount);
    }

    function mockOwner(address owner) external {
        _transferOwnership(owner);
    }
}

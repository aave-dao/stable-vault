// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/interfaces/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

interface IMockErc20 is IERC20 {
    function mint(address to, uint256 amount) external;
    function mint(uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function burn(uint256 amount) external;
    function decimals() external view returns (uint8);
}

contract MockErc20 is ERC20, IMockErc20 {
    uint8 internal immutable DECIMALS;

    constructor(string memory name, string memory symbol, uint8 decimalPlaces) ERC20(name, symbol) {
        DECIMALS = decimalPlaces;
    }

    function decimals() public view override(ERC20, IMockErc20) returns (uint8) {
        return DECIMALS;
    }

    function mint(address to, uint256 amount) external virtual override {
        _mint(to, amount);
    }

    function mint(uint256 amount) external virtual override {
        _mint(msg.sender, amount);
    }

    function burn(address from, uint256 amount) external virtual override {
        _burn(from, amount);
    }

    function burn(uint256 amount) external virtual override {
        _burn(msg.sender, amount);
    }
}

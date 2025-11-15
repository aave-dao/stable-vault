// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

// Minimal ERC20 for tests
contract TestErc20 is IERC20, IERC20Metadata {
    string public constant NAME = "Test USD";
    string public constant SYMBOL = "TUSD";

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    uint8 internal _decimals;

    constructor(uint8 decimals_) {
        _decimals = decimals_;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        require(a >= amount, "allow");
        allowance[from][msg.sender] = a - amount;
        _transfer(from, to, amount);
        return true;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external {
        totalSupply -= amount;
        balanceOf[from] -= amount;
        emit Transfer(from, address(0), amount);
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "TestErc20: transfer amount exceeds balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function name() external pure returns (string memory) {
        return NAME;
    }

    function symbol() external pure returns (string memory) {
        return SYMBOL;
    }
}

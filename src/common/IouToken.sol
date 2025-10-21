// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IMintableBurnableIERC20} from "../interfaces/IMintableBurnableIERC20.sol";

contract IouToken is ERC20, Ownable, IMintableBurnableIERC20 {
    uint8 internal constant RAY_DECIMALS = 27;

    constructor(address owner) ERC20("IouToken", "IOU") Ownable(owner) {}

    // TODO: will we need multiple addresses able to mint and burn (bridge contracts, FH, Earning Chain Gateway)?

    function mint(address to, uint256 amount) external override onlyOwner {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external override onlyOwner {
        _burn(from, amount);
    }

    function decimals() public view virtual override returns (uint8) {
        return RAY_DECIMALS;
    }
}

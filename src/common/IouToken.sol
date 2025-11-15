// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IMintableBurnableIERC20} from "../interfaces/IMintableBurnableIERC20.sol";
import {ConstantsLib} from "../libraries/ConstantsLib.sol";

contract IouToken is ERC20, Ownable, IMintableBurnableIERC20 {
    constructor(address owner) ERC20("IouToken", "IOU") Ownable(owner) {}

    function mint(address to, uint256 amount) external override onlyOwner {
        _mint(to, amount);
    }

    function burn(address from, uint256 amount) external override onlyOwner {
        _burn(from, amount);
    }

    function decimals() public view virtual override returns (uint8) {
        return ConstantsLib.RAY_DECIMALS;
    }
}

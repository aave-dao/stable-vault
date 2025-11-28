// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IIouToken} from "../interfaces/IIouToken.sol";
import {IMintableBurnableIERC20} from "../interfaces/IMintableBurnableIERC20.sol";
import {ConstantsLib} from "../libraries/ConstantsLib.sol";

/// @title IouToken
/// @author Aave Labs
/// @notice IouToken ERC20 contract.
/// @dev IOU tokens can be exchanged for assets supported by the Allocator on a respective chain.
contract IouToken is ERC20, Ownable, IIouToken {
    /// @dev Constructor.
    /// @param iouTokenManager Address of the IOU token manager which is the owner of the token.
    constructor(address iouTokenManager) ERC20("IouToken", "IOU") Ownable(iouTokenManager) {}

    /// @inheritdoc IMintableBurnableIERC20
    function mint(address to, uint256 amount) external override onlyOwner {
        _mint(to, amount);
    }

    /// @inheritdoc IMintableBurnableIERC20
    function burn(address from, uint256 amount) external override onlyOwner {
        _burn(from, amount);
    }

    /// @inheritdoc IIouToken
    function lock(address from, uint256 amount) external override onlyOwner {
        _transfer(from, owner(), amount);
        emit Locked(from, amount);
    }

    /// @inheritdoc ERC20
    function decimals() public view virtual override returns (uint8) {
        return ConstantsLib.RAY_DECIMALS;
    }
}

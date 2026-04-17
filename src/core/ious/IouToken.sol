// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

import {IIouToken} from "src/interfaces/IIouToken.sol";
import {IMintableBurnableIERC20} from "src/interfaces/IMintableBurnableIERC20.sol";
import {Constants} from "src/types/Constants.sol";
import {Errors} from "src/types/Errors.sol";

/// @title IouToken
/// @author Aave Labs
/// @notice IouToken ERC20 contract.
/// @dev IOU tokens can be exchanged for assets supported by the Allocator on a respective chain.
contract IouToken is ERC20, Ownable, IIouToken {
    /// @dev Constructor.
    /// @param iouTokenManager Address of the IOU token manager which is the owner of the token.
    /// @param name_ ERC20 name for this IOU token (e.g. "IOU: Aave USD Stable Vault"). Set once at deployment.
    /// @param symbol_ ERC20 symbol for this IOU token (e.g. "IOU-USD"). Set once at deployment.
    constructor(address iouTokenManager, string memory name_, string memory symbol_)
        ERC20(name_, symbol_)
        Ownable(iouTokenManager)
    {
        require(iouTokenManager != address(0), Errors.ZeroAddress());
        // Empty name/symbol would render as blank in explorers and wallets — reject up front to catch deployment
        // mistakes early (VA-98). ERC20 metadata is set once at deployment and immutable thereafter.
        require(bytes(name_).length > 0, Errors.InvalidParameter());
        require(bytes(symbol_).length > 0, Errors.InvalidParameter());
    }

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
    }

    /// @inheritdoc ERC20
    function decimals() public view virtual override returns (uint8) {
        return Constants.RAY_DECIMALS;
    }
}

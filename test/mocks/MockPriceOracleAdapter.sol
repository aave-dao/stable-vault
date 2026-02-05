// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IPriceOracleAdapter} from "src/interfaces/IPriceOracleAdapter.sol";

contract MockPriceOracleAdapter is IPriceOracleAdapter {
    mapping(address asset => OracleResponse) internal _responses;
    bool public shouldRevert;
    string public revertReason;

    function setShouldRevert(bool _shouldRevert, string memory errorMessage) external {
        shouldRevert = _shouldRevert;
        revertReason = errorMessage;
    }

    function mockResponse(address asset, uint256 priceRay, bool isStale) external {
        _responses[asset] = OracleResponse({priceRay: priceRay, isStale: isStale});
    }

    function getPrice(address asset) external view override returns (OracleResponse memory) {
        if (shouldRevert) {
            revert(revertReason);
        }
        return _responses[asset];
    }
}

// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IPriceOracleAdapter} from "src/interfaces/IPriceOracleAdapter.sol";

/// @dev Mock adapter that burns gas indefinitely once `burnEnabled` is set. Used to test the
/// Liquity-style OOG guard in `PriceOracle._getPrice`. Returns a benign response while disabled so
/// that the `setOracleAdapterForAsset` sanity-call passes during setup.
contract GasBurnerPriceOracleAdapter is IPriceOracleAdapter {
    bool public burnEnabled;
    OracleResponse internal _response;

    function setBurnEnabled(bool enabled) external {
        burnEnabled = enabled;
    }

    function setResponse(uint256 priceRay, bool isStale) external {
        _response = OracleResponse({priceRay: priceRay, isStale: isStale});
    }

    function getPrice(address) external view override returns (OracleResponse memory) {
        if (burnEnabled) {
            // Burn gas until OOG. keccak256 calls give us deterministic gas consumption inside a
            // `view` function (can't write storage).
            bytes32 h = keccak256("seed");
            while (true) {
                h = keccak256(abi.encode(h));
            }
        }
        return _response;
    }
}

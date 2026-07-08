// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IPriceOracleAdapter} from "src/interfaces/IPriceOracleAdapter.sol";

/// @dev Adapter mock that loops forever in `getPrice` once `burnEnabled` is set. While disabled it
/// returns a configurable response so the registration sanity-call in `setOracleAdapterForAsset` passes.
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
            bytes32 h = keccak256("seed");
            while (true) {
                h = keccak256(abi.encode(h));
            }
        }
        return _response;
    }
}

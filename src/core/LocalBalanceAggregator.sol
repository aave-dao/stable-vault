// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IAllocator} from "src/interfaces/IAllocator.sol";
import {IPriceOracle} from "src/interfaces/IPriceOracle.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";
import {MathLib} from "src/libraries/MathLib.sol";
import {Errors} from "src/types/Errors.sol";

/// @title LocalBalanceAggregator
/// @author Aave Labs
/// @notice Aggregates the balance of the Allocator's assets in the local chain.
abstract contract LocalBalanceAggregator {
    using AssetLib for uint256;
    using MathLib for uint256;

    address internal immutable ALLOCATOR;
    address internal immutable PRICE_ORACLE;

    constructor(address allocator, address priceOracle) {
        require(allocator != address(0), Errors.ZeroAddress());
        require(priceOracle != address(0), Errors.ZeroAddress());
        ALLOCATOR = allocator;
        PRICE_ORACLE = priceOracle;
    }

    /// @dev Sums only the Allocator's trusted assets priced through the PriceOracle. Distrusted assets
    /// contribute 0, intentionally underestimating the balance to stay conservative.
    function _getLocalAggregatedBalance() internal view returns (uint256) {
        IAllocator.AllocatorBalance[] memory allocatorAssets = IAllocator(ALLOCATOR).getTrustedAssetBalances();
        uint256 localBalanceRay;
        for (uint256 i = 0; i < allocatorAssets.length; i++) {
            uint256 priceRay = IPriceOracle(PRICE_ORACLE).getPrice(allocatorAssets[i].asset);
            localBalanceRay += priceRay.rayMulDown(
                allocatorAssets[i].amount.assetDecimalsToRay(allocatorAssets[i].asset)
            );
        }
        return localBalanceRay;
    }
}

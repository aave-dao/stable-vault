// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IRescuableAssets} from "src/interfaces/IRescuableAssets.sol";
import {RescuableAssetNative} from "src/misc/RescuableAssetNative.sol";
import {RescuableAssetToken} from "src/misc/RescuableAssetToken.sol";

/// @title RescuableAssets
/// @author Aave Labs
/// @notice Abstract base contract for contracts that can rescue tokens and native assets.
abstract contract RescuableAssets is IRescuableAssets, RescuableAssetToken, RescuableAssetNative {}

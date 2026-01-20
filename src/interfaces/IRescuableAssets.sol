// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IRescuableAssetNative} from "src/interfaces/IRescuableAssetNative.sol";
import {IRescuableAssetToken} from "src/interfaces/IRescuableAssetToken.sol";

/// @title IRescuableAssets
/// @author Aave Labs
/// @notice Interface for contracts that can rescue tokens and native assets.
interface IRescuableAssets is IRescuableAssetToken, IRescuableAssetNative {}

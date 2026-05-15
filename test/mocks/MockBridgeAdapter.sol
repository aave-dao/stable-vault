// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {IBridgeAdapter} from "src/interfaces/IBridgeAdapter.sol";
import {ICcipBridgeAdapter} from "src/interfaces/ICcipBridgeAdapter.sol";
import {ITransferHelper} from "src/interfaces/ITransferHelper.sol";
import {Constants} from "src/types/Constants.sol";
import {Errors} from "src/types/Errors.sol";

/// @dev Mirrors the opaque-bytes shape of IBridgeAdapter and pulls the bridged amount from TransferHelper.
contract MockBridgeAdapter is IBridgeAdapter {
    using SafeERC20 for IERC20;

    address internal immutable TRANSFER_HELPER;
    uint256 internal _feeAmount;

    constructor(address transferHelper) {
        TRANSFER_HELPER = transferHelper;
    }

    function getGateway() external view override returns (address) {}

    function mockFeeAmount(uint256 feeAmount) external {
        _feeAmount = feeAmount;
    }

    function publishMessageToChainWithFeePayer(
        uint256 destinationChainId,
        address asset,
        uint256 amount,
        bytes memory data,
        address feePayer,
        uint256 gasLimit,
        bytes memory bridgeAdapterData
    ) external payable override {
        (destinationChainId, data, gasLimit);
        ICcipBridgeAdapter.CcipFeeParams memory ccipFeeParams =
            abi.decode(bridgeAdapterData, (ICcipBridgeAdapter.CcipFeeParams));

        if (ccipFeeParams.feeToken == Constants.NATIVE_CURRENCY) {
            require(msg.value >= _feeAmount, Errors.InsufficientFunds());
        } else {
            require(msg.value == 0, Errors.InvalidParameter());
            if (_feeAmount > 0) {
                IERC20(ccipFeeParams.feeToken).safeTransferFrom(feePayer, address(this), _feeAmount);
            }
        }

        if (asset != Constants.ASSET_FOR_DATA_ONLY_BRIDGE && amount > 0) {
            ITransferHelper(TRANSFER_HELPER).pull(asset, amount);
        }
    }

    function setDestinationChainAdapter(uint256 chainId, address destinationChainAdapter) external override {}

    receive() external payable {}
}

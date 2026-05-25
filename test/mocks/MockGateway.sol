// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {CcipAdapter} from "src/bridging/ccip/CcipAdapter.sol";
import {IChainGateway} from "src/interfaces/IChainGateway.sol";
import {ITransferHelper} from "src/interfaces/ITransferHelper.sol";
import {Constants} from "src/types/Constants.sol";
import {Errors} from "src/types/Errors.sol";

contract MockGateway is IChainGateway {
    using SafeERC20 for IERC20;

    address internal _transferHelper;
    uint256 internal _balanceToConsume;
    address internal _tokenToComsume;
    address internal _destination;

    function getIouTokenManager() external view returns (address) {}

    function mockConsumeOnNextCall(
        address transferHelper,
        uint256 balanceToConsume,
        address tokenToComsumeBalance,
        address destination
    ) external {
        _transferHelper = transferHelper;
        _balanceToConsume = balanceToConsume;
        _tokenToComsume = tokenToComsumeBalance;
        _destination = destination;
    }

    function _mockConsume() internal {
        if (_balanceToConsume > 0) {
            ITransferHelper(_transferHelper).transfer(_tokenToComsume, _balanceToConsume, _destination);
        }
    }

    /// @dev Simulates fee consumption configured through `mockConsumeOnNextCall`.
    function sendBridgeIouTokenMessageWithFeePayer(
        uint256, /*destinationChainId*/
        address, /*iouTokenRecipient*/
        uint256, /*iouTokenAmountRay*/
        address, /*bridgeAdapter*/
        address feePayer,
        uint256, /*gasLimit*/
        bytes calldata bridgeAdapterData
    ) external payable override {
        CcipAdapter.CcipFeeParams memory ccipFeeParams = abi.decode(bridgeAdapterData, (CcipAdapter.CcipFeeParams));
        if (ccipFeeParams.feeToken == Constants.NATIVE_CURRENCY) {
            if (msg.value > 0) {
                (bool ok,) = _transferHelper.call{value: msg.value}("");
                require(ok, Errors.NativeTransferFailed());
            }
        } else {
            require(msg.value == 0, Errors.InvalidParameter());
            if (_balanceToConsume > 0) {
                IERC20(ccipFeeParams.feeToken).safeTransferFrom(feePayer, _transferHelper, _balanceToConsume);
            }
        }
        _mockConsume();
    }

    function addFundsBridgeAdapter(address asset, uint256 chainId, address bridgeAdapter) external {}
    function removeFundsBridgeAdapter(address asset, uint256 chainId, address bridgeAdapter) external {}
    function addDataOnlyBridgeAdapter(uint256 chainId, address bridgeAdapter) external {}
    function disableDataOnlyBridgeAdapterSending(uint256 chainId, address bridgeAdapter) external {}
    function removeDataOnlyBridgeAdapter(uint256 chainId, address bridgeAdapter) external {}
    function receiveMessage(uint256 sourceChainId, address asset, uint256 amount, bytes memory data) external {}
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IAcrossSpokePoolV3} from "src/dependencies/across/IAcrossSpokePoolV3.sol";

contract MockAcrossSpokePool is IAcrossSpokePoolV3 {
    function depositV3(
        address depositor,
        address recipient,
        address inputToken,
        address outputToken,
        uint256 inputAmount,
        uint256 outputAmount,
        uint256 destinationChainId,
        address exclusiveRelayer,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        uint32 exclusivityDeadline,
        bytes calldata message
    ) external payable override {}
}

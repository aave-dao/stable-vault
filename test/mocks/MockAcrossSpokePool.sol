// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

// import {IAcrossSpokePoolV3} from "src/dependencies/across/IAcrossSpokePoolV3.sol";

/// @dev This was supposed to inherit IAcrossSpokePoolV3, but it causes stack too deep.
/// So we went for a fallback function instead.
// contract MockAcrossSpokePool is IAcrossSpokePoolV3 {
contract MockAcrossSpokePool {
    // function depositV3(
    //     address depositor,
    //     address recipient,
    //     address inputToken,
    //     address outputToken,
    //     uint256 inputAmount,
    //     uint256 outputAmount,
    //     uint256 destinationChainId,
    //     address exclusiveRelayer,
    //     uint32 quoteTimestamp,
    //     uint32 fillDeadline,
    //     uint32 exclusivityDeadline,
    //     bytes memory message
    // ) external payable override {}

    fallback() external payable {}

    receive() external payable {}
}

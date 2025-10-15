// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {console} from "forge-std/console.sol";

import {Client} from "@chainlink-ccip/contracts/libraries/Client.sol";
import {IRouterClient, MockCCIPRouter} from "./mocks/MockRouter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IAny2EVMMessageReceiver} from "@chainlink-ccip/contracts/interfaces/IAny2EVMMessageReceiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {TestErc20} from "./mocks/TestErc20.sol";

contract CCIPTest is Test {
    using SafeERC20 for IERC20;

    MockCCIPRouter public mockRouter;

    uint64 public constant ACCOUNTING_CHAIN_ID = 1;
    uint64 public constant EARNING_CHAIN_ID = 2;

    address _receiver;

    address _token;

    function setUp() public {
        mockRouter = new MockCCIPRouter();
        _receiver = address(new CCIPReceiver());
        console.log("_receiver: %s", _receiver);

        //Configure the Fee to 0.1 ether for native token fees
        mockRouter.setFee(0.1 ether);
        deal(address(this), 100 ether);

        _token = address(new TestErc20(18));
        console.log("Token: %s", _token);
        TestErc20(_token).mint(address(this), 10 ether);
    }

    function test_ccipSend() public {
        Client.EVM2AnyMessage memory message;

        uint256 amount = 1 ether;
        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](1);
        tokenAmounts[0] = Client.EVMTokenAmount(_token, amount);

        message.receiver = abi.encode(_receiver);
        message.data = abi.encode("Hello World");
        message.tokenAmounts = tokenAmounts;

        IERC20(_token).approve(address(mockRouter), amount);

        console.log("Sending the message...");
        mockRouter.ccipSend{value: 0.1 ether}(EARNING_CHAIN_ID, message);
    }
}

contract CCIPReceiver is IAny2EVMMessageReceiver, IERC165 {
    function ccipReceive(Client.Any2EVMMessage calldata message) external override {
        console.log("Message received:");
        console.log("\t%s", abi.decode(message.data, (string)));
        console.log("\tsender:");
        console.logBytes(message.sender);
        console.log("\tmessageId:");
        console.logBytes32(message.messageId);
        console.log("destTokenAmounts.length: %s", message.destTokenAmounts.length);
        for (uint256 i = 0; i < message.destTokenAmounts.length; i++) {
            console.log(
                "destTokenAmounts[%s].token: %s | amount: %s",
                i,
                message.destTokenAmounts[i].token,
                message.destTokenAmounts[i].amount
            );
        }
        console.log("Token Balance: %s", IERC20(message.destTokenAmounts[0].token).balanceOf(address(this)));
    }

    function supportsInterface(bytes4 interfaceId) public pure virtual override returns (bool) {
        return interfaceId == type(IAny2EVMMessageReceiver).interfaceId || interfaceId == type(IERC165).interfaceId;
    }
}

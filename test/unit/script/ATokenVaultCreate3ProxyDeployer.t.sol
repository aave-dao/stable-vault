// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {ATokenVaultCreate3ProxyDeployer} from "script/base/ATokenVaultCreate3ProxyDeployer.sol";
import {ATokenVaultProxyAddressLib} from "script/libraries/ATokenVaultProxyAddressLib.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {MockErc20} from "test/mocks/MockErc20.sol";

contract LockDepositInitializer {
    using SafeERC20 for IERC20;

    bool public initialized;
    address public initializerCaller;

    function initialize(address token, uint256 amount) external {
        require(!initialized, "already initialized");
        initialized = true;
        initializerCaller = msg.sender;
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
    }
}

contract ATokenVaultCreate3ProxyDeployerTest is Test {
    function test_constructorDeploysProxyAndPreservesInitializerCallerAsFundedDeployer() public {
        MockErc20 token = new MockErc20("Mock USD", "mUSD", 18);
        LockDepositInitializer implementation = new LockDepositInitializer();

        uint256 initialLockDeposit = 1e18;
        token.mint(address(this), initialLockDeposit);

        address proxyDeployerAddress = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address proxyAddress = ATokenVaultProxyAddressLib.computeProxyAddress(proxyDeployerAddress);

        token.approve(proxyDeployerAddress, initialLockDeposit);

        bytes memory initCalldata =
            abi.encodeCall(LockDepositInitializer.initialize, (address(token), initialLockDeposit));
        ATokenVaultCreate3ProxyDeployer proxyDeployer = new ATokenVaultCreate3ProxyDeployer({
            underlying: address(token),
            implementation: address(implementation),
            proxyAdminOwner: makeAddr("proxyAdminOwner"),
            initCalldata: initCalldata,
            depositor: address(this),
            initialLockDeposit: initialLockDeposit
        });

        assertEq(address(proxyDeployer), proxyDeployerAddress);
        assertEq(proxyDeployer.proxy(), proxyAddress);
        assertEq(token.balanceOf(proxyAddress), initialLockDeposit);
        assertEq(token.balanceOf(address(proxyDeployer)), 0);
        assertEq(token.allowance(address(proxyDeployer), proxyAddress), 0);
        assertEq(LockDepositInitializer(proxyAddress).initializerCaller(), proxyDeployerAddress);
    }
}

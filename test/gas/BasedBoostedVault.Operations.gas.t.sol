// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {IBasedBoostedVault} from "../../src/interfaces/IBasedBoostedVault.sol";
import {MathLib} from "../../src/libraries/MathLib.sol";
import {BaseTest} from "../BaseTest.t.sol";

contract BasedBoostedVaultOperationsGasTest is BaseTest {
    string internal NAMESPACE = "BasedBoostedVault.Operations";

    uint256 amount = 100e6;
    address user1 = makeAddr("USER1");
    address user2 = makeAddr("USER2");

    function setUp() public override {
        super.setUp();
    }

    function test_deposit() public {
        // Context: deposits to the default subvault

        _seedUser(user1);
        vm.prank(user1);
        vault.deposit(user1, address(USDC), amount);
        vm.snapshotGasLastCall(NAMESPACE, "deposit: user1 first deposit");

        _seedUser(user1);
        vm.prank(user1);
        vault.deposit(user1, address(USDC), amount);
        vm.snapshotGasLastCall(NAMESPACE, "deposit: user1 second deposit");

        _seedUser(user2);
        vm.prank(user2);
        vault.deposit(user2, address(USDC), amount);
        vm.snapshotGasLastCall(NAMESPACE, "deposit: user2 first deposit");

        _seedUser(user2);
        vm.prank(user2);
        vault.deposit(user2, address(USDC), amount);
        vm.snapshotGasLastCall(NAMESPACE, "deposit: user2 second deposit");
    }

    function test_setUserRate() public {
        _seedUser(user1);
        vm.prank(user1);
        vault.deposit(user1, address(USDC), amount);

        _seedUser(user2);
        vm.prank(user2);
        vault.deposit(user2, address(USDC), amount);

        uint256 newRate = 1_000000001547125957863212449; // 5% APY
        IBasedBoostedVault.UserRateData[] memory userRateData = new IBasedBoostedVault.UserRateData[](1);
        userRateData[0] = IBasedBoostedVault.UserRateData(user1, newRate);

        vm.prank(everyRoleAccount);
        vault.setUserRate(userRateData);
        vm.snapshotGasLastCall(NAMESPACE, "setUserRate: count: 1");

        newRate = 1_000000003022265980097387650; // 10% APY
        userRateData = new IBasedBoostedVault.UserRateData[](2);
        userRateData[0] = IBasedBoostedVault.UserRateData(user1, newRate);
        userRateData[1] = IBasedBoostedVault.UserRateData(user2, newRate);

        vm.prank(everyRoleAccount);
        vault.setUserRate(userRateData);
        vm.snapshotGasLastCall(NAMESPACE, "setUserRate: count: 2");

        uint256 numberOfUsers = 10;
        userRateData = new IBasedBoostedVault.UserRateData[](numberOfUsers);
        for (uint256 i = 0; i < numberOfUsers; i++) {
            address user = makeAddr(string(abi.encodePacked("USER:", i)));
            _seedUser(user);
            vm.prank(user);
            vault.deposit(user, address(USDC), amount);
            userRateData[i] = IBasedBoostedVault.UserRateData(user, newRate);
        }

        vm.prank(everyRoleAccount);
        vault.setUserRate(userRateData);
        vm.snapshotGasLastCall(NAMESPACE, "setUserRate: count: 10");
    }

    function _seedUser(address user) internal {
        USDC.mint(user, amount);
        vm.prank(user);
        USDC.approve(address(vault), amount);
    }
}

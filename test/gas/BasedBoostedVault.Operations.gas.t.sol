// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {BaseTest} from "../BaseTest.t.sol";

import {IBasedBoostedVault} from "../../src/interfaces/IBasedBoostedVault.sol";
import {AssetLib} from "../../src/libraries/AssetLib.sol";

contract BasedBoostedVaultOperationsGasTest is BaseTest {
    using AssetLib for uint256;

    string internal NAMESPACE = "BasedBoostedVault.Operations";

    uint256 amount = 100e6;
    address user1 = makeAddr("USER1");
    address user2 = makeAddr("USER2");

    function setUp() public override {
        super.setUp();
    }

    function test_deposit() public {
        // Context: deposits to the default sub-vault

        _seedUser(user1);
        vm.prank(user1);
        vm.startSnapshotGas(NAMESPACE, "deposit: user1 first deposit");
        vault.deposit(user1, address(USDC), amount);
        vm.stopSnapshotGas();

        _seedUser(user1);
        vm.prank(user1);
        vm.startSnapshotGas(NAMESPACE, "deposit: user1 second deposit");
        vault.deposit(user1, address(USDC), amount);
        vm.stopSnapshotGas();

        _seedUser(user2);
        vm.prank(user2);
        vm.startSnapshotGas(NAMESPACE, "deposit: user2 first deposit");
        vault.deposit(user2, address(USDC), amount);
        vm.stopSnapshotGas();

        _seedUser(user2);
        vm.prank(user2);
        vm.startSnapshotGas(NAMESPACE, "deposit: user2 second deposit");
        vault.deposit(user2, address(USDC), amount);
        vm.stopSnapshotGas();
    }

    function test_setUserRate() public {
        _seedUser(user1);
        vm.prank(user1);
        vault.deposit(user1, address(USDC), amount);

        _seedUser(user2);
        vm.prank(user2);
        vault.deposit(user2, address(USDC), amount);

        address user3 = makeAddr("USER3");
        _seedUser(user3);
        vm.prank(user3);
        vault.deposit(user3, address(USDC), amount);

        uint256 newRate = 1_000000001547125957863212449; // 5% APY
        IBasedBoostedVault.UserRateData[] memory userRateData = new IBasedBoostedVault.UserRateData[](1);
        userRateData[0] = IBasedBoostedVault.UserRateData(user1, newRate);

        vm.prank(everyRoleAccount);
        vm.startSnapshotGas(NAMESPACE, "setUserRate: count: 1");
        vault.setUserRate(userRateData);
        vm.stopSnapshotGas();

        newRate = 1_000000003022265980097387650; // 10% APY
        userRateData = new IBasedBoostedVault.UserRateData[](2);
        userRateData[0] = IBasedBoostedVault.UserRateData(user1, newRate);
        userRateData[1] = IBasedBoostedVault.UserRateData(user2, newRate);

        vm.prank(everyRoleAccount);
        vm.startSnapshotGas(NAMESPACE, "setUserRate: count: 2");
        vault.setUserRate(userRateData);
        vm.stopSnapshotGas();

        uint256 numberOfUsers = 11;
        userRateData = new IBasedBoostedVault.UserRateData[](numberOfUsers - 1);
        for (uint256 i = 0; i < numberOfUsers; i++) {
            address user = makeAddr(string(abi.encodePacked("USER:", i)));
            _seedUser(user);
            vm.prank(user);
            vault.deposit(user, address(USDC), amount);
            // Do not change the rate for the last user so that the sub-vault remains in active set (to avoid gas refund
            // for storage clearance).
            if (i != numberOfUsers - 1) {
                userRateData[i] = IBasedBoostedVault.UserRateData(user, newRate);
            }
        }

        vm.prank(everyRoleAccount);
        vm.startSnapshotGas(NAMESPACE, "setUserRate: count: 10");
        vault.setUserRate(userRateData);
        vm.stopSnapshotGas();

        numberOfUsers = 101;
        userRateData = new IBasedBoostedVault.UserRateData[](numberOfUsers - 1);
        for (uint256 i = 0; i < numberOfUsers; i++) {
            address user = makeAddr(string(abi.encodePacked("USER::", i)));
            _seedUser(user);
            vm.prank(user);
            vault.deposit(user, address(USDC), amount);
            // Do not change the rate for the last user so that the sub-vault remains in active set (to avoid gas refund
            // for storage clearance).
            if (i != numberOfUsers - 1) {
                userRateData[i] = IBasedBoostedVault.UserRateData(user, newRate);
            }
        }

        vm.prank(everyRoleAccount);
        vm.startSnapshotGas(NAMESPACE, "setUserRate: count: 100");
        vault.setUserRate(userRateData);
        vm.stopSnapshotGas();

        numberOfUsers = 1001;
        userRateData = new IBasedBoostedVault.UserRateData[](numberOfUsers - 1);
        for (uint256 i = 0; i < numberOfUsers; i++) {
            address user = makeAddr(string(abi.encodePacked("USER:::", i)));
            _seedUser(user);
            vm.prank(user);
            vault.deposit(user, address(USDC), amount);
            // Do not change the rate for the last user so that the sub-vault remains in active set (to avoid gas refund
            // for storage clearance).
            if (i != numberOfUsers - 1) {
                userRateData[i] = IBasedBoostedVault.UserRateData(user, newRate);
            }
        }

        vm.prank(everyRoleAccount);
        vm.startSnapshotGas(NAMESPACE, "setUserRate: count: 1000");
        vault.setUserRate(userRateData);
        vm.stopSnapshotGas();
    }

    function test_setUserRate_differentRates() public {
        // Context: each user will migrate to a unique and net new sub-vault which requires new storage writes.

        uint256 newRate = 1_000000001547125957863212449;
        IBasedBoostedVault.UserRateData[] memory userRateData = new IBasedBoostedVault.UserRateData[](0);

        uint256 numberOfUsers = 11;
        userRateData = new IBasedBoostedVault.UserRateData[](numberOfUsers - 1);
        for (uint256 i = 0; i < numberOfUsers; i++) {
            address user = makeAddr(string(abi.encodePacked("USER:", i)));
            _seedUser(user);
            vm.prank(user);
            vault.deposit(user, address(USDC), amount);
            // Do not change the rate for the last user so that the sub-vault remains in active set (to avoid gas refund
            // for storage clearance).
            if (i != numberOfUsers - 1) {
                userRateData[i] = IBasedBoostedVault.UserRateData(user, newRate++);
            }
        }

        vm.prank(everyRoleAccount);
        vm.startSnapshotGas(NAMESPACE, "setUserRate (different rates): count: 10");
        vault.setUserRate(userRateData);
        vm.stopSnapshotGas();

        numberOfUsers = 101;
        userRateData = new IBasedBoostedVault.UserRateData[](numberOfUsers - 1);
        for (uint256 i = 0; i < numberOfUsers; i++) {
            address user = makeAddr(string(abi.encodePacked("USER::", i)));
            _seedUser(user);
            vm.prank(user);
            vault.deposit(user, address(USDC), amount);
            // Do not change the rate for the last user so that the sub-vault remains in active set (to avoid gas refund
            // for storage clearance).
            if (i != numberOfUsers - 1) {
                userRateData[i] = IBasedBoostedVault.UserRateData(user, newRate++);
            }
        }

        vm.prank(everyRoleAccount);
        vm.startSnapshotGas(NAMESPACE, "setUserRate (different rates): count: 100");
        vault.setUserRate(userRateData);
        vm.stopSnapshotGas();

        numberOfUsers = 1001;
        userRateData = new IBasedBoostedVault.UserRateData[](numberOfUsers - 1);
        for (uint256 i = 0; i < numberOfUsers; i++) {
            address user = makeAddr(string(abi.encodePacked("USER:::", i)));
            _seedUser(user);
            vm.prank(user);
            vault.deposit(user, address(USDC), amount);
            // Do not change the rate for the last user so that the sub-vault remains in active set (to avoid gas refund
            // for storage clearance).
            if (i != numberOfUsers - 1) {
                userRateData[i] = IBasedBoostedVault.UserRateData(user, newRate++);
            }
        }

        vm.prank(everyRoleAccount);
        vm.startSnapshotGas(NAMESPACE, "setUserRate (different rates): count: 1000");
        vault.setUserRate(userRateData);
        vm.stopSnapshotGas();
    }

    function test_requestWithdrawal() public {
        _seedUser(user1);
        vm.prank(user1);
        vault.deposit(user1, address(USDC), amount);

        _seedUser(user2);
        vm.prank(user2);
        vault.deposit(user2, address(USDC), amount);

        uint256 partialWithdrawalAmountRay = (amount / 2).assetDecimalsToRay(address(USDC));

        vm.prank(user1);
        vm.startSnapshotGas(NAMESPACE, "requestWithdrawal: user1 requests partial withdrawal");
        vault.requestWithdrawal(user1, partialWithdrawalAmountRay);
        vm.stopSnapshotGas();

        vm.prank(user2);
        vm.startSnapshotGas(NAMESPACE, "requestWithdrawal: user2 requests partial withdrawal");
        vault.requestWithdrawal(user2, partialWithdrawalAmountRay);
        vm.stopSnapshotGas();

        vm.prank(user1);
        vm.startSnapshotGas(NAMESPACE, "requestWithdrawal: user1 requests full withdrawal");
        vault.requestWithdrawal(user1, 0);
        vm.stopSnapshotGas();

        vm.prank(user2);
        vm.startSnapshotGas(NAMESPACE, "requestWithdrawal: user2 requests full withdrawal");
        vault.requestWithdrawal(user2, 0);
        vm.stopSnapshotGas();
    }

    function test_executeWithdrawal() public {
        _seedUser(user1);
        vm.prank(user1);
        vault.deposit(user1, address(USDC), amount);

        _seedUser(user2);
        vm.prank(user2);
        vault.deposit(user2, address(USDC), amount);

        uint256 amountToWithdrawRay = amount.assetDecimalsToRay(address(USDC));

        vm.prank(user1);
        vault.requestWithdrawal(user1, amountToWithdrawRay);

        vm.prank(user2);
        vault.requestWithdrawal(user2, amountToWithdrawRay);

        vm.prank(user1);
        vm.startSnapshotGas(NAMESPACE, "executeWithdrawal: user1 executes withdrawal");
        vault.executeWithdrawal(user1, address(USDC), amountToWithdrawRay, "");
        vm.stopSnapshotGas();

        vm.prank(user2);
        vm.startSnapshotGas(NAMESPACE, "executeWithdrawal: user2 executes withdrawal");
        vault.executeWithdrawal(user2, address(USDC), amountToWithdrawRay, "");
        vm.stopSnapshotGas();
    }

    function _seedUser(address user) internal {
        USDC.mint(user, amount);
        vm.prank(user);
        USDC.approve(address(vault), amount);
    }
}

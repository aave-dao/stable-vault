// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import {Strings} from "openzeppelin-contracts/contracts/utils/Strings.sol";

import {IBasedBoostedVault} from "src/interfaces/IBasedBoostedVault.sol";
import {AssetLib} from "src/libraries/AssetLib.sol";

import {BaseTest} from "test/BaseTest.t.sol";

contract BasedBoostedVaultOperationsGasTest is BaseTest {
    using AssetLib for uint256;

    string internal NAMESPACE = "BasedBoostedVault.Operations";

    uint256 amount = 100e6;
    uint256 userSeed = 0;

    function setUp() public override {
        super.setUp();

        // First deposit ever has some extra gas cost related to minting default sub-vault shares and adding it to the
        // active sub-vaults array, which in practice should only happen once.
        // Also, we want the default sub-vault to always remain as an active sub-vault after any operation, which is
        // also the expected behavior in practice.
        // This is why we make the following deposit from a user that will never interact again with the vault.
        address user = _generateNewUser();
        _mintAndApprove(user);
        vm.prank(user);
        vault.deposit(user, address(USDC), amount);
    }

    function test_deposit_firstDepositFromUser_baseSubVault() public {
        address user = _generateNewUser();
        _mintAndApprove(user);

        vm.prank(user);
        vault.deposit(user, address(USDC), amount);
        vm.snapshotGasLastCall(NAMESPACE, "[deposit] base sub-vault - user's 1st deposit");
    }

    function test_deposit_secondDepositFromUser_baseSubVault() public {
        address user = _generateNewUser();

        _mintAndApprove(user);
        vm.prank(user);
        vault.deposit(user, address(USDC), amount);

        _mintAndApprove(user);
        vm.prank(user);
        vault.deposit(user, address(USDC), amount);
        vm.snapshotGasLastCall(NAMESPACE, "[deposit] base sub-vault - user's 2nd deposit");
    }

    function test_deposit_thirdDepositFromUser_baseSubVault() public {
        address user = _generateNewUser();

        _mintAndApprove(user);
        vm.prank(user);
        vault.deposit(user, address(USDC), amount);

        _mintAndApprove(user);
        vm.prank(user);
        vault.deposit(user, address(USDC), amount);

        _mintAndApprove(user);
        vm.prank(user);
        vault.deposit(user, address(USDC), amount);
        vm.snapshotGasLastCall(NAMESPACE, "[deposit] base sub-vault - user's 3rd deposit");
    }

    function test_setUserRate_fromDefaultSubVaultToNewSubVault() public {
        address user = _generateNewUser();

        _mintAndApprove(user);
        vm.prank(user);
        vault.deposit(user, address(USDC), amount);

        uint256 newRate = 1_000000001547125957863212449; // 5% APY
        IBasedBoostedVault.UserRateData[] memory userRateData = new IBasedBoostedVault.UserRateData[](1);
        userRateData[0] = IBasedBoostedVault.UserRateData(user, newRate);

        vm.prank(everyRoleAccount);
        vault.setUserRate(userRateData);
        vm.snapshotGasLastCall(NAMESPACE, "[setUserRate] default sub-vault to new sub-vault - 1 user");
    }

    function test_setUserRate_10Users_fromDefaultSubVaultToSameNewSubVault() public {
        uint256 numberOfUsers = 10;
        uint256 newRate = 1_000000001547125957863212449; // 5% APY
        IBasedBoostedVault.UserRateData[] memory userRateData = new IBasedBoostedVault.UserRateData[](numberOfUsers);
        for (uint256 i = 0; i < numberOfUsers; i++) {
            address user = _generateNewUser();
            _mintAndApprove(user);
            vm.prank(user);
            vault.deposit(user, address(USDC), amount);
            userRateData[i] = IBasedBoostedVault.UserRateData(user, newRate);
        }

        vm.prank(everyRoleAccount);
        vault.setUserRate(userRateData);
        vm.snapshotGasLastCall(NAMESPACE, "[setUserRate] default sub-vault to same new sub-vault - 10 users");
    }

    function test_setUserRate_100Users_fromDefaultSubVaultToSameNewSubVault() public {
        uint256 numberOfUsers = 100;
        uint256 newRate = 1_000000001547125957863212449; // 5% APY
        IBasedBoostedVault.UserRateData[] memory userRateData = new IBasedBoostedVault.UserRateData[](numberOfUsers);
        for (uint256 i = 0; i < numberOfUsers; i++) {
            address user = _generateNewUser();
            _mintAndApprove(user);
            vm.prank(user);
            vault.deposit(user, address(USDC), amount);
            userRateData[i] = IBasedBoostedVault.UserRateData(user, newRate);
        }

        vm.prank(everyRoleAccount);
        vault.setUserRate(userRateData);
        vm.snapshotGasLastCall(NAMESPACE, "[setUserRate] default sub-vault to same new sub-vault - 100 users");
    }

    function test_setUserRate_1000Users_fromDefaultSubVaultToSameNewSubVault() public {
        uint256 numberOfUsers = 1000;
        uint256 newRate = 1_000000001547125957863212449; // 5% APY
        IBasedBoostedVault.UserRateData[] memory userRateData = new IBasedBoostedVault.UserRateData[](numberOfUsers);
        for (uint256 i = 0; i < numberOfUsers; i++) {
            address user = _generateNewUser();
            _mintAndApprove(user);
            vm.prank(user);
            vault.deposit(user, address(USDC), amount);
            userRateData[i] = IBasedBoostedVault.UserRateData(user, newRate);
        }

        vm.prank(everyRoleAccount);
        vault.setUserRate(userRateData);
        vm.snapshotGasLastCall(NAMESPACE, "[setUserRate] default sub-vault to same new sub-vault - 1000 users");
    }

    function test_setUserRate_10Users_fromDefaultSubVaultToAllNewDifferentSubVaults() public {
        uint256 newRate = 1_000000001547125957863212449;

        uint256 numberOfUsers = 10;
        IBasedBoostedVault.UserRateData[] memory userRateData = new IBasedBoostedVault.UserRateData[](numberOfUsers);
        for (uint256 i = 0; i < numberOfUsers; i++) {
            address user = _generateNewUser();
            _mintAndApprove(user);
            vm.prank(user);
            vault.deposit(user, address(USDC), amount);

            userRateData[i] = IBasedBoostedVault.UserRateData(user, ++newRate);
        }

        vm.prank(everyRoleAccount);
        vault.setUserRate(userRateData);
        vm.snapshotGasLastCall(NAMESPACE, "[setUserRate] default sub-vault to all new different sub-vaults - 10 users");
    }

    function test_setUserRate_100Users_fromDefaultSubVaultToAllNewDifferentSubVaults() public {
        uint256 newRate = 1_000000001547125957863212449;

        uint256 numberOfUsers = 100;
        IBasedBoostedVault.UserRateData[] memory userRateData = new IBasedBoostedVault.UserRateData[](numberOfUsers);
        for (uint256 i = 0; i < numberOfUsers; i++) {
            address user = _generateNewUser();
            _mintAndApprove(user);
            vm.prank(user);
            vault.deposit(user, address(USDC), amount);

            userRateData[i] = IBasedBoostedVault.UserRateData(user, ++newRate);
        }

        vm.prank(everyRoleAccount);
        vault.setUserRate(userRateData);
        vm.snapshotGasLastCall(NAMESPACE, "[setUserRate] default sub-vault to all new different sub-vaults - 100 users");
    }

    function test_setUserRate_1000Users_fromDefaultSubVaultToAllNewDifferentSubVaults() public {
        uint256 newRate = 1_000000001547125957863212449;

        uint256 numberOfUsers = 1000;
        IBasedBoostedVault.UserRateData[] memory userRateData = new IBasedBoostedVault.UserRateData[](numberOfUsers);
        for (uint256 i = 0; i < numberOfUsers; i++) {
            address user = _generateNewUser();
            _mintAndApprove(user);
            vm.prank(user);
            vault.deposit(user, address(USDC), amount);

            userRateData[i] = IBasedBoostedVault.UserRateData(user, ++newRate);
        }

        vm.prank(everyRoleAccount);
        vault.setUserRate(userRateData);
        vm.snapshotGasLastCall(
            NAMESPACE, "[setUserRate] default sub-vault to all new different sub-vaults - 1000 users"
        );
    }

    function test_requestWithdrawal_partialWithdrawal() public {
        address user = _generateNewUser();

        _mintAndApprove(user);
        vm.prank(user);
        vault.deposit(user, address(USDC), amount);

        uint256 partialWithdrawalAmountRay = (amount / 2).assetDecimalsToRay(address(USDC));

        vm.prank(user);
        vault.requestWithdrawal(user, partialWithdrawalAmountRay);
        vm.snapshotGasLastCall(NAMESPACE, "[requestWithdrawal] partial withdrawal");
    }

    function test_requestWithdrawal_fullWithdrawal() public {
        address user = _generateNewUser();

        _mintAndApprove(user);
        vm.prank(user);
        vault.deposit(user, address(USDC), amount);

        uint256 fullWithdrawalAmountRay = amount.assetDecimalsToRay(address(USDC));

        vm.prank(user);
        vault.requestWithdrawal(user, fullWithdrawalAmountRay);
        vm.snapshotGasLastCall(NAMESPACE, "[requestWithdrawal] full withdrawal");
    }

    function test_executeWithdrawal_partialWithdrawal() public {
        address user = _generateNewUser();

        _mintAndApprove(user);
        vm.prank(user);
        vault.deposit(user, address(USDC), amount);

        uint256 partialWithdrawalAmountRay = (amount / 2).assetDecimalsToRay(address(USDC));

        vm.prank(user);
        vault.requestWithdrawal(user, partialWithdrawalAmountRay);

        vm.prank(user);
        vault.executeWithdrawal(user, address(USDC), 0, partialWithdrawalAmountRay, "");
        vm.snapshotGasLastCall(NAMESPACE, "[executeWithdrawal] partial withdrawal");
    }

    function test_executeWithdrawal_fullWithdrawal() public {
        address user = _generateNewUser();

        _mintAndApprove(user);
        vm.prank(user);
        vault.deposit(user, address(USDC), amount);

        uint256 fullWithdrawalAmountRay = amount.assetDecimalsToRay(address(USDC));

        vm.prank(user);
        vault.requestWithdrawal(user, fullWithdrawalAmountRay);

        vm.prank(user);
        vault.executeWithdrawal(user, address(USDC), 0, fullWithdrawalAmountRay, "");
        vm.snapshotGasLastCall(NAMESPACE, "[executeWithdrawal] full withdrawal");
    }

    function _generateNewUser() internal returns (address) {
        return _generateUser(userSeed++);
    }

    function _generateUser(uint256 seed) internal returns (address) {
        return makeAddr(string.concat("USER[", Strings.toString(seed), "]"));
    }

    function _mintAndApprove(address user) internal {
        USDC.mint(user, amount);
        vm.prank(user);
        USDC.approve(address(vault), amount);
    }
}

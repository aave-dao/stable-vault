// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";

import {BasedBoostedVault} from "./../src/accounting/BasedBoostedVault.sol";
import {FundsHandler} from "./../src/accounting/FundsHandler.sol";
import {IBasedBoostedVault} from "./../src/interfaces/IBasedBoostedVault.sol";
import {IFundsHandler} from "./../src/interfaces/IFundsHandler.sol";
import {AssetLib} from "./../src/libraries/AssetLib.sol";
import {ErrorsLib} from "./../src/libraries/ErrorsLib.sol";
import {MathLib} from "./../src/libraries/MathLib.sol";
import {IMockErc20, MockErc20} from "./mocks/MockErc20.sol";
import {MockFundsHandler} from "./mocks/MockFundsHandler.sol";
import {MockNonStandardErc20} from "./mocks/MockNonStandardErc20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

contract BasedBoostedVaultTest is Test {
    using MathLib for uint256;
    using AssetLib for uint256;
    using SafeERC20 for IMockErc20;

    address admin = makeAddr("admin");
    address manager = makeAddr("manager");

    uint256 constant DEFAULT_PER_SECOND_RATE = 1000000001243680656318820313; // ~4% APY
    IMockErc20 mockAsset;
    MockFundsHandler mockFundsHandler;
    IBasedBoostedVault bbv;

    function _deployDefaultAsset() internal returns (IMockErc20) {
        return IMockErc20(address(new MockNonStandardErc20("Test USDT", "tUSDT", 6)));
    }

    function _deployBasedBoostedVault(address adminParam, uint256 defaultSubVaultPerSecondRate)
        internal
        returns (IBasedBoostedVault)
    {
        return new BasedBoostedVault(adminParam, defaultSubVaultPerSecondRate);
    }

    function setUp() public {
        mockAsset = _deployDefaultAsset();
        bbv = _deployBasedBoostedVault(admin, DEFAULT_PER_SECOND_RATE);

        mockFundsHandler = new MockFundsHandler();

        vm.prank(admin);
        BasedBoostedVault(address(bbv)).setFundsHandler(address(mockFundsHandler));

        vm.prank(admin);
        bbv.updateAssetSupport(address(mockAsset), true);

        vm.prank(admin);
        BasedBoostedVault(address(bbv)).setManager(manager);
    }

    function test_constructor_setsTheExpectedValues(address expectedOwner, uint256 expectedDefaultSubVaultRate) public {
        vm.assume(expectedOwner != address(0));
        expectedDefaultSubVaultRate = _boundRate(expectedDefaultSubVaultRate);

        BasedBoostedVault newBbv = new BasedBoostedVault(expectedOwner, expectedDefaultSubVaultRate);

        assertEq(newBbv.owner(), expectedOwner);

        IBasedBoostedVault.SubVaultData memory defaultSubVault = newBbv.getDefaultSubVault();
        assertEq(defaultSubVault.perSecondRate, expectedDefaultSubVaultRate);
        assertEq(defaultSubVault.id, newBbv.getSubVaultIdByRate(expectedDefaultSubVaultRate));
    }

    function test_constructor_reverts_ifZeroAddressAsOwner() public {
        vm.expectRevert();
        new BasedBoostedVault(address(0), DEFAULT_PER_SECOND_RATE);
    }

    function test_constructor_reverts_ifInvalidDefaultSubVaultRate(uint256 invalidDefaultSubVaultRate) public {
        vm.assume(invalidDefaultSubVaultRate < MathLib.RAY);

        vm.expectRevert();
        new BasedBoostedVault(admin, MathLib.RAY - 1);
    }

    function test_deposit_firstUserDepositGoesToDefaultSubVault(address user, uint256 amount) public {
        vm.assume(user != address(0));
        amount = _boundAssetAmount(address(mockAsset), amount);

        IBasedBoostedVault.SubVaultData memory userSubVault = bbv.getUserSubVault(user);
        vm.assume(userSubVault.id == 0); // no prior deposits

        mockAsset.mint(user, amount);

        vm.prank(user);
        mockAsset.forceApprove(address(bbv), amount);

        vm.prank(user);
        bbv.deposit(user, address(mockAsset), amount);

        userSubVault = bbv.getUserSubVault(user);
        assertNotEq(userSubVault.id, 0); // subVault assigned after deposit

        IBasedBoostedVault.SubVaultData memory defaultSubVault = bbv.getDefaultSubVault();
        assertEq(userSubVault.id, defaultSubVault.id);
        assertEq(userSubVault.perSecondRate, defaultSubVault.perSecondRate);
    }

    function test_deposit_goesToCurrentUserSubVaultIfUserAlreadyHasAPosition(
        address user,
        uint256 firstDepositAmount,
        uint256 secondDepositAmount,
        uint256 userRate
    ) public {
        vm.assume(user != address(0));
        firstDepositAmount = _boundAssetAmount(address(mockAsset), firstDepositAmount);
        secondDepositAmount = _boundAssetAmount(address(mockAsset), secondDepositAmount);
        // Assumes the sum of the two deposits does not exceed the max expected deposit amount
        vm.assume(
            _boundAssetAmount(address(mockAsset), firstDepositAmount + secondDepositAmount)
                == firstDepositAmount + secondDepositAmount
        );
        userRate = _boundRate(userRate);

        mockAsset.mint(user, firstDepositAmount + secondDepositAmount);

        vm.assume(userRate != bbv.getDefaultSubVault().perSecondRate);
        vm.assume(bbv.getUserSubVault(user).id == 0); // no prior deposits

        vm.prank(user);
        mockAsset.forceApprove(address(bbv), firstDepositAmount);

        vm.prank(user);
        bbv.deposit(user, address(mockAsset), firstDepositAmount);

        assertEq(bbv.getUserSubVault(user).id, bbv.getDefaultSubVault().id);

        vm.prank(manager);
        bbv.setUserRate(user, userRate);

        IBasedBoostedVault.SubVaultData memory userVaultBeforeSecondDeposit = bbv.getUserSubVault(user);
        assertNotEq(userVaultBeforeSecondDeposit.id, bbv.getDefaultSubVault().id);

        vm.prank(user);
        mockAsset.forceApprove(address(bbv), secondDepositAmount);

        vm.prank(user);
        bbv.deposit(user, address(mockAsset), secondDepositAmount);

        IBasedBoostedVault.SubVaultData memory userVaultAfterSecondDeposit = bbv.getUserSubVault(user);
        assertEq(userVaultBeforeSecondDeposit.id, userVaultAfterSecondDeposit.id);
        assertEq(userVaultBeforeSecondDeposit.perSecondRate, userVaultAfterSecondDeposit.perSecondRate);
    }

    function test_deposit_reverts_ifAmountIsZero(address user) public {
        vm.assume(user != address(0));

        vm.prank(user);
        vm.expectRevert(ErrorsLib.InvalidAmount.selector);
        bbv.deposit(user, address(mockAsset), 0);
    }

    function test_deposit_callsFundsHandlerToProcessDepositWithExpectedParams(address user, uint256 amount) public {
        vm.assume(user != address(0));
        amount = _boundAssetAmount(address(mockAsset), amount);

        mockAsset.mint(user, amount);

        vm.prank(user);
        mockAsset.forceApprove(address(bbv), amount);

        vm.expectCall(
            address(mockFundsHandler),
            abi.encodeWithSelector(IFundsHandler.processDeposit.selector, address(mockAsset), amount)
        );

        vm.prank(user);
        bbv.deposit(user, address(mockAsset), amount);
    }

    function test_setUserRate_reverts_ifUserDoesNotHaveAPosition(address user, uint256 newPerSecondRate) public {
        vm.assume(user != address(0));
        vm.assume(bbv.getUserSubVault(user).id == 0); // no prior deposits
        newPerSecondRate = _boundRate(newPerSecondRate);
        vm.assume(newPerSecondRate != bbv.getDefaultSubVault().perSecondRate);

        vm.prank(manager);
        vm.expectRevert(IBasedBoostedVault.NonExistentPosition.selector);
        bbv.setUserRate(user, DEFAULT_PER_SECOND_RATE);
    }

    function test_setUserRate_reverts_ifSettingTheSameRateHeAlreadyHas(address user, uint256 amount) public {
        vm.assume(user != address(0));
        amount = _boundAssetAmount(address(mockAsset), amount);

        mockAsset.mint(user, amount);

        vm.prank(user);
        mockAsset.forceApprove(address(bbv), amount);

        vm.prank(user);
        bbv.deposit(user, address(mockAsset), amount);

        uint256 currentRate = bbv.getUserSubVault(user).perSecondRate;

        vm.prank(manager);
        vm.expectRevert(IBasedBoostedVault.RedundantRate.selector);
        bbv.setUserRate(user, currentRate);
    }

    function test_setUserRate_twoUsersWithSameRateLandsInTheSameSubVault(
        address user1,
        address user2,
        uint256 amount1,
        uint256 amount2,
        uint256 newRate
    ) public {
        vm.assume(user1 != address(0));
        vm.assume(user2 != address(0));
        vm.assume(user1 != user2);
        amount1 = _boundAssetAmount(address(mockAsset), amount1);
        amount2 = _boundAssetAmount(address(mockAsset), amount2);
        newRate = _boundRate(newRate);
        vm.assume(newRate != bbv.getDefaultSubVault().perSecondRate);

        mockAsset.mint(user1, amount1);
        mockAsset.mint(user2, amount2);

        vm.prank(user1);
        mockAsset.forceApprove(address(bbv), amount1);
        vm.prank(user1);
        bbv.deposit(user1, address(mockAsset), amount1);

        vm.prank(manager);
        bbv.setUserRate(user1, newRate);

        IBasedBoostedVault.SubVaultData memory user1SubVault = bbv.getUserSubVault(user1);

        vm.prank(user2);
        mockAsset.forceApprove(address(bbv), amount2);
        vm.prank(user2);
        bbv.deposit(user2, address(mockAsset), amount2);

        IBasedBoostedVault.SubVaultData memory user2SubVault = bbv.getUserSubVault(user2);

        // SubVaults are not the same because user2 is still at the default subVault
        assertNotEq(user2SubVault.id, user1SubVault.id);
        assertNotEq(user2SubVault.perSecondRate, newRate);

        vm.prank(manager);
        bbv.setUserRate(user2, newRate);

        // SubVaults must match after setting the same new rate as user1 for user2
        user2SubVault = bbv.getUserSubVault(user2);
        assertEq(user2SubVault.id, user1SubVault.id);
        assertEq(user2SubVault.perSecondRate, newRate);
    }

    //////////////////////// HELPERS ////////////////////////
    // TODO: Move to BaseTest or Helpers contract

    function _boundRate(uint256 rate) internal pure returns (uint256) {
        return bound(rate, MathLib.RAY, type(uint256).max);
    }

    function _boundAssetAmount(address asset, uint256 amount) internal view returns (uint256) {
        return bound(amount, 1, 10 ** IMockErc20(asset).decimals());
    }

    function _boundRayAmount(uint256 amount) internal pure returns (uint256) {
        return bound(amount, 1, MathLib.RAY);
    }

    function _boundAmount(uint256 amount, uint256 scaleFactor) internal pure returns (uint256) {
        return bound(amount, 1, 100_000_000_000_000 * scaleFactor); // 100 trillion
    }
}

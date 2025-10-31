// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BasedBoostedVault} from "./../src/accounting/BasedBoostedVault.sol";
import {IBasedBoostedVault} from "./../src/interfaces/IBasedBoostedVault.sol";
import {IFundsHandler} from "./../src/interfaces/IFundsHandler.sol";
import {AssetLib} from "./../src/libraries/AssetLib.sol";
import {ErrorsLib} from "./../src/libraries/ErrorsLib.sol";
import {MathLib} from "./../src/libraries/MathLib.sol";
import {TestWithHelpers} from "./helpers/TestWithHelpers.sol";
import {MockAccessManager} from "./mocks/MockAccessManager.sol";
import {MockAssetRegistry} from "./mocks/MockAssetRegistry.sol";
import {IMockErc20} from "./mocks/MockErc20.sol";
import {MockFundsHandler} from "./mocks/MockFundsHandler.sol";
import {MockIouToken} from "./mocks/MockIouToken.sol";
import {MockNonStandardErc20} from "./mocks/MockNonStandardErc20.sol";

contract BasedBoostedVaultTest is TestWithHelpers {
    using MathLib for uint256;
    using AssetLib for uint256;
    using SafeERC20 for IMockErc20;

    address immutable proxyAdmin = makeAddr("PROXY_ADMIN");
    address immutable admin = makeAddr("admin");
    address immutable manager = makeAddr("manager");

    uint256 constant DEFAULT_PER_SECOND_RATE = 1000000001243680656318820313; // ~4% APY
    MockAccessManager mockAccessManager;
    IMockErc20 mockAsset;
    MockFundsHandler mockFundsHandler;
    MockIouToken mockIouToken;
    MockAssetRegistry mockAssetRegistry;
    IBasedBoostedVault bbv;

    function _deployDefaultAsset() internal returns (IMockErc20) {
        return IMockErc20(address(new MockNonStandardErc20("Test USDT", "tUSDT", 6)));
    }

    function _deployBasedBoostedVault(
        address adminParam,
        uint256 maxPerSecondRate,
        uint256 defaultSubVaultPerSecondRate,
        address iouToken,
        address fundsHandler,
        address assetRegistry
    ) internal returns (IBasedBoostedVault) {
        address vaultImpl = address(new BasedBoostedVault(maxPerSecondRate, iouToken, fundsHandler));
        return BasedBoostedVault(
            address(
                new TransparentUpgradeableProxy(
                    vaultImpl,
                    proxyAdmin,
                    abi.encodeCall(
                        BasedBoostedVault.initialize, (adminParam, defaultSubVaultPerSecondRate, assetRegistry)
                    )
                )
            )
        );
    }

    function setUp() public {
        mockAccessManager = new MockAccessManager(admin);
        mockIouToken = new MockIouToken(address(mockAccessManager));
        mockAssetRegistry = new MockAssetRegistry();
        mockAsset = _deployDefaultAsset();
        mockFundsHandler = new MockFundsHandler();
        bbv = _deployBasedBoostedVault(
            address(mockAccessManager),
            DEFAULT_MAX_PER_SECOND_RATE,
            DEFAULT_PER_SECOND_RATE,
            address(mockIouToken),
            address(mockFundsHandler),
            address(mockAssetRegistry)
        );
    }

    // TODO: initializer and constructor tests

    // function test_constructor_setsTheExpectedValues(address expectedOwner, uint256 expectedDefaultSubVaultRate)
    // public { vm.assume(expectedOwner != address(0));
    //     expectedDefaultSubVaultRate = _boundRate(expectedDefaultSubVaultRate);

    //     BasedBoostedVault newBbv = new BasedBoostedVault(
    //         expectedOwner,
    //         DEFAULT_MAX_PER_SECOND_RATE,
    //         expectedDefaultSubVaultRate,
    //         address(mockIouToken),
    //         address(mockFundsHandler),
    //         address(mockAssetRegistry)
    //     );

    //     assertEq(newBbv.authority(), expectedOwner);

    //     IBasedBoostedVault.SubVaultData memory defaultSubVault = newBbv.getDefaultSubVault();
    //     assertEq(defaultSubVault.perSecondRate, expectedDefaultSubVaultRate);
    //     assertEq(defaultSubVault.id, newBbv.getSubVaultIdByRate(expectedDefaultSubVaultRate));
    // }

    // function test_constructor_reverts_ifZeroAddressAsOwner() public {
    //     vm.expectRevert();
    //     new BasedBoostedVault(
    //         address(0),
    //         DEFAULT_MAX_PER_SECOND_RATE,
    //         DEFAULT_PER_SECOND_RATE,
    //         address(mockIouToken),
    //         address(mockFundsHandler),
    //         address(mockAssetRegistry)
    //     );
    // }

    // function test_constructor_reverts_ifInvalidDefaultSubVaultRate(uint256 invalidDefaultSubVaultRate) public {
    //     vm.assume(invalidDefaultSubVaultRate < MathLib.RAY);

    //     vm.expectRevert();
    //     new BasedBoostedVault(
    //         address(mockAccessManager),
    //         DEFAULT_MAX_PER_SECOND_RATE,
    //         MathLib.RAY - 1,
    //         address(mockIouToken),
    //         address(mockFundsHandler),
    //         address(mockAssetRegistry)
    //     );
    // }

    function test_deposit_firstUserDepositGoesToDefaultSubVault(address user, uint256 amount) public {
        vm.assume(user != address(0));
        vm.assume(user != proxyAdmin);
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

        assertEq(bbv.getGlobalOriginalDepositAmount(), AssetLib.assetDecimalsToRay(amount, address(mockAsset)));
    }

    function test_deposit_goesToCurrentUserSubVaultIfUserAlreadyHasAPosition(
        address user,
        uint256 firstDepositAmount,
        uint256 secondDepositAmount,
        uint256 userRate
    ) public {
        vm.assume(user != address(0) && user != proxyAdmin);
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
        _setUserRate(user, userRate);

        IBasedBoostedVault.SubVaultData memory userVaultBeforeSecondDeposit = bbv.getUserSubVault(user);
        assertNotEq(userVaultBeforeSecondDeposit.id, bbv.getDefaultSubVault().id);

        vm.prank(user);
        mockAsset.forceApprove(address(bbv), secondDepositAmount);

        vm.prank(user);
        bbv.deposit(user, address(mockAsset), secondDepositAmount);

        IBasedBoostedVault.SubVaultData memory userVaultAfterSecondDeposit = bbv.getUserSubVault(user);
        assertEq(userVaultBeforeSecondDeposit.id, userVaultAfterSecondDeposit.id);
        assertEq(userVaultBeforeSecondDeposit.perSecondRate, userVaultAfterSecondDeposit.perSecondRate);

        assertEq(
            bbv.getGlobalOriginalDepositAmount(),
            AssetLib.assetDecimalsToRay(firstDepositAmount + secondDepositAmount, address(mockAsset))
        );
    }

    function test_deposit_reverts_ifAmountIsZero(address user) public {
        vm.assume(user != address(0) && user != proxyAdmin);

        vm.prank(user);
        vm.expectRevert(ErrorsLib.InvalidAmount.selector);
        bbv.deposit(user, address(mockAsset), 0);
    }

    function test_deposit_reverts_ifAssetIsNotAllowedToDepositIntoBBV(address msgSender, address user, uint256 amount)
        public
    {
        vm.assume(msgSender != address(0) && msgSender != proxyAdmin);
        vm.assume(user != address(0) && user != proxyAdmin);
        vm.assume(msgSender != user);

        amount = _boundAssetAmount(address(mockAsset), amount);
        mockAsset.mint(user, amount);

        vm.prank(user);
        mockAsset.forceApprove(address(bbv), amount);

        mockAssetRegistry.mockToDisallowAssetDepositsIntoBBV(address(mockAsset));

        vm.prank(user);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnsupportedAsset.selector, address(mockAsset)));
        bbv.deposit(user, address(mockAsset), amount);
    }

    function test_deposit_reverts_ifMsgSenderIsNotTheUserDepositing(address user, uint256 amount) public {
        vm.assume(user != address(0) && user != proxyAdmin);
        amount = _boundAssetAmount(address(mockAsset), amount);

        mockAsset.mint(user, amount);

        vm.prank(user);
        vm.expectRevert((IBasedBoostedVault.InvalidMsgSender.selector));
        bbv.deposit(makeAddr("otherUser"), address(mockAsset), amount);
    }

    function test_deposit_callsFundsHandlerToProcessDepositWithExpectedParams(address user, uint256 amount) public {
        vm.assume(user != address(0) && user != proxyAdmin);
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
        vm.assume(user != address(0) && user != proxyAdmin);
        vm.assume(bbv.getUserSubVault(user).id == 0); // no prior deposits
        newPerSecondRate = _boundRate(newPerSecondRate);
        vm.assume(newPerSecondRate != bbv.getDefaultSubVault().perSecondRate);

        vm.prank(manager);
        vm.expectRevert(IBasedBoostedVault.NonExistentPosition.selector);
        _setUserRate(user, DEFAULT_PER_SECOND_RATE);
    }

    function test_setUserRate_reverts_ifSettingTheSameRateHeAlreadyHas(address user, uint256 amount) public {
        vm.assume(user != address(0) && user != proxyAdmin);
        amount = _boundAssetAmount(address(mockAsset), amount);

        mockAsset.mint(user, amount);

        vm.prank(user);
        mockAsset.forceApprove(address(bbv), amount);

        vm.prank(user);
        bbv.deposit(user, address(mockAsset), amount);

        uint256 currentRate = bbv.getUserSubVault(user).perSecondRate;

        vm.prank(manager);
        vm.expectRevert(IBasedBoostedVault.RedundantRate.selector);
        _setUserRate(user, currentRate);
    }

    function test_setUserRate_twoUsersWithSameRateLandsInTheSameSubVault(
        address user1,
        address user2,
        uint256 amount1,
        uint256 amount2,
        uint256 newRate
    ) public {
        vm.assume(user1 != address(0) && user1 != proxyAdmin);
        vm.assume(user2 != address(0) && user2 != proxyAdmin);
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
        _setUserRate(user1, newRate);

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
        _setUserRate(user2, newRate);

        // SubVaults must match after setting the same new rate as user1 for user2
        user2SubVault = bbv.getUserSubVault(user2);
        assertEq(user2SubVault.id, user1SubVault.id);
        assertEq(user2SubVault.perSecondRate, newRate);
    }

    function test_setDefaultSubVault_setsExistingVaultIfAlreadyExistsWithGivenRate(
        address user,
        uint256 amount,
        uint256 newPerSecondRate
    ) public {
        newPerSecondRate = _boundRate(newPerSecondRate);
        vm.assume(bbv.getDefaultSubVault().perSecondRate != newPerSecondRate);

        vm.assume(user != address(0) && user != proxyAdmin);
        amount = _boundAssetAmount(address(mockAsset), amount);
        mockAsset.mint(user, amount);
        vm.prank(user);
        mockAsset.forceApprove(address(bbv), amount);
        vm.prank(user);
        bbv.deposit(user, address(mockAsset), amount);

        vm.prank(manager);
        _setUserRate(user, newPerSecondRate);
        uint256 expectedSubVaultId = bbv.getSubVaultIdByRate(newPerSecondRate);

        vm.prank(manager);
        bbv.setDefaultSubVault(newPerSecondRate);

        assertEq(bbv.getDefaultSubVault().perSecondRate, newPerSecondRate);
        assertEq(bbv.getSubVaultIdByRate(newPerSecondRate), expectedSubVaultId);
        assertEq(bbv.getSubVaultRateById(expectedSubVaultId), newPerSecondRate);
    }

    function test_setDefaultSubVault_settingToSameRateAsCurrentDefaultSubVaultIsAllowedAndDoesNothing(uint256 newPerSecondRate)
        public
    {
        newPerSecondRate = _boundRate(newPerSecondRate);

        vm.prank(manager);
        bbv.setDefaultSubVault(newPerSecondRate);

        assertEq(bbv.getDefaultSubVault().perSecondRate, newPerSecondRate);
        assertEq(bbv.getSubVaultIdByRate(newPerSecondRate), bbv.getDefaultSubVault().id);
        assertEq(bbv.getSubVaultRateById(bbv.getDefaultSubVault().id), newPerSecondRate);

        uint256 sameDefaultSubVaultId = bbv.getDefaultSubVault().id;

        vm.prank(manager);
        bbv.setDefaultSubVault(newPerSecondRate);

        assertEq(bbv.getDefaultSubVault().perSecondRate, newPerSecondRate);
        assertEq(bbv.getSubVaultIdByRate(newPerSecondRate), sameDefaultSubVaultId);
        assertEq(bbv.getSubVaultRateById(sameDefaultSubVaultId), newPerSecondRate);
    }

    function test_setDefaultSubVault_createsANewSubVaultIfNoSubVaultHasTheGivenRate(
        uint256 newPerSecondRate,
        uint256 anotherNewPerSecondRate
    ) public {
        vm.assume(newPerSecondRate != anotherNewPerSecondRate);
        newPerSecondRate = _boundRate(newPerSecondRate);
        anotherNewPerSecondRate = _boundRate(anotherNewPerSecondRate);
        vm.assume(bbv.getSubVaultIdByRate(newPerSecondRate) == 0);
        vm.assume(bbv.getSubVaultIdByRate(anotherNewPerSecondRate) == 0);

        vm.prank(manager);
        bbv.setDefaultSubVault(newPerSecondRate);

        uint256 lastId = bbv.getDefaultSubVault().id;

        assertEq(bbv.getDefaultSubVault().perSecondRate, newPerSecondRate);
        assertEq(bbv.getSubVaultIdByRate(newPerSecondRate), lastId);
        assertEq(bbv.getSubVaultRateById(lastId), newPerSecondRate);

        uint256 expectedId = lastId + 1;

        assertEq(bbv.getSubVaultIdByRate(anotherNewPerSecondRate), 0);
        assertEq(bbv.getSubVaultRateById(expectedId), 0);

        vm.prank(manager);
        bbv.setDefaultSubVault(anotherNewPerSecondRate);

        assertEq(bbv.getDefaultSubVault().perSecondRate, anotherNewPerSecondRate);
        assertEq(bbv.getSubVaultIdByRate(anotherNewPerSecondRate), expectedId);
        assertEq(bbv.getSubVaultRateById(expectedId), anotherNewPerSecondRate);
    }

    function test_setDefaultSubVault_reverts_ifMsgSenderIsNotTheManager(address msgSender, uint256 newPerSecondRate)
        public
    {
        vm.assume(msgSender != address(0) && msgSender != proxyAdmin);
        vm.assume(msgSender != manager);
        newPerSecondRate = _boundRate(newPerSecondRate);

        mockAccessManager.mockRejectCall(msgSender, address(bbv), IBasedBoostedVault.setDefaultSubVault.selector, 0);
        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, msgSender));
        vm.prank(msgSender);
        bbv.setDefaultSubVault(newPerSecondRate);
    }

    function test_setDefaultSubVault_reverts_ifNewRateIsInvalid(uint256 invalidPerSecondRate) public {
        vm.assume(invalidPerSecondRate < MathLib.RAY);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IBasedBoostedVault.InvalidRate.selector));
        bbv.setDefaultSubVault(invalidPerSecondRate);
    }

    function test_getAggregatedBalance_returnsExpectedValue(uint256 expectedAssets) public {
        expectedAssets = _boundRayAmount(expectedAssets);

        mockFundsHandler.mockAggregatedBalance(expectedAssets);
        vm.expectCall(address(mockFundsHandler), abi.encodeWithSelector(IFundsHandler.getAggregatedBalance.selector));

        uint256 actualAssets = bbv.getAggregatedBalance();

        assertEq(actualAssets, expectedAssets);
    }

    ////////////////////////////// HELPERS ///////////////////////////////

    function _setUserRate(address user, uint256 newPerSecondRate) public {
        IBasedBoostedVault.UserRateData[] memory userRateData = new IBasedBoostedVault.UserRateData[](1);
        userRateData[0] = IBasedBoostedVault.UserRateData(user, newPerSecondRate);
        bbv.setUserRate(userRateData);
    }
}

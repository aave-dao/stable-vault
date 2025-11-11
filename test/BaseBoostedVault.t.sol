// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {BasedBoostedVault} from "./../src/accounting/BasedBoostedVault.sol";
import {IBasedBoostedVault} from "./../src/interfaces/IBasedBoostedVault.sol";
import {IFundsHandler} from "./../src/interfaces/IFundsHandler.sol";
import {IRescuableAssets} from "./../src/interfaces/IRescuableAssets.sol";
import {AssetLib} from "./../src/libraries/AssetLib.sol";
import {ErrorsLib} from "./../src/libraries/ErrorsLib.sol";
import {MathLib} from "./../src/libraries/MathLib.sol";
import {TestWithHelpers} from "./helpers/TestWithHelpers.sol";
import {_toAddressArray, _toUint256Array} from "./helpers/TypeHelpers.sol";
import {MockAccessManager} from "./mocks/MockAccessManager.sol";
import {MockAssetRegistry} from "./mocks/MockAssetRegistry.sol";
import {MockErc20} from "./mocks/MockErc20.sol";
import {IMockErc20} from "./mocks/MockErc20.sol";
import {MockFundsHandler} from "./mocks/MockFundsHandler.sol";
import {MockIouTokenManager} from "./mocks/MockIouTokenManager.sol";
import {MockNonStandardErc20} from "./mocks/MockNonStandardErc20.sol";
import {MockTransferHelper} from "./mocks/MockTransferHelper.sol";

contract BasedBoostedVaultTest is TestWithHelpers {
    using MathLib for uint256;
    using AssetLib for uint256;
    using SafeERC20 for IMockErc20;

    address admin = makeAddr("admin");
    address manager = makeAddr("manager");

    uint256 constant DEFAULT_PER_SECOND_RATE = 1000000001243680656318820313; // ~4% APY
    MockAccessManager mockAccessManager;
    IMockErc20 mockAsset;
    MockFundsHandler mockFundsHandler;
    MockErc20 mockIouToken;
    MockIouTokenManager mockIouTokenManager;
    MockAssetRegistry mockAssetRegistry;
    MockTransferHelper mockTransferHelper;
    IBasedBoostedVault bbv;

    function _deployDefaultAsset() internal returns (IMockErc20) {
        return IMockErc20(address(new MockNonStandardErc20("Test USDT", "tUSDT", 6)));
    }

    function _deployBasedBoostedVault(
        address accessManager,
        uint256 maxPerSecondRate,
        uint256 defaultSubVaultPerSecondRate,
        address iouTokenManager,
        address fundsHandler,
        address assetRegistry,
        address transferHelper
    ) internal returns (IBasedBoostedVault) {
        address vaultImpl = address(
            new BasedBoostedVault(maxPerSecondRate, iouTokenManager, fundsHandler, transferHelper)
        );
        return BasedBoostedVault(
            address(
                new TransparentUpgradeableProxy(
                    vaultImpl,
                    address(this),
                    abi.encodeCall(
                        BasedBoostedVault.initialize, (accessManager, defaultSubVaultPerSecondRate, assetRegistry)
                    )
                )
            )
        );
    }

    function setUp() public {
        mockAccessManager = new MockAccessManager(admin);
        mockIouToken = new MockErc20("I Owe You Tokens", "IOU", 18);
        mockIouTokenManager = new MockIouTokenManager();
        mockIouTokenManager.mockIouToken(address(mockIouToken));
        mockAssetRegistry = new MockAssetRegistry();
        mockAsset = _deployDefaultAsset();
        mockFundsHandler = new MockFundsHandler();
        mockTransferHelper = new MockTransferHelper();
        bbv = _deployBasedBoostedVault(
            address(mockAccessManager),
            DEFAULT_MAX_PER_SECOND_RATE,
            DEFAULT_PER_SECOND_RATE,
            address(mockIouTokenManager),
            address(mockFundsHandler),
            address(mockAssetRegistry),
            address(mockTransferHelper)
        );
    }

    function test_constructor_setsTheExpectedValues(
        uint256 expectedMaxValidPerSecondRate,
        address expectedIouManager,
        address expectedFundsHandler,
        address expectedTransferHelper
    ) public {
        vm.assume(expectedIouManager != address(0));
        vm.assume(expectedFundsHandler != address(0));
        vm.assume(expectedTransferHelper != address(0));
        vm.assume(expectedMaxValidPerSecondRate > MathLib.RAY);

        BasedBoostedVault newBbv = new BasedBoostedVault(
            expectedMaxValidPerSecondRate, expectedIouManager, expectedFundsHandler, expectedTransferHelper
        );

        assertEq(newBbv.getMaxValidPerSecondRate(), expectedMaxValidPerSecondRate);
    }

    function test_constructor_reverts_ifInvalidMaxValidPerSecondRate(uint256 invalidMaxValidPerSecondRate) public {
        vm.assume(invalidMaxValidPerSecondRate <= MathLib.RAY);

        vm.expectRevert(IBasedBoostedVault.InvalidRate.selector);
        new BasedBoostedVault(
            invalidMaxValidPerSecondRate,
            address(mockIouTokenManager),
            address(mockFundsHandler),
            address(mockTransferHelper)
        );
    }

    function test_initialize_setsTheExpectedValues(
        address expectedAccessManager,
        uint256 expectedDefaultSubVaultRate,
        address expectedAssetRegistry
    ) public {
        vm.assume(expectedAccessManager != address(0));
        vm.assume(expectedAssetRegistry != address(0));
        expectedDefaultSubVaultRate = _boundRate(expectedDefaultSubVaultRate);

        address bbvImpl = address(
            new BasedBoostedVault(
                DEFAULT_MAX_PER_SECOND_RATE,
                address(mockIouTokenManager),
                address(mockFundsHandler),
                address(mockTransferHelper)
            )
        );

        BasedBoostedVault newBbv = BasedBoostedVault(
            address(
                new TransparentUpgradeableProxy(
                    bbvImpl,
                    address(this),
                    abi.encodeCall(
                        BasedBoostedVault.initialize,
                        (expectedAccessManager, expectedDefaultSubVaultRate, expectedAssetRegistry)
                    )
                )
            )
        );

        IBasedBoostedVault.SubVaultData memory defaultSubVault = newBbv.getDefaultSubVault();
        assertEq(defaultSubVault.perSecondRate, expectedDefaultSubVaultRate);
        assertEq(defaultSubVault.id, newBbv.getSubVaultIdByRate(expectedDefaultSubVaultRate));
    }

    function test_initialize_reverts_ifInvalidDefaultSubVaultRate(uint256 invalidDefaultSubVaultRate) public {
        vm.assume(invalidDefaultSubVaultRate < MathLib.RAY || invalidDefaultSubVaultRate > DEFAULT_MAX_PER_SECOND_RATE);

        address bbvImpl = address(
            new BasedBoostedVault(
                DEFAULT_MAX_PER_SECOND_RATE,
                address(mockIouTokenManager),
                address(mockFundsHandler),
                address(mockTransferHelper)
            )
        );

        vm.expectRevert(IBasedBoostedVault.InvalidRate.selector);
        BasedBoostedVault(
            address(
                new TransparentUpgradeableProxy(
                    bbvImpl,
                    address(this),
                    abi.encodeCall(
                        BasedBoostedVault.initialize,
                        (address(mockAccessManager), invalidDefaultSubVaultRate, address(mockAssetRegistry))
                    )
                )
            )
        );
    }

    function test_deposit_firstUserDepositGoesToDefaultSubVault(address user, uint256 amount) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(bbv));
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

        assertEq(bbv.getGlobalOriginalDepositAmount(), amount.assetDecimalsToRay(address(mockAsset)));
    }

    function test_deposit_goesToCurrentUserSubVaultIfUserAlreadyHasAPosition(
        address user,
        uint256 firstDepositAmount,
        uint256 secondDepositAmount,
        uint256 userRate
    ) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(bbv));
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
            (firstDepositAmount + secondDepositAmount).assetDecimalsToRay(address(mockAsset))
        );
    }

    function test_deposit_reverts_ifAmountIsZero(address user) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(bbv));

        vm.prank(user);
        vm.expectRevert(ErrorsLib.InvalidAmount.selector);
        bbv.deposit(user, address(mockAsset), 0);
    }

    function test_deposit_reverts_ifAssetIsNotAllowedToDepositIntoBBV(address msgSender, address user, uint256 amount)
        public
    {
        vm.assume(msgSender != address(0));
        _assumeNotProxyAdmin(msgSender, address(bbv));
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(bbv));
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

    function test_deposit_allowsToDepositOnBehalfOfOtherUser(address user, address msgSender, uint256 amount) public {
        vm.assume(user != address(0));
        vm.assume(msgSender != address(0));
        vm.assume(user != address(mockFundsHandler));
        vm.assume(msgSender != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(bbv));
        _assumeNotProxyAdmin(msgSender, address(bbv));
        amount = _boundAssetAmount(address(mockAsset), amount);

        vm.assume(bbv.getUserBalance(user) == 0);
        vm.assume(bbv.getUserBalance(msgSender) == 0);

        mockAsset.mint(msgSender, amount);
        vm.prank(msgSender);
        mockAsset.forceApprove(address(bbv), amount);

        vm.assume(mockAsset.balanceOf(user) == 0);
        vm.assume(mockAsset.balanceOf(msgSender) == amount);

        vm.prank(msgSender);
        bbv.deposit(user, address(mockAsset), amount);

        assertTrue(bbv.getUserBalance(user) > 0);
        assertTrue(bbv.getUserBalance(msgSender) == 0);

        vm.assume(mockAsset.balanceOf(user) == 0);
        vm.assume(mockAsset.balanceOf(msgSender) == 0);
    }

    function test_deposit_callsFundsHandlerToProcessDepositWithExpectedParams(address user, uint256 amount) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(bbv));
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
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(bbv));
        vm.assume(bbv.getUserSubVault(user).id == 0); // no prior deposits
        newPerSecondRate = _boundRate(newPerSecondRate);
        vm.assume(newPerSecondRate != bbv.getDefaultSubVault().perSecondRate);

        vm.prank(manager);
        vm.expectRevert(IBasedBoostedVault.NonExistentPosition.selector);
        _setUserRate(user, DEFAULT_PER_SECOND_RATE);
    }

    function test_setUserRate_reverts_ifSettingTheSameRateHeAlreadyHas(address user, uint256 amount) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(bbv));
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
        vm.assume(user1 != address(0));
        _assumeNotProxyAdmin(user1, address(bbv));
        vm.assume(user2 != address(0));
        _assumeNotProxyAdmin(user2, address(bbv));
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

        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(bbv));
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

    function test_setDefaultSubVault_reverts_ifMsgSenderIsNotAuthorized(
        address unauthorizedMsgSender,
        uint256 newPerSecondRate
    ) public {
        vm.assume(unauthorizedMsgSender != address(0));
        _assumeNotProxyAdmin(unauthorizedMsgSender, address(bbv));
        vm.assume(unauthorizedMsgSender != manager);
        newPerSecondRate = _boundRate(newPerSecondRate);

        mockAccessManager.mockRejectCall(
            unauthorizedMsgSender, address(bbv), IBasedBoostedVault.setDefaultSubVault.selector
        );
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedMsgSender)
        );
        vm.prank(unauthorizedMsgSender);
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

    function test_claimFees_reverts_ifMsgSenderIsNotAuthorized(address unauthorizedMsgSender, uint256 amountToClaim)
        public
    {
        _assumeNotProxyAdmin(unauthorizedMsgSender, address(bbv));
        amountToClaim = _boundAssetAmount(address(mockAsset), amountToClaim);

        mockAccessManager.mockRejectCall(unauthorizedMsgSender, address(bbv), IBasedBoostedVault.claimFees.selector);

        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedMsgSender)
        );
        vm.prank(unauthorizedMsgSender);
        bbv.claimFees(_toAddressArray(address(mockAsset)), _toUint256Array(amountToClaim));
    }

    function test_claimFees_reverts_ifObligationsExceedAssets(uint256 obligationsRay, uint256 aggregatedBalanceRay)
        public
    {
        obligationsRay = _boundRayAmount(obligationsRay);
        aggregatedBalanceRay = _boundRayAmount(aggregatedBalanceRay);
        uint256 obligationsAfterConversionRay =
            obligationsRay.rayToAssetDecimals(address(mockAsset)).assetDecimalsToRay(address(mockAsset));
        vm.assume(obligationsAfterConversionRay > aggregatedBalanceRay);

        mockFundsHandler.mockAggregatedBalance(aggregatedBalanceRay);

        // Make a deposit of `obligations` to grow the obligations to that amount
        uint256 obligationsInAssetDecimals = obligationsRay.rayToAssetDecimals(address(mockAsset));

        vm.assume(obligationsInAssetDecimals > 0);

        mockAsset.mint(obligationsInAssetDecimals);
        mockAsset.forceApprove(address(bbv), obligationsInAssetDecimals);
        bbv.deposit(address(this), address(mockAsset), obligationsInAssetDecimals);

        assertGt(bbv.getVaultObligations(), bbv.getAggregatedBalance());

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(IBasedBoostedVault.NoFeesToClaim.selector));
        bbv.claimFees(_toAddressArray(address(mockAsset)), _toUint256Array(obligationsInAssetDecimals));
    }

    function test_claimFees_reverts_ifPullingMoreFundsThanTheAvailableFeesToClaim(
        uint256 availableFeesToClaimRay,
        uint256 requestedAssetsToClaim
    ) public {
        requestedAssetsToClaim = _boundAssetAmount(address(mockAsset), requestedAssetsToClaim);
        availableFeesToClaimRay = _boundRayAmount(availableFeesToClaimRay);
        vm.assume(requestedAssetsToClaim.assetDecimalsToRay(address(mockAsset)) > availableFeesToClaimRay);

        mockAsset.mint(address(mockFundsHandler), requestedAssetsToClaim);
        mockFundsHandler.mockApprove(address(bbv), address(mockAsset), requestedAssetsToClaim);

        mockFundsHandler.mockAggregatedBalance(availableFeesToClaimRay);

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.InvalidAmount.selector));
        bbv.claimFees(_toAddressArray(address(mockAsset)), _toUint256Array(requestedAssetsToClaim));
    }

    function test_claimFees_emitExpectedEvent(uint256 availableFeesToClaimRay, uint256 requestedAssetsToClaim) public {
        requestedAssetsToClaim = _boundAssetAmount(address(mockAsset), requestedAssetsToClaim);
        availableFeesToClaimRay = _boundRayAmount(availableFeesToClaimRay);
        vm.assume(requestedAssetsToClaim.assetDecimalsToRay(address(mockAsset)) <= availableFeesToClaimRay);

        mockTransferHelper.mockAsset(address(mockAsset), availableFeesToClaimRay);

        mockFundsHandler.mockAggregatedBalance(availableFeesToClaimRay);

        vm.expectEmit(true, true, true, true);
        emit IBasedBoostedVault.FeesClaimed(
            _toAddressArray(address(mockAsset)), _toUint256Array(requestedAssetsToClaim)
        );

        vm.prank(manager);
        bbv.claimFees(_toAddressArray(address(mockAsset)), _toUint256Array(requestedAssetsToClaim));
    }

    function test_claimFees_sendsExpectedAmountOfFeesToMsgSender(
        address msgSender,
        uint256 availableFeesToClaimRay,
        uint256 requestedAssetsToClaim
    ) public {
        vm.assume(msgSender != address(0));
        vm.assume(msgSender != address(mockFundsHandler));
        _assumeNotProxyAdmin(msgSender, address(bbv));
        requestedAssetsToClaim = _boundAssetAmount(address(mockAsset), requestedAssetsToClaim);
        availableFeesToClaimRay = _boundRayAmount(availableFeesToClaimRay);
        vm.assume(requestedAssetsToClaim.assetDecimalsToRay(address(mockAsset)) <= availableFeesToClaimRay);
        vm.assume(mockAsset.balanceOf(msgSender) == 0);

        mockTransferHelper.mockAsset(address(mockAsset), availableFeesToClaimRay);

        mockFundsHandler.mockAggregatedBalance(availableFeesToClaimRay);

        // The AccessManager contract we use has all calls allowed by default, only rejections needs to be explicit.
        vm.prank(msgSender);
        bbv.claimFees(_toAddressArray(address(mockAsset)), _toUint256Array(requestedAssetsToClaim));

        assertEq(mockAsset.balanceOf(msgSender), requestedAssetsToClaim);
    }

    function test_setSubVaultRate_reverts_ifMsgSenderIsNotAuthorized(
        address unauthorizedMsgSender,
        uint256 subVaultId,
        uint256 newPerSecondRate
    ) public {
        _assumeNotProxyAdmin(unauthorizedMsgSender, address(bbv));
        newPerSecondRate = _boundRate(newPerSecondRate);

        mockAccessManager.mockRejectCall(
            unauthorizedMsgSender, address(bbv), IBasedBoostedVault.setSubVaultRate.selector
        );

        vm.prank(unauthorizedMsgSender);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedMsgSender)
        );
        bbv.setSubVaultRate(subVaultId, newPerSecondRate);
    }

    function test_setSubVaultRate_reverts_ifRateIsInvalid(uint256 subVaultId, uint256 invalidRate) public {
        vm.assume(invalidRate < MathLib.RAY || invalidRate > DEFAULT_MAX_PER_SECOND_RATE);

        vm.expectRevert(IBasedBoostedVault.InvalidRate.selector);
        bbv.setSubVaultRate(subVaultId, invalidRate);
    }

    function test_setSubVaultRate_reverts_ifAlreadyExistsAVaultWithTheGivenRate(
        uint256 subVaultId,
        uint256 existingRate
    ) public {
        existingRate = _boundRate(existingRate);

        bbv.setDefaultSubVault(existingRate);

        vm.expectRevert(IBasedBoostedVault.SubVaultAlreadyExists.selector);
        bbv.setSubVaultRate(subVaultId, existingRate);
    }

    function test_setSubVaultRate_reverts_ifNoSubVaultExistsWithTheGivenId(uint256 subVaultId, uint256 perSecondRate)
        public
    {
        vm.assume(bbv.getSubVaultRateById(subVaultId) == 0);

        perSecondRate = _boundRate(perSecondRate);
        vm.assume(bbv.getSubVaultIdByRate(perSecondRate) == 0);

        vm.expectRevert(IBasedBoostedVault.SubVaultDoesNotExist.selector);
        bbv.setSubVaultRate(subVaultId, perSecondRate);
    }

    function test_setSubVaultRate_emitsExpectedEvent(uint256 newPerSecondRate) public {
        newPerSecondRate = _boundRate(newPerSecondRate);
        vm.assume(bbv.getSubVaultIdByRate(newPerSecondRate) == 0);

        uint256 subVaultId = bbv.getDefaultSubVault().id;

        vm.expectEmit(true, true, true, true);
        emit IBasedBoostedVault.SubVaultRateSet(subVaultId, newPerSecondRate);
        bbv.setSubVaultRate(subVaultId, newPerSecondRate);
    }

    function test_setSubVaultRate_setsTheExpectedRate(uint256 newPerSecondRate) public {
        newPerSecondRate = _boundRate(newPerSecondRate);
        vm.assume(bbv.getSubVaultIdByRate(newPerSecondRate) == 0);

        uint256 subVaultId = bbv.getDefaultSubVault().id;
        bbv.setSubVaultRate(subVaultId, newPerSecondRate);

        assertEq(bbv.getSubVaultRateById(subVaultId), newPerSecondRate);
        assertEq(bbv.getSubVaultIdByRate(newPerSecondRate), subVaultId);
    }

    function test_getActiveSubVaults_activeSubVaultIsAddedUponDeposit(address user, uint256 depositAmount) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(bbv));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);

        assertEq(bbv.getActiveSubVaults().length, 0);

        _deposit(user, depositAmount);

        assertEq(bbv.getActiveSubVaults().length, 1);
        assertEq(bbv.getActiveSubVaults()[0].id, bbv.getDefaultSubVault().id);
    }

    function test_getActiveSubVaults_activeSubVaultIsChangedUponSetUserRate(
        address user,
        uint256 depositAmount,
        uint256 newPerSecondRate
    ) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(bbv));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);

        _deposit(user, depositAmount);

        assertEq(bbv.getActiveSubVaults().length, 1);
        assertEq(bbv.getActiveSubVaults()[0].id, bbv.getDefaultSubVault().id);

        newPerSecondRate = _boundRate(newPerSecondRate);
        vm.assume(bbv.getSubVaultIdByRate(newPerSecondRate) != bbv.getDefaultSubVault().id);

        _setUserRate(user, newPerSecondRate);

        assertEq(bbv.getActiveSubVaults().length, 1);
        assertEq(bbv.getActiveSubVaults()[0].id, bbv.getSubVaultIdByRate(newPerSecondRate));
    }

    function test_getActiveSubVaults_activeSubVaultIsRemovedWhenAllLiquidityIsWithdrawnFromIt(
        address user,
        uint256 depositAmount
    ) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(bbv));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);
        _deposit(user, depositAmount);
        mockFundsHandler.mockAggregatedBalance(depositAmount);

        assertEq(bbv.getActiveSubVaults().length, 1);

        vm.prank(user);
        bbv.requestWithdrawal(user, 0);

        assertEq(bbv.getActiveSubVaults().length, 0);
    }

    function test_getUserBalance_returnsZeroIfUserDoesNotHaveAPosition(address user) public view {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(bbv));
        vm.assume(bbv.getUserSubVault(user).id == 0);

        assertEq(bbv.getUserBalance(user), 0);
    }

    function test_requestWithdrawal_reverts_ifMsgSenderIsNotTheUser(
        address user,
        address msgSender,
        uint256 depositAmount,
        uint256 withdrawalAmountRay
    ) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(bbv));
        _assumeNotProxyAdmin(msgSender, address(bbv));
        vm.assume(msgSender != user);
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);
        _deposit(user, depositAmount);
        withdrawalAmountRay = bound(withdrawalAmountRay, 0, depositAmount.assetDecimalsToRay(address(mockAsset)));

        vm.expectRevert(IBasedBoostedVault.InvalidMsgSender.selector);
        vm.prank(msgSender);
        bbv.requestWithdrawal(user, withdrawalAmountRay);
    }

    function test_requestWithdrawal_reverts_userDoesNotHaveAPosition(address user, uint256 withdrawalAmountRay) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(bbv));
        withdrawalAmountRay = _boundRayAmount(withdrawalAmountRay);

        vm.expectRevert(IBasedBoostedVault.NonExistentPosition.selector);
        vm.prank(user);
        bbv.requestWithdrawal(user, withdrawalAmountRay);
    }

    function test_requestWithdrawal_passingZeroWorksAsFullWithdrawalAmountWildcard(address user, uint256 depositAmount)
        public
    {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(bbv));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);
        _deposit(user, depositAmount);

        uint256 userBalanceRay = bbv.getUserBalance(user);

        vm.prank(user);
        uint256 actualWithdrawalAmountRay = bbv.requestWithdrawal(user, 0);

        assertEq(actualWithdrawalAmountRay, userBalanceRay);
    }

    // Couldn't reproduce the case where the withdrawal amount is zero due to conversion rounding loss.
    //   └────── It should never happen. We added an `assert` instead of a `require`. We can remove it
    //           later or keep it as a safe guard.
    function test_requestWithdrawal_DoesNotHaveRoundingLoss(address user) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(bbv));
        uint256 depositAmount = 1;

        uint256 depositAmountInRay = depositAmount.assetDecimalsToRay(address(mockAsset));
        _deposit(user, depositAmount);

        vm.warp(block.timestamp + 1);
        mockFundsHandler.mockAggregatedBalance(10e27);

        vm.prank(user);
        bbv.requestWithdrawal(user, depositAmountInRay);

        vm.prank(user);
        bbv.requestWithdrawal(user, 0);
    }

    function test_requestWithdrawal_WithReallySmallInterest(address user) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(bbv));
        uint256 depositAmount = 1000000;

        uint256 depositAmountInRay = depositAmount.assetDecimalsToRay(address(mockAsset));
        _deposit(user, depositAmount);

        uint256 smallestGrowingRate = 1000000000000000000000000001;
        _setUserRate(user, smallestGrowingRate);

        vm.warp(block.timestamp + 1);
        mockFundsHandler.mockAggregatedBalance(10e27);

        vm.prank(user);
        bbv.requestWithdrawal(user, depositAmountInRay - 1);

        vm.prank(user);
        bbv.requestWithdrawal(user, 0);
    }

    function test_requestWithdrawal_tinyAmountWorksAsExpected(address user) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(bbv));
        uint256 depositAmount = 1;

        IMockErc20 asset = IMockErc20(address(new MockErc20("GHO", "GHO", 18)));
        asset.mint(user, depositAmount);
        vm.prank(user);
        asset.forceApprove(address(bbv), depositAmount);
        vm.prank(user);
        bbv.deposit(user, address(asset), depositAmount);

        uint256 withdrawalAmountRay = depositAmount.assetDecimalsToRay(address(asset));

        vm.assume(asset.balanceOf(user) == 0);

        vm.prank(user);
        bbv.requestWithdrawal(user, withdrawalAmountRay);

        assertEq(mockIouToken.balanceOf(user), withdrawalAmountRay);
    }

    function test_requestWithdrawal_reverts_ifWithdrawalAmountIsGreaterThanUserBalance(
        address user,
        uint256 userBalance,
        uint256 withdrawalAmountRay
    ) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(bbv));
        userBalance = _boundAssetAmount(address(mockAsset), userBalance);
        _deposit(user, userBalance);
        uint256 userBalanceRay = userBalance.assetDecimalsToRay(address(mockAsset));
        withdrawalAmountRay = _boundRayAmount(withdrawalAmountRay);
        vm.assume(withdrawalAmountRay > userBalanceRay);

        vm.expectRevert(ErrorsLib.InvalidAmount.selector);
        vm.prank(user);
        bbv.requestWithdrawal(user, withdrawalAmountRay);
    }

    function test_requestWithdrawal_reverts_ifInterestToWithdrawIsGreaterThanAvailableInterest(
        address user, // 0x0000000000000000000000000000000000000ac9
        uint256 depositAmount, // 74
        uint256 timeElapsed // 5285
    ) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(bbv));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);
        _deposit(user, depositAmount);

        timeElapsed = bound(timeElapsed, 5 minutes, 30 * 365 days);
        vm.warp(block.timestamp + timeElapsed);

        uint256 withdrawalAmountRay = bbv.getUserBalance(user);

        mockFundsHandler.mockAggregatedBalance(depositAmount.assetDecimalsToRay(address(mockAsset)));

        vm.expectRevert(
            abi.encodeWithSelector(
                IBasedBoostedVault.InsufficientAssets.selector,
                user,
                withdrawalAmountRay,
                depositAmount.assetDecimalsToRay(address(mockAsset))
            )
        );
        vm.prank(user);
        bbv.requestWithdrawal(user, withdrawalAmountRay);
    }

    function test_requestWithdrawal_mintsExpectedAmountOfIouTokens(
        address user,
        uint256 depositAmount,
        uint256 withdrawalAmountRay
    ) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(bbv));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);
        _deposit(user, depositAmount);
        vm.assume(withdrawalAmountRay < depositAmount.assetDecimalsToRay(address(mockAsset)));
        vm.assume(mockIouToken.balanceOf(user) == 0);

        mockFundsHandler.mockAggregatedBalance(depositAmount);

        uint256 expectedIouTokens = withdrawalAmountRay == 0 ? bbv.getUserBalance(user) : withdrawalAmountRay;

        vm.prank(user);
        uint256 actualWithdrawalAmountRay = bbv.requestWithdrawal(user, withdrawalAmountRay);

        assertEq(mockIouToken.balanceOf(user), expectedIouTokens);
        assertEq(actualWithdrawalAmountRay, expectedIouTokens);
    }

    // TODO: Implement tests after we decide which event are we going to use. This one requires calculation of shares.
    // function test_requestWithdrawal_emitsExpectedEvent(
    //     address user,
    //     uint256 depositAmount,
    //     uint256 withdrawalAmountRay
    // ) public {
    //     vm.assume(user != address(0));
    //     vm.assume(user != address(mockFundsHandler));
    //     _assumeNotProxyAdmin(user, address(bbv));
    //     depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);
    //     _deposit(user, depositAmount);
    //     vm.assume(withdrawalAmountRay < depositAmount.assetDecimalsToRay(address(mockAsset)));

    //     mockFundsHandler.mockAggregatedBalance(depositAmount);

    //     uint256 actualWithdrawalAmount = withdrawalAmountRay == 0 ? bbv.getUserBalance(user) : withdrawalAmountRay;

    //     vm.expectEmit(true, true, true, true);
    //     emit IBasedBoostedVault.WithdrawalRequestedWithShares(
    //         user, subVaultId, redeemedShares, actualWithdrawalAmount, guaranteedAmountRay
    //     );

    //     vm.prank(user);
    //     bbv.requestWithdrawal(user, withdrawalAmountRay);
    // }

    function test_requestWithdrawal_returnsExpectedAmount(
        address user,
        uint256 depositAmount,
        uint256 withdrawalAmountRay
    ) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(bbv));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);
        _deposit(user, depositAmount);
        vm.assume(withdrawalAmountRay < depositAmount.assetDecimalsToRay(address(mockAsset)));

        mockFundsHandler.mockAggregatedBalance(depositAmount);

        uint256 expectedReturnValue = withdrawalAmountRay == 0 ? bbv.getUserBalance(user) : withdrawalAmountRay;

        vm.prank(user);
        uint256 actualReturnValue = bbv.requestWithdrawal(user, withdrawalAmountRay);

        assertEq(actualReturnValue, expectedReturnValue);
    }

    function test_requestWithdrawal_reducesUserBalanceByExpectedAmount(
        address user,
        uint256 depositAmount,
        uint256 withdrawalAmountRay
    ) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(bbv));
        depositAmount = _boundAssetAmount(address(mockAsset), depositAmount);
        _deposit(user, depositAmount);
        uint256 userBalanceBefore = bbv.getUserBalance(user);
        vm.assume(withdrawalAmountRay < depositAmount.assetDecimalsToRay(address(mockAsset)));

        mockFundsHandler.mockAggregatedBalance(depositAmount);

        uint256 actualWithdrawalAmountRay = withdrawalAmountRay == 0 ? bbv.getUserBalance(user) : withdrawalAmountRay;

        vm.prank(user);
        uint256 actualReturnValue = bbv.requestWithdrawal(user, withdrawalAmountRay);

        assertEq(actualReturnValue, actualWithdrawalAmountRay);
        assertEq(bbv.getUserBalance(user), userBalanceBefore - actualWithdrawalAmountRay);
    }

    function test_executeWithdrawal_reverts_ifMsgSenderIsNotTheUser(
        address user,
        address msgSender,
        uint256 iouAmountRay
    ) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(bbv));
        _assumeNotProxyAdmin(msgSender, address(bbv));
        vm.assume(msgSender != user);
        iouAmountRay = _boundRayAmount(iouAmountRay);
        mockIouToken.mint(user, iouAmountRay);

        vm.expectRevert(IBasedBoostedVault.InvalidMsgSender.selector);
        vm.prank(msgSender);
        bbv.executeWithdrawal(user, address(mockAsset), iouAmountRay);
    }

    function test_executeWithdrawal_reverts_ifAssetIsNotAllowedToWithdrawFromBbv(
        address user,
        address msgSender,
        uint256 iouAmountRay
    ) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(bbv));
        _assumeNotProxyAdmin(msgSender, address(bbv));
        vm.assume(msgSender != user);
        iouAmountRay = _boundRayAmount(iouAmountRay);
        mockIouToken.mint(user, iouAmountRay);

        mockAssetRegistry.mockToDisallowAssetWithdrawalsFromBBV(address(mockAsset));

        vm.expectRevert(abi.encodeWithSelector(ErrorsLib.UnsupportedAsset.selector, address(mockAsset)));
        vm.prank(user);
        bbv.executeWithdrawal(user, address(mockAsset), iouAmountRay);
    }

    function test_executeWithdrawal_reverts_ifIouAmountIsGreaterThanUserBalance(
        address user,
        uint256 userIouBalance,
        uint256 iouAmountRay
    ) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(bbv));
        userIouBalance = _boundRayAmountAllowingZero(userIouBalance);
        iouAmountRay = _boundRayAmount(iouAmountRay);
        vm.assume(iouAmountRay > userIouBalance);
        mockIouToken.mint(user, userIouBalance);

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, user, userIouBalance, iouAmountRay)
        );
        vm.prank(user);
        bbv.executeWithdrawal(user, address(mockAsset), iouAmountRay);
    }

    function test_executeWithdrawal_emitsExpectedEvent(address user, uint256 iouAmountRay) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(bbv));
        iouAmountRay = _boundRayAmount(iouAmountRay);
        mockIouToken.mint(user, iouAmountRay);

        uint256 actualWithdrawnAssets = iouAmountRay.rayToAssetDecimals(address(mockAsset));
        mockTransferHelper.mockAsset(address(mockAsset), actualWithdrawnAssets);

        vm.expectEmit(true, true, true, true);
        emit IBasedBoostedVault.WithdrawalExecuted(user, address(mockAsset), actualWithdrawnAssets);

        vm.prank(user);
        bbv.executeWithdrawal(user, address(mockAsset), iouAmountRay);
    }

    function test_executeWithdrawal_burnsExpectedAmountOfIouTokens(
        address user,
        uint256 userIouBalance,
        uint256 iouAmountRay
    ) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(bbv));
        userIouBalance = _boundRayAmountAllowingZero(userIouBalance);
        iouAmountRay = _boundRayAmount(iouAmountRay);
        vm.assume(iouAmountRay <= userIouBalance);
        mockIouToken.mint(user, userIouBalance);
        assertEq(mockIouToken.balanceOf(user), userIouBalance);

        uint256 actualWithdrawnAssets = iouAmountRay.rayToAssetDecimals(address(mockAsset));
        mockTransferHelper.mockAsset(address(mockAsset), actualWithdrawnAssets);

        vm.prank(user);
        bbv.executeWithdrawal(user, address(mockAsset), iouAmountRay);

        assertEq(mockIouToken.balanceOf(user), userIouBalance - iouAmountRay);
    }

    function test_executeWithdrawal_transfersExpectedAmountOfAssetsToUser(address user, uint256 iouAmountRay) public {
        vm.assume(user != address(0));
        vm.assume(user != address(mockFundsHandler));
        _assumeNotProxyAdmin(user, address(bbv));
        iouAmountRay = _boundRayAmount(iouAmountRay);
        mockIouToken.mint(user, iouAmountRay);
        vm.assume(mockAsset.balanceOf(user) == 0);

        uint256 actualWithdrawnAssets = iouAmountRay.rayToAssetDecimals(address(mockAsset));
        mockTransferHelper.mockAsset(address(mockAsset), actualWithdrawnAssets);

        vm.prank(user);
        bbv.executeWithdrawal(user, address(mockAsset), iouAmountRay);

        assertEq(mockAsset.balanceOf(user), actualWithdrawnAssets);
    }

    function test_rescueTokens_reverts_ifMsgSenderIsNotAuthorized(
        address unauthorizedMsgSender,
        uint256 bbvAssetBalance,
        uint256 assetAmountToRescue
    ) public {
        vm.assume(unauthorizedMsgSender != address(0));
        _assumeNotProxyAdmin(unauthorizedMsgSender, address(bbv));
        vm.assume(unauthorizedMsgSender != manager);
        bbvAssetBalance = _boundAssetAmount(address(mockAsset), bbvAssetBalance);
        assetAmountToRescue = _boundAssetAmount(address(mockAsset), assetAmountToRescue);
        vm.assume(bbvAssetBalance >= assetAmountToRescue);
        mockAsset.mint(address(bbv), bbvAssetBalance);

        mockAccessManager.mockRejectCall(unauthorizedMsgSender, address(bbv), IRescuableAssets.rescueTokens.selector);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedMsgSender)
        );
        vm.prank(unauthorizedMsgSender);
        IRescuableAssets(address(bbv)).rescueTokens(address(mockAsset), assetAmountToRescue);
    }

    function test_rescueTokens_getsExpectedAmountOfAssetsToMsgSender(
        address msgSender,
        uint256 bbvAssetBalance,
        uint256 assetAmountToRescue
    ) public {
        vm.assume(msgSender != address(0));
        _assumeNotProxyAdmin(msgSender, address(bbv));

        bbvAssetBalance = _boundAssetAmount(address(mockAsset), bbvAssetBalance);
        assetAmountToRescue = _boundAssetAmount(address(mockAsset), assetAmountToRescue);
        vm.assume(bbvAssetBalance >= assetAmountToRescue);
        mockAsset.mint(address(bbv), bbvAssetBalance);
        assertEq(mockAsset.balanceOf(address(bbv)), bbvAssetBalance);
        vm.assume(mockAsset.balanceOf(msgSender) == 0);

        vm.prank(msgSender);
        IRescuableAssets(address(bbv)).rescueTokens(address(mockAsset), assetAmountToRescue);

        assertEq(mockAsset.balanceOf(msgSender), assetAmountToRescue);
        assertEq(mockAsset.balanceOf(address(bbv)), bbvAssetBalance - assetAmountToRescue);
    }

    ////////////////////////////// HELPERS ///////////////////////////////

    function _deposit(address user, uint256 amount) public {
        mockAsset.mint(user, amount);
        vm.prank(user);
        mockAsset.forceApprove(address(bbv), amount);
        vm.prank(user);
        bbv.deposit(user, address(mockAsset), amount);
    }

    function _setUserRate(address user, uint256 newPerSecondRate) public {
        IBasedBoostedVault.UserRateData[] memory userRateData = new IBasedBoostedVault.UserRateData[](1);
        userRateData[0] = IBasedBoostedVault.UserRateData(user, newPerSecondRate);
        bbv.setUserRate(userRateData);
    }
}

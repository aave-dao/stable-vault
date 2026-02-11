// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IAccessManaged} from "@openzeppelin/contracts/access/manager/IAccessManaged.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";

import {IChainBalanceOracle} from "src/interfaces/IChainBalanceOracle.sol";
import {IChainBalanceOracleAdapter} from "src/interfaces/IChainBalanceOracleAdapter.sol";
import {ChainBalanceOracle} from "src/oracles/balance/ChainBalanceOracle.sol";

import {TestWithHelpers} from "test/helpers/TestWithHelpers.sol";
import {MockAccessManager} from "test/mocks/MockAccessManager.sol";
import {MockChainBalanceOracleAdapter} from "test/mocks/MockChainBalanceOracleAdapter.sol";

contract ChainBalanceOracleTest is TestWithHelpers {
    address admin = makeAddr("ADMIN");
    address everyRoleAccount = makeAddr("EVERY_ROLE_ACCOUNT");

    uint256 constant EARNING_CHAIN_ID = 1;

    MockAccessManager internal _mockAccessManager;
    ChainBalanceOracle internal _chainBalanceOracle;
    MockChainBalanceOracleAdapter internal _mockAdapter;

    function _deployChainBalanceOracle(address accessManager) internal returns (ChainBalanceOracle) {
        address impl = address(new ChainBalanceOracle());
        return ChainBalanceOracle(
            address(
                new TransparentUpgradeableProxy(
                    impl, address(this), abi.encodeCall(ChainBalanceOracle.initialize, (accessManager))
                )
            )
        );
    }

    function setUp() public virtual {
        _mockAccessManager = new MockAccessManager(admin);
        _chainBalanceOracle = _deployChainBalanceOracle(address(_mockAccessManager));
        _mockAdapter = new MockChainBalanceOracleAdapter();
        // Warp to a reasonable timestamp to avoid underflow.
        vm.warp(block.timestamp + 1 days);
    }

    function test_initialize_setsAccessManager() public view {
        assertEq(_chainBalanceOracle.authority(), address(_mockAccessManager));
    }

    function test_initialize_reverts_ifCalledTwice() public {
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        _chainBalanceOracle.initialize(address(_mockAccessManager));
    }

    function test_constructor_disablesInitializers() public {
        ChainBalanceOracle impl = new ChainBalanceOracle();
        vm.expectRevert(Initializable.InvalidInitialization.selector);
        impl.initialize(address(_mockAccessManager));
    }

    function test_setChainBalanceOracleAdapter_setsAdapter(uint256 chainId, uint256 balanceRay) public {
        // Mock a valid response so the adapter check passes
        _mockAdapter.mockResponse(
            chainId,
            balanceRay,
            block.timestamp,
            block.timestamp - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS,
            false
        );

        vm.expectEmit(true, true, true, true);
        emit IChainBalanceOracle.ChainBalanceAdapterSet(chainId, address(0), address(_mockAdapter));

        vm.prank(everyRoleAccount);
        _chainBalanceOracle.setChainBalanceOracleAdapter(chainId, address(_mockAdapter));
    }

    function test_setChainBalanceOracleAdapter_emitsEventWithPreviousAdapter(uint256 chainId, uint256 balanceRay)
        public
    {
        _mockAdapter.mockResponse(
            chainId,
            balanceRay,
            block.timestamp,
            block.timestamp - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS,
            false
        );
        vm.prank(everyRoleAccount);
        _chainBalanceOracle.setChainBalanceOracleAdapter(chainId, address(_mockAdapter));

        // Create new adapter
        MockChainBalanceOracleAdapter newAdapter = new MockChainBalanceOracleAdapter();
        newAdapter.mockResponse(
            chainId,
            balanceRay,
            block.timestamp,
            block.timestamp - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS,
            false
        );

        // Setting a new adapter should emit event with previous adapter
        vm.expectEmit(true, true, true, true);
        emit IChainBalanceOracle.ChainBalanceAdapterSet(chainId, address(_mockAdapter), address(newAdapter));

        vm.prank(everyRoleAccount);
        _chainBalanceOracle.setChainBalanceOracleAdapter(chainId, address(newAdapter));
    }

    function test_setChainBalanceOracleAdapter_reverts_ifAdapterCallFails(uint256 chainId) public {
        _mockAdapter.setShouldRevert(true);

        vm.expectRevert(abi.encodeWithSelector(IChainBalanceOracleAdapter.InvalidChainId.selector, chainId));
        vm.prank(everyRoleAccount);
        _chainBalanceOracle.setChainBalanceOracleAdapter(chainId, address(_mockAdapter));
    }

    function test_setChainBalanceOracleAdapter_reverts_ifNotAuthorized(address unauthorizedCaller, uint256 chainId)
        public
    {
        vm.assume(unauthorizedCaller != address(0));
        _assumeNotProxyAdmin(unauthorizedCaller, address(_chainBalanceOracle));

        _mockAccessManager.mockRejectCall(
            unauthorizedCaller, address(_chainBalanceOracle), ChainBalanceOracle.setChainBalanceOracleAdapter.selector
        );

        vm.expectRevert(abi.encodeWithSelector(IAccessManaged.AccessManagedUnauthorized.selector, unauthorizedCaller));
        vm.prank(unauthorizedCaller);
        _chainBalanceOracle.setChainBalanceOracleAdapter(chainId, address(_mockAdapter));
    }

    function test_getChainBalance_returnsBalanceWhenNotStale(uint256 chainId, uint256 balanceRay) public {
        _mockAdapter.mockResponse(
            chainId,
            balanceRay,
            block.timestamp,
            block.timestamp - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS,
            false
        );

        vm.prank(everyRoleAccount);
        _chainBalanceOracle.setChainBalanceOracleAdapter(chainId, address(_mockAdapter));

        IChainBalanceOracle.ChainBalance memory result = _chainBalanceOracle.getChainBalance(chainId);
        assertEq(result.balanceRay, balanceRay, "Should return balanceRay when not stale");
        assertEq(result.lastUpdateTimestamp, block.timestamp, "Should return lastUpdateTimestamp when not stale");
        assertEq(
            result.sourceChainTimestamp,
            block.timestamp - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS,
            "Should return sourceChainTimestamp when not stale"
        );
        assertFalse(result.isStale, "Should return false when not stale");
    }

    function test_getChainBalance_returnsZeroWhenStale(uint256 chainId, uint256 balanceRay) public {
        // Warp to a reasonable timestamp to avoid underflow
        vm.warp(block.timestamp + 10 days);

        // Mock adapter to return stale data
        _mockAdapter.mockResponse(
            chainId,
            balanceRay,
            block.timestamp - 1 days,
            block.timestamp - 1 days - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS,
            true
        );

        vm.prank(everyRoleAccount);
        _chainBalanceOracle.setChainBalanceOracleAdapter(chainId, address(_mockAdapter));

        IChainBalanceOracle.ChainBalance memory result = _chainBalanceOracle.getChainBalance(chainId);
        assertEq(result.balanceRay, 0, "Should return 0 when stale");
        assertTrue(result.isStale, "Should return true when stale");
    }

    function test_getChainBalance_reverts_ifNoAdapterSet(uint256 chainId) public {
        vm.expectRevert(abi.encodeWithSelector(IChainBalanceOracle.ChainBalanceOracleAdapterNotFound.selector, chainId));
        _chainBalanceOracle.getChainBalance(chainId);
    }

    function test_getChainBalance_withMultipleChains() public {
        uint256 chain1 = 1;
        uint256 chain2 = 42161;
        uint256 chain3 = 10;

        uint256 balance1 = 1000 * 1e27;
        uint256 balance2 = 2000 * 1e27;
        uint256 balance3 = 3000 * 1e27;

        // Create separate adapters for each chain
        MockChainBalanceOracleAdapter adapter1 = new MockChainBalanceOracleAdapter();
        MockChainBalanceOracleAdapter adapter2 = new MockChainBalanceOracleAdapter();
        MockChainBalanceOracleAdapter adapter3 = new MockChainBalanceOracleAdapter();

        adapter1.mockResponse(
            chain1,
            balance1,
            block.timestamp,
            block.timestamp - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS,
            false
        );
        adapter2.mockResponse(
            chain2,
            balance2,
            block.timestamp,
            block.timestamp - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS,
            false
        );
        // This one is stale
        adapter3.mockResponse(
            chain3,
            balance3,
            block.timestamp,
            block.timestamp - DEFAULT_CHAIN_BALANCE_ORACLE_PUBLISH_DELAY_SECONDS * 3,
            true
        );

        vm.startPrank(everyRoleAccount);
        _chainBalanceOracle.setChainBalanceOracleAdapter(chain1, address(adapter1));
        _chainBalanceOracle.setChainBalanceOracleAdapter(chain2, address(adapter2));
        _chainBalanceOracle.setChainBalanceOracleAdapter(chain3, address(adapter3));
        vm.stopPrank();

        assertEq(_chainBalanceOracle.getChainBalance(chain1).balanceRay, balance1, "Chain 1 balance mismatch");
        assertEq(_chainBalanceOracle.getChainBalance(chain2).balanceRay, balance2, "Chain 2 balance mismatch");
        assertEq(_chainBalanceOracle.getChainBalance(chain3).balanceRay, 0, "Chain 3 should return 0 (stale)");
    }
}

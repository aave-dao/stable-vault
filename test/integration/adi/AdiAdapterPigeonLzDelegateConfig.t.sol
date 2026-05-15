// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.22;

import {AdiAdapterPigeonLocalForkBase} from "./AdiAdapterPigeonLocalForkBase.sol";

/// @notice a.DI PR7-style `CrossChainForwarder.configAdapter` + LZ `EndpointV2` delegate wiring on local forks.
/// @dev See https://github.com/aave/aave-delivery-infrastructure/pull/7 — send-side OApp context is the CCC
///      (`delegatecall` into the LZ adapter); receive-side is the adapter address itself.
interface ICrossChainForwarderConfigAdapter {
    function configAdapter(uint256 destinationChainId, address adapter, bytes calldata data) external;
}

/// @dev `IConfigurableAdapter.config` on the LZ adapter (PR7 `LayerZeroAdapter.config`).
interface IConfigurableLzAdapter {
    function config(uint256 destinationChainId, bytes calldata data) external;
}

/// @dev Minimal LayerZero V2 endpoint surface used by PR7.
interface ILayerZeroEndpointV2Delegates {
    function setDelegate(address _delegate) external;

    function delegates(address _oapp) external view returns (address);
}

interface ILzAdapterLike {
    function LZ_ENDPOINT() external view returns (address);
}

/// @dev Matches `ICrossChainForwarder.ChainIdBridgeConfig` / `getForwarderBridgeAdaptersByChain` return layout.
interface ICccForwarderAdaptersView {
    struct ChainIdBridgeConfig {
        address destinationBridgeAdapter;
        address currentChainBridgeAdapter;
    }

    function getForwarderBridgeAdaptersByChain(uint256 chainId) external view returns (ChainIdBridgeConfig[] memory);
}

contract AdiAdapterPigeonLzDelegateConfig is AdiAdapterPigeonLocalForkBase {
    /// @notice CCC owner calls `configAdapter` → delegatecall into a **registered** LZ forwarder adapter.
    /// @dev Stable Vaults ETH CCC only registers Arbitrum-native for `42161`, so we exercise ARB CCC → ETH (`1`)
    ///      where CCIP + LZ + HL are registered (see `getForwarderBridgeAdaptersByChain(1)` on the ARB fork).
    function test_configAdapter_arbLz_setsEndpointDelegateForCccOApp() public onlyForkTest {
        vm.selectFork(_arbFork);

        address lzAdapter = _findForwarderLzAdapter(_arbCcc, ETH_CHAIN_ID);
        assertNotEq(lzAdapter, address(0), "no LZ adapter in ARB CCC forwarder set for destination Ethereum");

        address lzEp = ILzAdapterLike(lzAdapter).LZ_ENDPOINT();
        address delegate = makeAddr("LZ_DELEGATE_CCC_CONTEXT_ARB");

        vm.prank(_stableVaultsOwner);
        ICrossChainForwarderConfigAdapter(_arbCcc).configAdapter(ETH_CHAIN_ID, lzAdapter, abi.encode(delegate));

        address set = ILayerZeroEndpointV2Delegates(lzEp).delegates(_arbCcc);
        assertEq(set, delegate, "EndpointV2.delegates(CCC) should match CCC-context setDelegate");
    }

    /// @notice Owner calls `config` on the ETH LZ adapter directly (adapter OApp context on Ethereum).
    function test_lzAdapterDirectConfig_eth_setsEndpointDelegateForAdapterOApp() public onlyForkTest {
        assertNotEq(_ethLzAdapter, address(0), "ETH_LZ_ADAPTER not set");

        address delegate = makeAddr("LZ_DELEGATE_ADAPTER_CONTEXT_ETH");
        bytes memory data = abi.encode(delegate);

        vm.selectFork(_ethFork);

        address lzEp = ILzAdapterLike(_ethLzAdapter).LZ_ENDPOINT();

        vm.prank(_stableVaultsOwner);
        IConfigurableLzAdapter(_ethLzAdapter).config(ARB_CHAIN_ID, data);

        address set = ILayerZeroEndpointV2Delegates(lzEp).delegates(_ethLzAdapter);
        assertEq(set, delegate, "EndpointV2.delegates(LZ_ADAPTER) should match adapter-context setDelegate");
    }

    /// @notice Same direct `config` path on the LZ adapter discovered on Arbitrum (receive-side OApp).
    function test_lzAdapterDirectConfig_arb_setsEndpointDelegateForAdapterOApp() public onlyForkTest {
        vm.selectFork(_arbFork);

        address lzAdapter = _findForwarderLzAdapter(_arbCcc, ETH_CHAIN_ID);
        assertNotEq(lzAdapter, address(0), "no LZ adapter in ARB CCC forwarder set for destination Ethereum");

        address lzEp = ILzAdapterLike(lzAdapter).LZ_ENDPOINT();
        address delegate = makeAddr("LZ_DELEGATE_ADAPTER_CONTEXT_ARB");

        vm.prank(_stableVaultsOwner);
        IConfigurableLzAdapter(lzAdapter).config(ETH_CHAIN_ID, abi.encode(delegate));

        address set = ILayerZeroEndpointV2Delegates(lzEp).delegates(lzAdapter);
        assertEq(set, delegate, "EndpointV2.delegates(LZ_ADAPTER) should match adapter-context setDelegate");
    }

    function _findForwarderLzAdapter(address ccc, uint256 destinationChainId) internal view returns (address) {
        ICccForwarderAdaptersView.ChainIdBridgeConfig[] memory cfgs =
            ICccForwarderAdaptersView(ccc).getForwarderBridgeAdaptersByChain(destinationChainId);
        for (uint256 i = 0; i < cfgs.length; i++) {
            address a = cfgs[i].currentChainBridgeAdapter;
            if (a.code.length == 0) {
                continue;
            }
            try ILzAdapterLike(a).LZ_ENDPOINT() returns (address ep) {
                if (ep != address(0)) {
                    return a;
                }
            } catch {
                // not an LZ-style adapter
            }
        }
        return address(0);
    }
}

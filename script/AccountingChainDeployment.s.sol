// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "forge-std/Script.sol";

import {Create3AddressBook} from "script/base/Create3AddressBook.sol";
import {Create3Deployment} from "script/base/Create3Deployment.sol";

import {ExtendedAccessManager} from "src/access/ExtendedAccessManager.sol";
import {CcipAdapter} from "src/bridging/CcipAdapter.sol";
import {Allocator} from "src/core/Allocator.sol";
import {AccountingChainGateway} from "src/core/accounting/AccountingChainGateway.sol";
import {BasedBoostedVault} from "src/core/accounting/BasedBoostedVault.sol";
import {FundsHandler} from "src/core/accounting/FundsHandler.sol";
import {IouToken} from "src/core/ious/IouToken.sol";
import {IouTokenManager} from "src/core/ious/IouTokenManager.sol";
import {AssetRegistry} from "src/periphery/AssetRegistry.sol";
import {Swapper} from "src/periphery/Swapper.sol";
import {TransferHelper} from "src/periphery/TransferHelper.sol";
import {WithdrawalPolicy} from "src/periphery/WithdrawalPolicy.sol";

contract AccountingChainDeployment is Create3Deployment, Create3AddressBook, Script {
    address constant DEPLOYER = address(0xBB700dA5CCC9Ec5605780Fc40695f1206B090303);

    uint256 constant DEFAULT_MAX_PER_SECOND_RATE = 1000000005781378656804591713; // ~20% APY
    uint256 constant DEFAULT_SUB_VAULT_PER_SECOND_RATE = 1000000001243680656318820313; // ~4% APY

    address constant PROXY_ADMIN = DEPLOYER;
    address constant BBV_PROXY_ADMIN = PROXY_ADMIN;
    address constant ALLOCATOR_PROXY_ADMIN = PROXY_ADMIN;
    address constant WITHDRAWAL_POLICY_PROXY_ADMIN = PROXY_ADMIN;
    address constant ASSET_REGISTRY_PROXY_ADMIN = PROXY_ADMIN;
    address constant GATEWAY_PROXY_ADMIN = PROXY_ADMIN;
    address constant IOU_TOKEN_MANAGER_PROXY_ADMIN = PROXY_ADMIN;
    address constant FUNDS_HANDLER_PROXY_ADMIN = PROXY_ADMIN;

    address immutable ALLOCATOR_DEPOSITOR = getFundsHandlerAddress(DEPLOYER);
    address immutable ALLOCATOR_WITHDRAWER = getFundsHandlerAddress(DEPLOYER);

    // Set to Ethereum CCIP Router address
    address constant CCIP_ROUTER_ADDRESS = address(0x80226fc0Ee2b096224EeAc085Bb9a8cba1146f7D);

    function run() public {
        vm.startBroadcast(DEPLOYER);
        _deployContracts();
        _setupContracts();
        vm.stopBroadcast();
    }

    function _deployContracts() internal {
        _deployTransferHelper();
        _deployAccessManager();
        _deployAssetRegistry();
        _deployWithdrawalPolicy();
        _deployIouToken();
        _deployIouTokenManager();
        _deployBasedBoostedVault();
        _deployAllocator();
        _deployFundsHandler();
        _deployGateway();
        _deploySwapper();
        _deployCcipAdapter();
        // _deployStrategyVault();
    }

    function _setupContracts() internal {}

    function _deployTransferHelper() internal returns (address) {
        address transferHelper = _deploy_create3({
            namespacedSaltSeed: TRANSFER_HELPER_SALT_SEED,
            deployer: DEPLOYER,
            initCode: abi.encodePacked(type(TransferHelper).creationCode)
        });
        require(transferHelper == getTransferHelperAddress(DEPLOYER), "TransferHelper does not match expected address");
        return transferHelper;
    }

    function _deployAccessManager() internal returns (address) {
        address accessManager = _deploy_create3({
            namespacedSaltSeed: ACCESS_MANAGER_SALT_SEED,
            deployer: DEPLOYER,
            initCode: abi.encodePacked(type(ExtendedAccessManager).creationCode)
        });
        require(accessManager == getAccessManagerAddress(DEPLOYER), "AccessManager does not match expected address");
        return accessManager;
    }

    function _deployAssetRegistry() internal returns (address) {
        address implementation = address(new AssetRegistry());
        address assetRegistry = _deployTransparentProxy_create3({
            namespacedSaltSeed: ASSET_REGISTRY_SALT_SEED,
            deployer: DEPLOYER,
            implementation: implementation,
            proxyAdmin: ASSET_REGISTRY_PROXY_ADMIN,
            initCalldata: abi.encodeCall(AssetRegistry.initialize, (getAccessManagerAddress(DEPLOYER)))
        });
        require(assetRegistry == getAssetRegistryAddress(DEPLOYER), "AssetRegistry does not match expected address");
        return assetRegistry;
    }

    function _deployWithdrawalPolicy() internal returns (address) {
        address implementation = address(new WithdrawalPolicy({assetRegistry: getAssetRegistryAddress(DEPLOYER)}));
        address withdrawalPolicy = _deployTransparentProxy_create3({
            namespacedSaltSeed: WITHDRAWAL_POLICY_SALT_SEED,
            deployer: DEPLOYER,
            implementation: implementation,
            proxyAdmin: WITHDRAWAL_POLICY_PROXY_ADMIN,
            initCalldata: abi.encodeCall(WithdrawalPolicy.initialize, (getAccessManagerAddress(DEPLOYER)))
        });
        require(
            withdrawalPolicy == getWithdrawalPolicyAddress(DEPLOYER), "WithdrawalPolicy does not match expected address"
        );
        return withdrawalPolicy;
    }

    function _deployIouToken() internal returns (address) {
        address iouToken = _deploy_create3({
            namespacedSaltSeed: IOU_TOKEN_SALT_SEED,
            deployer: DEPLOYER,
            initCode: abi.encodePacked(type(IouToken).creationCode)
        });
        require(iouToken == getIouTokenAddress(DEPLOYER), "IouToken does not match expected address");
        return iouToken;
    }

    function _deployIouTokenManager() internal returns (address) {
        address implementation = address(
            new IouTokenManager({
                iouToken: getIouTokenAddress(DEPLOYER),
                chainGateway: getGatewayAddress(DEPLOYER),
                vault: getBasedBoostedVaultAddress(DEPLOYER),
                transferHelper: getTransferHelperAddress(DEPLOYER),
                isAccountingChain: true
            })
        );
        address iouTokenManager = _deployTransparentProxy_create3({
            namespacedSaltSeed: IOU_TOKEN_MANAGER_SALT_SEED,
            deployer: DEPLOYER,
            implementation: implementation,
            proxyAdmin: IOU_TOKEN_MANAGER_PROXY_ADMIN,
            initCalldata: ""
        });
        require(
            iouTokenManager == getIouTokenManagerAddress(DEPLOYER), "IouTokenManager does not match expected address"
        );
        return iouTokenManager;
    }

    function _deployBasedBoostedVault() internal returns (address) {
        address implementation = address(
            new BasedBoostedVault({
                maxValidPerSecondRate: DEFAULT_MAX_PER_SECOND_RATE,
                assetRegistry: getAssetRegistryAddress(DEPLOYER),
                iouTokenManager: getIouTokenManagerAddress(DEPLOYER),
                fundsHandler: getFundsHandlerAddress(DEPLOYER),
                transferHelper: getTransferHelperAddress(DEPLOYER),
                withdrawalPolicy: getWithdrawalPolicyAddress(DEPLOYER)
            })
        );
        address bbv = _deployTransparentProxy_create3({
            namespacedSaltSeed: BASED_BOOSTED_VAULT_SALT_SEED,
            deployer: DEPLOYER,
            implementation: implementation,
            proxyAdmin: BBV_PROXY_ADMIN,
            initCalldata: abi.encodeCall(
                BasedBoostedVault.initialize, (getAccessManagerAddress(DEPLOYER), DEFAULT_SUB_VAULT_PER_SECOND_RATE)
            )
        });
        require(bbv == getBasedBoostedVaultAddress(DEPLOYER), "BasedBoostedVault does not match expected address");
        return bbv;
    }

    function _deployAllocator() internal returns (address) {
        address implementation = address(
            new Allocator({
                assetRegistry: getAssetRegistryAddress(DEPLOYER),
                depositor: ALLOCATOR_DEPOSITOR,
                withdrawer: ALLOCATOR_WITHDRAWER,
                transferHelper: getTransferHelperAddress(DEPLOYER)
            })
        );
        address allocator = _deployTransparentProxy_create3({
            namespacedSaltSeed: ALLOCATOR_SALT_SEED,
            deployer: DEPLOYER,
            implementation: implementation,
            proxyAdmin: ALLOCATOR_PROXY_ADMIN,
            initCalldata: abi.encodeCall(Allocator.initialize, (getAccessManagerAddress(DEPLOYER)))
        });
        require(allocator == getAllocatorAddress(DEPLOYER), "Allocator does not match expected address");
        return allocator;
    }

    function _deployFundsHandler() internal returns (address) {
        address implementation = address(
            new FundsHandler({
                basedBoostedVault: getBasedBoostedVaultAddress(DEPLOYER),
                gateway: getGatewayAddress(DEPLOYER),
                allocator: getAllocatorAddress(DEPLOYER),
                transferHelper: getTransferHelperAddress(DEPLOYER)
            })
        );
        address fundsHandler = _deployTransparentProxy_create3({
            namespacedSaltSeed: FUNDS_HANDLER_SALT_SEED,
            deployer: DEPLOYER,
            implementation: implementation,
            proxyAdmin: FUNDS_HANDLER_PROXY_ADMIN,
            initCalldata: abi.encodeCall(FundsHandler.initialize, (getAccessManagerAddress(DEPLOYER)))
        });
        require(fundsHandler == getFundsHandlerAddress(DEPLOYER), "FundsHandler does not match expected address");
        return fundsHandler;
    }

    function _deployGateway() internal returns (address) {
        address implementation = address(
            new AccountingChainGateway({
                fundsHandler: getFundsHandlerAddress(DEPLOYER), iouTokenManager: getIouTokenManagerAddress(DEPLOYER)
            })
        );
        address gateway = _deployTransparentProxy_create3({
            namespacedSaltSeed: GATEWAY_SALT_SEED,
            deployer: DEPLOYER,
            implementation: implementation,
            proxyAdmin: GATEWAY_PROXY_ADMIN,
            initCalldata: abi.encodeCall(AccountingChainGateway.initialize, (getAccessManagerAddress(DEPLOYER)))
        });
        require(gateway == getGatewayAddress(DEPLOYER), "Gateway does not match expected address");
        return gateway;
    }

    function _deploySwapper() internal returns (address) {
        address swapper = _deploy_create3({
            namespacedSaltSeed: SWAPPER_SALT_SEED,
            deployer: DEPLOYER,
            initCode: abi.encodePacked(type(Swapper).creationCode)
        });
        require(swapper == getSwapperAddress(DEPLOYER), "Swapper does not match expected address");
        return swapper;
    }

    function _deployCcipAdapter() internal returns (address) {
        address ccipAdapter = _deploy_create3({
            namespacedSaltSeed: CCIP_ADAPTER_SALT_SEED,
            deployer: DEPLOYER,
            initCode: abi.encodePacked(
                type(CcipAdapter).creationCode,
                getAccessManagerAddress(DEPLOYER),
                getGatewayAddress(DEPLOYER),
                CCIP_ROUTER_ADDRESS,
                getTransferHelperAddress(DEPLOYER)
            )
        });
        require(ccipAdapter == getCcipAdapterAddress(DEPLOYER), "CcipAdapter does not match expected address");
        return ccipAdapter;
    }
}

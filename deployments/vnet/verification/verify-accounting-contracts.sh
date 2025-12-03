#!/bin/bash

# Automated verification script for accounting.json contracts
# This script will verify all contracts sequentially

VERIFIER_URL="https://virtual.base.us-east.rpc.tenderly.co/69ce5d4c-849c-49f5-b510-bbd044b0d78d/verify"

echo "=========================================="
echo "Starting verification of accounting contracts"
echo "=========================================="
echo ""

verify_contract() {
    local contract_name=$1
    local address=$2
    local source_path=$3
    
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Verifying: $contract_name"
    echo "Address: $address"
    echo "Source: $source_path"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    
    if forge verify-contract "$address" \
        "$source_path" \
        --verifier custom \
        --verifier-url "$VERIFIER_URL" \
        --watch 2>&1; then
        echo "✓ Successfully verified $contract_name"
    else
        echo "✗ Failed to verify $contract_name (continuing...)"
    fi
    echo ""
}

verify_contract "TransferHelper" \
    "0x9c0d4c4e85df91a16b79b405676f289cdb06632b" \
    "src/periphery/TransferHelper.sol:TransferHelper"

verify_contract "AccessManager" \
    "0xba2533cb389802bcd18e0356b6186afb1829f6ff" \
    "src/access/ExtendedAccessManager.sol:ExtendedAccessManager"

verify_contract "AssetRegistry::implementation" \
    "0x4fb37a25131790880c8668d6bd07fa93d358d2bb" \
    "src/periphery/AssetRegistry.sol:AssetRegistry"

verify_contract "AssetRegistry::proxy" \
    "0xb0b9a4b122cff529b6dc4f93e0b9496afafaef3b" \
    "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy"

verify_contract "WithdrawalPolicy::implementation" \
    "0xe448581c3dff6720c0b4944fbaef8bf44d7419ea" \
    "src/periphery/WithdrawalPolicy.sol:WithdrawalPolicy"

verify_contract "WithdrawalPolicy::proxy" \
    "0x96ec72dd6a226c9fc2187f00b65f41851ff2643c" \
    "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy"

verify_contract "IouToken" \
    "0x9f1b1815af9aa9e8ecb0be9c939a3481ee7ff3f6" \
    "src/core/ious/IouToken.sol:IouToken"

verify_contract "IouTokenManager::implementation" \
    "0xb929a69fe0ceaa9e1bc0f47750e21005aeb19ccd" \
    "src/core/ious/IouTokenManager.sol:IouTokenManager"

verify_contract "IouTokenManager::proxy" \
    "0x14fc7c26e112ac6f7ed7e5b6adcb795562fdaf10" \
    "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy"

verify_contract "BasedBoostedVault::implementation" \
    "0x6da09c73d3c26c2d4a12857d1f2e1dd32fab22bd" \
    "src/core/accounting/BasedBoostedVault.sol:BasedBoostedVault"

verify_contract "BasedBoostedVault::proxy" \
    "0xb49bd8c7fa9d910d77ef5a356ccfdf6a4ba14602" \
    "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy"

verify_contract "Allocator::implementation" \
    "0x105dc45c592a882ef213ffdbd7c0ed9147fe27e3" \
    "src/core/Allocator.sol:Allocator"

verify_contract "Allocator::proxy" \
    "0x07623d7cb79b98ffceecef180c3ec41ef0c90789" \
    "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy"

verify_contract "FundsHandler::implementation" \
    "0x45a82120240b836892f0140d117438401be9683c" \
    "src/core/accounting/FundsHandler.sol:FundsHandler"

verify_contract "FundsHandler::proxy" \
    "0xd2f851e7a5f4f43b3347376cd93824524a1b0187" \
    "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy"

verify_contract "AccountingChainGateway::implementation" \
    "0xb11b1af497101fa0b09c579c44ee112813ce2832" \
    "src/core/accounting/AccountingChainGateway.sol:AccountingChainGateway"

verify_contract "AccountingChainGateway::proxy" \
    "0xb93e374af729e77e42294791c20f947e7bdffde6" \
    "lib/openzeppelin-contracts/contracts/proxy/transparent/TransparentUpgradeableProxy.sol:TransparentUpgradeableProxy"

verify_contract "CcipAdapter" \
    "0x18b2b16456162b546aa8f3227c5d15b5add4ba41" \
    "src/bridging/CcipAdapter.sol:CcipAdapter"

echo "=========================================="
echo "Verification process completed!"
echo "=========================================="

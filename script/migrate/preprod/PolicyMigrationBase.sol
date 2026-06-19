// SPDX-License-Identifier: UNLICENSED
// Copyright (c) 2025 Aave Labs
pragma solidity ^0.8.20;

import {IAccessManager} from "@openzeppelin/contracts/access/manager/IAccessManager.sol";
import {console} from "forge-std/console.sol";
import {BaseChainDeployment} from "script/base/BaseChainDeployment.sol";
import {RolesConfig} from "script/base/RolesConfig.sol";
import {Create3AddressLib} from "script/libraries/Create3AddressLib.sol";
import {IPolicyRegistry} from "src/interfaces/IPolicyRegistry.sol";
import {DepositPolicy} from "src/policies/DepositPolicy.sol";
import {FundsBridgingPolicy} from "src/policies/FundsBridgingPolicy.sol";
import {WithdrawalExecutionPolicy} from "src/policies/WithdrawalExecutionPolicy.sol";

/// @title  Policy migration base (VA-347) — chain-agnostic logic.
/// @notice Migrates DepositPolicy / FundsBridgingPolicy / WithdrawalExecutionPolicy to the
///         global-rate-limit / non-upgradeable versions that prod runs, on an ALREADY-LIVE env (preprod),
///         WITHOUT touching the deliberate per-env differences (delays, owners, caps).
///
/// The genesis deploy did all of this immediately because the deployer transiently held ADMIN_ROLE.
/// On a live env every wiring call is AccessManager-gated, so we go through schedule()/execute(). Each
/// STEP is a separate external entrypoint (a separate `forge script` invocation) so the operator can
/// verify between steps and pause across the timelock waits.
///
/// Step sequence (see docs/ENV_CONSISTENCY.md §E):
///   stepDeploy()                          [DEPLOYER]   Create3-deploy the policies at new salts (not gated)
///   verify()                                           (read-only) confirm addresses have code
///   stepScheduleWiring()                  [MAIN ADMIN] schedule() all wiring + setPolicy (CRITICAL = 2h)
///   --- wait 2h ---
///   stepExecuteWiringScheduleBuckets()    [MAIN ADMIN] execute() wiring; setDefaultFeeBps direct;
///                                                      schedule() raise* bucket inits + addSigner (HIGH = 1h)
///   --- wait 1h ---
///   stepExecuteBuckets()                  [MAIN ADMIN] execute() the bucket inits + addSigner
///   verify()                                           (read-only) confirm registry + buckets + roles
///
/// Salt convention (Alan): deploy-commit-suffixed seeds, suffix = prod's accounting deploy commit
/// `b9461591` (`git diff b9461591 HEAD -- src/` is empty ⇒ HEAD bytecode == prod). Kept local here; the
/// canonical Create3AddressBook constants stay clean (prod used those).
abstract contract PolicyMigrationBase is BaseChainDeployment {
    string constant DEPOSIT_POLICY_SALT_V = "aave.stable-vault.DepositPolicy.b9461591";
    string constant FUNDS_BRIDGING_POLICY_SALT_V = "aave.stable-vault.FundsBridgingPolicy.b9461591";
    string constant WITHDRAWAL_EXECUTION_POLICY_SALT_V = "aave.stable-vault.WithdrawalExecutionPolicy.b9461591";

    // --- chain-specific hooks (implemented by the per-chain concrete) -------------------------------
    /// @dev DepositPolicy exists on the accounting chain only.
    function _hasDepositPolicy() internal pure virtual returns (bool);
    /// @dev DepositPolicy registry id (accounting only; unused when !_hasDepositPolicy()).
    function _depositPolicyId() internal pure virtual returns (bytes32);
    /// @dev DepositPolicy applier (accounting: StableVault; unused when !_hasDepositPolicy()).
    function _depositPolicyApplier() internal view virtual returns (address);

    // --- deploy-genesis hooks the migration never invokes (BaseChainDeployment requires them). -------
    //     _isAccountingChain / _chainName are derived from the chain prefix so they stay correct if any
    //     inherited helper reads them; the rest are no-ops (the genesis deploy/setup path is unused).
    function _isAccountingChain() internal pure override returns (bool) {
        return keccak256(bytes(_chainConfigPrefix())) == keccak256(bytes(".accountingChain"));
    }

    function _chainName() internal pure override returns (string memory) {
        return _isAccountingChain() ? "accounting" : "earning";
    }

    function _deployContracts() internal override {}
    function _setupContracts() internal override {}

    function _allocatorDepositor() internal view override returns (address) {
        return address(0);
    }

    function _allocatorWithdrawer() internal view override returns (address) {
        return address(0);
    }

    function _iouTokenManagerVault() internal view override returns (address) {
        return address(0);
    }

    function _aTokenVaultUnderlyings() internal view override returns (address[] memory) {
        return new address[](0);
    }

    // --- address helpers ----------------------------------------------------------------------------
    function _newDepositPolicy() internal view returns (address) {
        return Create3AddressLib.computeCreate3Address(DEPOSIT_POLICY_SALT_V, _deployer());
    }

    function _newFundsBridgingPolicy() internal view returns (address) {
        return Create3AddressLib.computeCreate3Address(FUNDS_BRIDGING_POLICY_SALT_V, _deployer());
    }

    function _newWithdrawalExecutionPolicy() internal view returns (address) {
        return Create3AddressLib.computeCreate3Address(WITHDRAWAL_EXECUTION_POLICY_SALT_V, _deployer());
    }

    function _mainAdmin() internal view returns (address) {
        return _configAddress(".profiles.mainAdmin");
    }

    function _secondaryAdmin() internal view returns (address) {
        return _configAddress(".profiles.secondaryAdmin");
    }

    function _am() internal view returns (IAccessManager) {
        return IAccessManager(getAccessManagerAddress(_deployer()));
    }

    function _ck(string memory suffix) internal pure returns (string memory) {
        return string.concat(_chainConfigPrefix(), suffix);
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////
    // STEP 1 — deploy (DEPLOYER EOA). Create3 deploys are not AccessManager-gated.
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function stepDeploy() external {
        address am = getAccessManagerAddress(_deployer());
        vm.startBroadcast(_deployer());

        if (_hasDepositPolicy()) {
            _deploy_create3({
                namespacedSaltSeed: DEPOSIT_POLICY_SALT_V,
                deployer: _deployer(),
                initCode: abi.encodePacked(type(DepositPolicy).creationCode, abi.encode(am, _depositPolicyApplier()))
            });
        }

        _deploy_create3({
            namespacedSaltSeed: FUNDS_BRIDGING_POLICY_SALT_V,
            deployer: _deployer(),
            initCode: abi.encodePacked(
                type(FundsBridgingPolicy).creationCode, abi.encode(am, _fundsBridgingPolicyHolder())
            )
        });

        // WEP is non-upgradeable: deployed directly (no proxy). defaultFeeBps seeded 0, set in step 3.
        _deploy_create3({
            namespacedSaltSeed: WITHDRAWAL_EXECUTION_POLICY_SALT_V,
            deployer: _deployer(),
            initCode: abi.encodePacked(
                type(WithdrawalExecutionPolicy).creationCode,
                abi.encode(
                    am,
                    _withdrawalExecutionPolicyTarget(),
                    uint16(0),
                    _configUint128(_ck(".withdrawalExecutionPolicy.minRedemptionCapacityRay")),
                    _configUint128(_ck(".withdrawalExecutionPolicy.minRedemptionRefillRateRay"))
                )
            )
        });

        vm.stopBroadcast();

        if (_hasDepositPolicy()) {
            console.log("DepositPolicy (new)            ", _newDepositPolicy());
        }
        console.log("FundsBridgingPolicy (new)      ", _newFundsBridgingPolicy());
        console.log("WithdrawalExecutionPolicy (new)", _newWithdrawalExecutionPolicy());
        console.log("=> notify the App backend team of these new policy addresses (VA-347).");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////
    // STEP 2 — schedule wiring (MAIN ADMIN). Gated at CRITICAL_DELAY (2h preprod).
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function stepScheduleWiring() external {
        vm.startBroadcast(_mainAdmin());
        _wiringOps(true);
        vm.stopBroadcast();
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////
    // STEP 3 — execute wiring, then schedule the bucket inits (MAIN ADMIN), after the 2h wait.
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function stepExecuteWiringScheduleBuckets() external {
        vm.startBroadcast(_mainAdmin());
        _wiringOps(false);

        // NO_DELAY operational setter — callable directly once its selector is bound (this step).
        WithdrawalExecutionPolicy(_newWithdrawalExecutionPolicy())
            .setDefaultFeeBps(_configUint16(".withdrawalExecutionPolicy.defaultFeeBps"));

        _bucketOps(true);
        vm.stopBroadcast();
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////
    // STEP 4 — execute the bucket inits + addSigner (MAIN ADMIN), after the 1h wait.
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function stepExecuteBuckets() external {
        vm.startBroadcast(_mainAdmin());
        _bucketOps(false);
        vm.stopBroadcast();
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////
    // VERIFY — read-only. Reverts on any inconsistency. Safe to run after any step.
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    /// @notice Post-deploy checkpoint (step 1): the new policy contracts exist. Does NOT check wiring —
    ///         run this right after stepDeploy(); run verify() after the full sequence.
    function verifyDeployed() external view {
        require(_newFundsBridgingPolicy().code.length != 0, "FBP not deployed");
        require(_newWithdrawalExecutionPolicy().code.length != 0, "WEP not deployed");
        if (_hasDepositPolicy()) {
            require(_newDepositPolicy().code.length != 0, "DepositPolicy not deployed");
        }
        console.log("verifyDeployed: new policy contracts have code OK");
    }

    function verify() external view {
        address fbp = _newFundsBridgingPolicy();
        address wep = _newWithdrawalExecutionPolicy();
        IPolicyRegistry registry = IPolicyRegistry(getPolicyRegistryAddress(_deployer()));

        require(_newFundsBridgingPolicy().code.length != 0, "FBP not deployed");
        require(_newWithdrawalExecutionPolicy().code.length != 0, "WEP not deployed");
        require(registry.getPolicy(_bridgePolicyId()) == fbp, "registry: bridge policy not repointed");
        require(registry.getPolicy(_withdrawalExecutionPolicyId()) == wep, "registry: WEP not repointed");
        if (_hasDepositPolicy()) {
            require(_newDepositPolicy().code.length != 0, "DepositPolicy not deployed");
            require(
                registry.getPolicy(_depositPolicyId()) == _newDepositPolicy(), "registry: deposit policy not repointed"
            );
        }
        console.log("verify: registry repointed to new policy addresses OK");
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////
    // Op builders. `doSchedule == true` → schedule(); else execute(). Identical op list both passes so
    // the operationId (hashOperation(mainAdmin, target, data)) matches.
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _wiringOps(bool doSchedule) internal {
        IAccessManager am = _am();
        address amAddr = address(am);
        address fbp = _newFundsBridgingPolicy();
        address wep = _newWithdrawalExecutionPolicy();
        address registry = getPolicyRegistryAddress(_deployer());

        // 1) Re-bind every selector of each new policy address to its roleId (target bindings are
        //    address-specific, so all selectors must be rebound to the new contract).
        if (_hasDepositPolicy()) {
            _bindSelectors(am, amAddr, _newDepositPolicy(), _depositRoles(), doSchedule);
        }
        _bindSelectors(am, amAddr, fbp, _bridgingRoles(), doSchedule);
        _bindSelectors(am, amAddr, wep, _wepRoles(), doSchedule);

        // 2) The 8 NEW global roleIds (deposit + bridging) are unconfigured on preprod. Configure +
        //    grant. grantRole BEFORE setGrantDelay so the grant isn't itself delayed (keeps us to 2 waits).
        RolesConfig.Role[] memory globals = _newGlobalRoles();
        for (uint256 i = 0; i < globals.length; i++) {
            RolesConfig.Role memory r = globals[i];
            _op(am, amAddr, abi.encodeCall(IAccessManager.setRoleGuardian, (r.roleId, r.guardianRoleId)), doSchedule);
            _op(am, amAddr, abi.encodeCall(IAccessManager.setRoleAdmin, (r.roleId, r.guardianRoleId)), doSchedule);
            _op(am, amAddr, abi.encodeCall(IAccessManager.grantRole, (r.roleId, _mainAdmin(), r.delay)), doSchedule);
            if (!r.hasCriticalRisk) {
                _op(
                    am,
                    amAddr,
                    abi.encodeCall(IAccessManager.grantRole, (r.roleId, _secondaryAdmin(), r.delay)),
                    doSchedule
                );
            }
            // Disabler holds the lower* globals (execDelay 0). delay==0 distinguishes lower from raise.
            if (r.delay == RolesConfig.NO_DELAY) {
                _op(
                    am,
                    amAddr,
                    abi.encodeCall(IAccessManager.grantRole, (r.roleId, _getProfile__Disabler(), RolesConfig.NO_DELAY)),
                    doSchedule
                );
            }
            _op(am, amAddr, abi.encodeCall(IAccessManager.setGrantDelay, (r.roleId, r.delay)), doSchedule);
        }

        // 3) Re-point the PolicyRegistry to the new addresses (CRITICAL_DELAY).
        if (_hasDepositPolicy()) {
            _op(
                am,
                registry,
                abi.encodeCall(IPolicyRegistry.setPolicy, (_depositPolicyId(), _newDepositPolicy())),
                doSchedule
            );
        }
        _op(am, registry, abi.encodeCall(IPolicyRegistry.setPolicy, (_bridgePolicyId(), fbp)), doSchedule);
        _op(am, registry, abi.encodeCall(IPolicyRegistry.setPolicy, (_withdrawalExecutionPolicyId(), wep)), doSchedule);
    }

    function _bindSelectors(
        IAccessManager am,
        address amAddr,
        address target,
        RolesConfig.Role[] memory roles,
        bool doSchedule
    ) internal {
        for (uint256 i = 0; i < roles.length; i++) {
            _op(
                am,
                amAddr,
                abi.encodeCall(
                    IAccessManager.setTargetFunctionRole, (target, _one(roles[i].selector), roles[i].roleId)
                ),
                doSchedule
            );
        }
    }

    function _bucketOps(bool doSchedule) internal {
        IAccessManager am = _am();
        address fbp = _newFundsBridgingPolicy();
        address wep = _newWithdrawalExecutionPolicy();
        address adapter = getCcipAdapterAddress(_deployer());
        uint256 remoteChainId = _configUint(string.concat(_remoteChainConfigPrefix(), ".chainId"));

        if (_hasDepositPolicy()) {
            address deposit = _newDepositPolicy();
            _initDepositAsset(am, deposit, _gho(), _ck(".depositPolicy.perAssetLimits.gho"), doSchedule);
            _initDepositAsset(am, deposit, _usdc(), _ck(".depositPolicy.perAssetLimits.usdc"), doSchedule);
            _initDepositAsset(am, deposit, _usdt(), _ck(".depositPolicy.perAssetLimits.usdt"), doSchedule);
            _op(
                am,
                deposit,
                abi.encodeCall(
                    DepositPolicy.raiseGlobalDepositCapacity,
                    (_configUint128(_ck(".depositPolicy.globalLimit.capacity")))
                ),
                doSchedule
            );
            _op(
                am,
                deposit,
                abi.encodeCall(
                    DepositPolicy.raiseGlobalDepositRefillRate,
                    (_configUint128(_ck(".depositPolicy.globalLimit.refillRate")))
                ),
                doSchedule
            );
        }

        _initBridgingAsset(
            am, fbp, _gho(), remoteChainId, adapter, _ck(".fundsBridgingPolicy.perAssetLimits.gho"), doSchedule
        );
        _initBridgingAsset(
            am, fbp, _usdc(), remoteChainId, adapter, _ck(".fundsBridgingPolicy.perAssetLimits.usdc"), doSchedule
        );
        _initBridgingAsset(
            am, fbp, _usdt(), remoteChainId, adapter, _ck(".fundsBridgingPolicy.perAssetLimits.usdt"), doSchedule
        );
        _op(
            am,
            fbp,
            abi.encodeCall(
                FundsBridgingPolicy.raiseGlobalBridgingCapacity,
                (_configUint128(_ck(".fundsBridgingPolicy.globalLimit.capacity")))
            ),
            doSchedule
        );
        _op(
            am,
            fbp,
            abi.encodeCall(
                FundsBridgingPolicy.raiseGlobalBridgingRefillRate,
                (_configUint128(_ck(".fundsBridgingPolicy.globalLimit.refillRate")))
            ),
            doSchedule
        );

        _op(
            am,
            wep,
            abi.encodeCall(
                WithdrawalExecutionPolicy.raiseRedemptionCapacity,
                (_configUint128(_ck(".withdrawalExecutionPolicy.redemptionLimit.capacityRay")))
            ),
            doSchedule
        );
        _op(
            am,
            wep,
            abi.encodeCall(
                WithdrawalExecutionPolicy.raiseRedemptionRefillRate,
                (_configUint128(_ck(".withdrawalExecutionPolicy.redemptionLimit.refillRateRay")))
            ),
            doSchedule
        );
        _op(
            am,
            wep,
            abi.encodeCall(WithdrawalExecutionPolicy.addSigner, (_configAddress(".withdrawalExecutionPolicy.signer"))),
            doSchedule
        );
    }

    function _initDepositAsset(IAccessManager am, address deposit, address asset, string memory key, bool doSchedule)
        internal
    {
        _op(
            am,
            deposit,
            abi.encodeCall(
                DepositPolicy.raiseDepositCapacity, (asset, _configUint128(string.concat(key, ".capacity")))
            ),
            doSchedule
        );
        _op(
            am,
            deposit,
            abi.encodeCall(
                DepositPolicy.raiseDepositRefillRate, (asset, _configUint128(string.concat(key, ".refillRate")))
            ),
            doSchedule
        );
    }

    function _initBridgingAsset(
        IAccessManager am,
        address fbp,
        address asset,
        uint256 destChainId,
        address adapter,
        string memory key,
        bool doSchedule
    ) internal {
        _op(
            am,
            fbp,
            abi.encodeCall(
                FundsBridgingPolicy.raiseBridgingCapacity,
                (asset, destChainId, adapter, _configUint128(string.concat(key, ".capacity")))
            ),
            doSchedule
        );
        _op(
            am,
            fbp,
            abi.encodeCall(
                FundsBridgingPolicy.raiseBridgingRefillRate,
                (asset, destChainId, adapter, _configUint128(string.concat(key, ".refillRate")))
            ),
            doSchedule
        );
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////
    // schedule()/execute() primitive. `target` is the AccessManager (admin ops) or the policy/registry.
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _op(IAccessManager am, address target, bytes memory data, bool doSchedule) internal {
        if (doSchedule) {
            // when=0 → earliest allowed (now + setback). Idempotent: skip if already scheduled & pending.
            bytes32 id = am.hashOperation(_mainAdmin(), target, data);
            if (am.getSchedule(id) != 0) {
                return;
            }
            am.schedule(target, data, 0);
        } else {
            am.execute(target, data);
        }
    }

    function _one(bytes4 selector) internal pure returns (bytes4[] memory arr) {
        arr = new bytes4[](1);
        arr[0] = selector;
    }

    ///////////////////////////////////////////////////////////////////////////////////////////////////
    // Role sets (data only — from RolesConfig helpers; same selectors → same roleIds as genesis).
    ///////////////////////////////////////////////////////////////////////////////////////////////////

    function _depositRoles() internal view returns (RolesConfig.Role[] memory r) {
        r = new RolesConfig.Role[](8);
        r[0] = getRole__raiseDepositCapacity();
        r[1] = getRole__raiseDepositRefillRate();
        r[2] = getRole__lowerDepositCapacity();
        r[3] = getRole__lowerDepositRefillRate();
        r[4] = getRole__raiseGlobalDepositCapacity();
        r[5] = getRole__raiseGlobalDepositRefillRate();
        r[6] = getRole__lowerGlobalDepositCapacity();
        r[7] = getRole__lowerGlobalDepositRefillRate();
    }

    function _bridgingRoles() internal view returns (RolesConfig.Role[] memory r) {
        r = new RolesConfig.Role[](8);
        r[0] = getRole__raiseBridgingCapacity();
        r[1] = getRole__raiseBridgingRefillRate();
        r[2] = getRole__lowerBridgingCapacity();
        r[3] = getRole__lowerBridgingRefillRate();
        r[4] = getRole__raiseGlobalBridgingCapacity();
        r[5] = getRole__raiseGlobalBridgingRefillRate();
        r[6] = getRole__lowerGlobalBridgingCapacity();
        r[7] = getRole__lowerGlobalBridgingRefillRate();
    }

    function _wepRoles() internal view returns (RolesConfig.Role[] memory r) {
        r = new RolesConfig.Role[](8);
        r[0] = getRole__setDefaultFeeBps();
        r[1] = getRole__setAssetFeeBps();
        r[2] = getRole__addSigner();
        r[3] = getRole__removeSigner();
        r[4] = getRole__raiseRedemptionCapacity();
        r[5] = getRole__raiseRedemptionRefillRate();
        r[6] = getRole__lowerRedemptionCapacity();
        r[7] = getRole__lowerRedemptionRefillRate();
    }

    /// @dev The genuinely-new roleIds on preprod: the 8 global deposit/bridging roles.
    function _newGlobalRoles() internal view returns (RolesConfig.Role[] memory r) {
        r = new RolesConfig.Role[](8);
        r[0] = getRole__raiseGlobalDepositCapacity();
        r[1] = getRole__raiseGlobalDepositRefillRate();
        r[2] = getRole__lowerGlobalDepositCapacity();
        r[3] = getRole__lowerGlobalDepositRefillRate();
        r[4] = getRole__raiseGlobalBridgingCapacity();
        r[5] = getRole__raiseGlobalBridgingRefillRate();
        r[6] = getRole__lowerGlobalBridgingCapacity();
        r[7] = getRole__lowerGlobalBridgingRefillRate();
    }
}

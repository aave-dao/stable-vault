#!/usr/bin/env bash
#
# VA-347 / VA-359 preprod policy migration — single harness, two modes.
#
# The SAME forge step entrypoints (MigrateAccountingPolicies / MigrateEarningPolicies /
# Va359ClaimSurplusInterest) run in both modes — only the wrapper differs:
#
#   MODE=fork  (default)  boots anvil forks of the real preprod chains, impersonates the deployer +
#                         MainAdmin EOAs (--unlocked --sender), and fakes the timelock waits with
#                         evm_increaseTime. End-to-end in one invocation. NEVER touches a live chain.
#
#   MODE=live             broadcasts the very same steps to the real chains, signing from a Foundry
#                         keystore (--account, validated against the config address). Anvil's
#                         evm_increaseTime is not available on a live chain, so at each timelock
#                         boundary the run STOPS and prints the exact resume command — you wait the
#                         real delay, then re-run with START_FROM=<next step>. This mirrors
#                         adi-deploy/scripts/stable-vaults/run-deployment.sh (MODE/PHASE + keystore +
#                         CONFIRM guard + START_FROM/STOP_BEFORE step gating).
#
# Usage:
#   script/migrate/preprod/run-migration.sh [flags]
#
#   --mode fork|live        (default: fork)
#   --live                  shorthand for --mode live
#   --phase dry-run|broadcast
#                           default: fork=broadcast, live=dry-run. live broadcast also needs
#                           CONFIRM_LIVE_BROADCAST=YES.
#   --broadcast|--dry-run   shorthand for --phase …
#   --chains a,b            which chains (default both). accounting=Arbitrum, earning=Ethereum.
#                           On live, drive ONE chain per process (a boundary halts the whole run).
#   --start-from <step>     resume at a named step (skip everything before it). Live timelock resume.
#   --stop-before <step>    stop just before a named step.
#   --no-va359              skip the VA-359 claimSurplusInterest re-config.
#   --dashboard             (fork only) dashboard consistency check vs prod.
#   --keep-anvil            (fork only) leave the anvil forks running.
#   --dump-txs              dump every forge broadcast tx to docs/migration-tx-dump/.
#
# Step names (for --start-from / --stop-before), per chain label (arbitrum|ethereum):
#   <label>:deploy  <label>:verifyDeployed  <label>:scheduleWiring  <label>:executeWiring
#   <label>:executeBuckets  <label>:verify
#   <label>:va359:schedule  <label>:va359:execute  <label>:va359:verify
#
# MODE=live env vars:
#   DEPLOYER_ACCOUNT     Foundry keystore name that resolves to the config `deployer` (for the deploy step)
#   MAINADMIN_ACCOUNT    Foundry keystore name that resolves to `profiles.mainAdmin` (for schedule/execute)
#   KEYCHAIN_SERVICE     (optional) macOS Keychain service to read the keystore password from
#                        (account = the *_ACCOUNT name). If unset, the password is prompted once per role.
#   CONFIRM_LIVE_BROADCAST=YES   required to actually broadcast on live.
#   VERIFY_CONTRACTS=true|false  (default true on live) Etherscan-verify the deploy step; needs ETHERSCAN_API_KEY.
#
# Requires: foundry (anvil/forge/cast), node, and ALCHEMY_KEY in ./.env (or RPC_MAINNET/RPC_ARBITRUM).
set -euo pipefail

cd "$(dirname "$0")/../../.."            # repo root (based-boosted-vaults)
ROOT="$PWD"
CONFIG="config/deployment-config.preprod.jsonc"
DASHBOARD="${DASHBOARD_REPO:-$ROOT/../stable-vault-dashboard}"

MODE="${MODE:-fork}"
PHASE="${PHASE:-}"
CHAINS="accounting,earning"
START_FROM="${START_FROM:-}"
STOP_BEFORE="${STOP_BEFORE:-}"
RUN_DASHBOARD=0
KEEP_ANVIL=0
RUN_VA359=1
DUMP_TXS=0
DUMP_DIR="docs/migration-tx-dump"   # gitignored; per-step forge broadcast JSONs + combined all-transactions.json
VERIFY_CONTRACTS="${VERIFY_CONTRACTS:-}"
VERIFY_RETRIES="${VERIFY_RETRIES:-20}"
VERIFY_DELAY="${VERIFY_DELAY:-10}"
CONFIRM_LIVE_BROADCAST="${CONFIRM_LIVE_BROADCAST:-}"
UNVERIFIED_STEPS=()   # steps whose tx broadcast confirmed but Etherscan verification failed (retry later)

while [ $# -gt 0 ]; do
  case "$1" in
    --mode) MODE="$2"; shift 2 ;;
    --live) MODE="live"; shift ;;
    --phase) PHASE="$2"; shift 2 ;;
    --broadcast) PHASE="broadcast"; shift ;;
    --dry-run) PHASE="dry-run"; shift ;;
    --chains) CHAINS="$2"; shift 2 ;;
    --start-from) START_FROM="$2"; shift 2 ;;
    --stop-before) STOP_BEFORE="$2"; shift 2 ;;
    --no-va359) RUN_VA359=0; shift ;;
    --dashboard) RUN_DASHBOARD=1; shift ;;
    --keep-anvil) KEEP_ANVIL=1; shift ;;
    --dump-txs) DUMP_TXS=1; shift ;;
    -h|--help) sed -n '2,60p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

case "$MODE" in fork|live) ;; *) echo "MODE must be fork or live (got '$MODE')" >&2; exit 1 ;; esac
if [ -z "$PHASE" ]; then [ "$MODE" = live ] && PHASE="dry-run" || PHASE="broadcast"; fi
case "$PHASE" in dry-run|broadcast) ;; *) echo "PHASE must be dry-run or broadcast (got '$PHASE')" >&2; exit 1 ;; esac
[ -z "$VERIFY_CONTRACTS" ] && { [ "$MODE" = live ] && VERIFY_CONTRACTS=true || VERIFY_CONTRACTS=false; }

log()  { printf '\033[1;36m== %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
lc()   { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# --- secrets / RPCs ---------------------------------------------------------------------------------
set -a; [ -f .env ] && . ./.env; set +a
ETH_FORK="${RPC_MAINNET:-https://eth-mainnet.g.alchemy.com/v2/${ALCHEMY_KEY:?set ALCHEMY_KEY or RPC_MAINNET}}"
ARB_FORK="${RPC_ARBITRUM:-https://arb-mainnet.g.alchemy.com/v2/${ALCHEMY_KEY}}"

# --- config-derived values (no magic literals) -----------------------------------------------------
cfg() { node -e 'const fs=require("fs");const t=fs.readFileSync(process.argv[1],"utf8").replace(/\/\/.*$/gm,"");const j=JSON.parse(t);const v=process.argv[2].split(".").reduce((o,k)=>o&&o[k],j);process.stdout.write(String(v))' "$CONFIG" "$1"; }
DEPLOYER="$(cfg deployer)"
MAINADMIN="$(cfg profiles.mainAdmin)"
CRITICAL_DELAY="$(cfg criticalDelay)"   # gates wiring + setPolicy (preprod 7200 = 2h)
HIGH_DELAY="$(cfg highDelay)"           # gates the raise* bucket inits   (preprod 3600 = 1h)
FUND_HEX=0x21e19e0c9bab2400000          # 10,000 ETH (fork funding only)
log "MODE=$MODE PHASE=$PHASE  deployer=$DEPLOYER  mainAdmin=$MAINADMIN  criticalDelay=${CRITICAL_DELAY}s  highDelay=${HIGH_DELAY}s"

# --- live preflight ---------------------------------------------------------------------------------
if [ "$MODE" = live ]; then
  [ "$RUN_DASHBOARD" = 1 ] && fail "--dashboard is fork-only"
  [ "$KEEP_ANVIL" = 1 ]    && fail "--keep-anvil is fork-only"
  if [ "$PHASE" = broadcast ] && [ "$CONFIRM_LIVE_BROADCAST" != "YES" ]; then
    fail "Refusing live broadcast. Re-run with CONFIRM_LIVE_BROADCAST=YES after a PHASE=dry-run review."
  fi
  if [ "$PHASE" = broadcast ] && [ "$VERIFY_CONTRACTS" = true ] && [ -z "${ETHERSCAN_API_KEY:-}" ]; then
    log "WARNING: VERIFY_CONTRACTS=true but ETHERSCAN_API_KEY is unset — disabling deploy-step verification."
    VERIFY_CONTRACTS=false
  fi
fi

# --- keystore signers (live only) -------------------------------------------------------------------
# Per-role keystore + macOS-Keychain (or prompted) password, validated against the config address —
# mirrors run-deployment.sh validate_signer, extended to the migration's TWO signer identities.
SIGNER_DEPLOYER_READY=0; PWFILE_DEPLOYER=""
SIGNER_MAINADMIN_READY=0; PWFILE_MAINADMIN=""
PREP_PWFILE=""

_prep_one() { # <keystore-account> <expected-addr> <role-label>
  local acct="$1" want="$2" role="$3" pf addr
  [ -n "$acct" ] || fail "MODE=live needs the keystore account for '$role' (set ${role}_ACCOUNT) resolving to $want"
  pf="$(mktemp "${TMPDIR:-/tmp}/mig-pw.XXXXXX")"; chmod 600 "$pf"
  if [ -n "${KEYCHAIN_SERVICE:-}" ]; then
    security find-generic-password -s "$KEYCHAIN_SERVICE" -a "$acct" -w >"$pf" 2>/dev/null \
      || { rm -f "$pf"; fail "Keychain lookup failed (service=$KEYCHAIN_SERVICE account=$acct)"; }
  else
    printf 'Keystore password for %s account "%s": ' "$role" "$acct" >&2
    local pw; IFS= read -rs pw; echo >&2; printf '%s' "$pw" >"$pf"; unset pw
  fi
  addr="$(cast wallet address --account "$acct" --password-file "$pf" 2>/dev/null)" \
    || { rm -f "$pf"; fail "Could not derive address for keystore account '$acct' (wrong password?)"; }
  [ "$(lc "$addr")" = "$(lc "$want")" ] \
    || { rm -f "$pf"; fail "Keystore account '$acct' resolves to $addr, but config role '$role' = $want"; }
  PREP_PWFILE="$pf"
  ok "live signer '$role': $acct ($addr)"
}

prep_signer() { # <deployer|mainAdmin>
  [ "$MODE" = live ] || return 0
  case "$1" in
    deployer)
      [ "$SIGNER_DEPLOYER_READY" = 1 ] && return 0
      _prep_one "${DEPLOYER_ACCOUNT:-}" "$DEPLOYER" deployer
      PWFILE_DEPLOYER="$PREP_PWFILE"; SIGNER_DEPLOYER_READY=1 ;;
    mainAdmin)
      [ "$SIGNER_MAINADMIN_READY" = 1 ] && return 0
      _prep_one "${MAINADMIN_ACCOUNT:-}" "$MAINADMIN" mainAdmin
      PWFILE_MAINADMIN="$PREP_PWFILE"; SIGNER_MAINADMIN_READY=1 ;;
  esac
}

role_addr()   { case "$1" in deployer) echo "$DEPLOYER";; mainAdmin) echo "$MAINADMIN";; esac; }
acct_for()    { case "$1" in deployer) echo "${DEPLOYER_ACCOUNT:-}";; mainAdmin) echo "${MAINADMIN_ACCOUNT:-}";; esac; }
pwfile_for()  { case "$1" in deployer) echo "$PWFILE_DEPLOYER";; mainAdmin) echo "$PWFILE_MAINADMIN";; esac; }
chain_flag()  { case "$1" in arbitrum) echo accounting;; ethereum) echo earning;; esac; }

# --- step gating (START_FROM / STOP_BEFORE / live boundary halt) ------------------------------------
STARTED=0; [ -z "$START_FROM" ] && STARTED=1
HALT=0
HALT_RESUME=""

should_run() { # <step-name>  → 0 run, 1 skip
  [ "$HALT" = 1 ] && return 1
  if [ -n "$STOP_BEFORE" ] && [ "$1" = "$STOP_BEFORE" ]; then HALT=1; log "stop-before $1"; return 1; fi
  if [ "$STARTED" != 1 ]; then
    if [ "$1" = "$START_FROM" ]; then STARTED=1; else return 1; fi
  fi
  return 0
}

# --- anvil lifecycle (fork only) --------------------------------------------------------------------
ANVIL_PIDS=()
# Collect every forge broadcast JSON (one per step) into DUMP_DIR + a flat all-transactions.json.
collect_txs() {
  [ "$DUMP_TXS" = 1 ] || return 0
  mkdir -p "$DUMP_DIR"; rm -f "$DUMP_DIR"/*.json
  local copied=0
  for f in broadcast/MigrateAccountingPolicies.s.sol/*/*-latest.json \
           broadcast/MigrateEarningPolicies.s.sol/*/*-latest.json \
           broadcast/Va359ClaimSurplusInterest.s.sol/*/*-latest.json; do
    [ -f "$f" ] || continue
    local name; name=$(echo "$f" | sed -E 's#broadcast/(.+)\.s\.sol/([0-9]+)/(.+)-latest\.json#\1__\2__\3#')
    cp "$f" "$DUMP_DIR/${name}.json"; copied=$((copied+1))
  done
  [ "$copied" = 0 ] && { log "no broadcast files to dump"; return 0; }
  node -e '
    const fs=require("fs"),p=require("path"),dir=process.argv[1],out=[];
    for(const f of fs.readdirSync(dir).sort()){
      if(!f.endsWith(".json")||f==="all-transactions.json")continue;
      const m=f.match(/^(.+)__(\d+)__(.+)\.json$/);if(!m)continue;
      const j=JSON.parse(fs.readFileSync(p.join(dir,f),"utf8"));
      (j.transactions||[]).forEach((t,i)=>out.push({
        script:m[1], chainId:+m[2], step:m[3], seq:i,
        type:t.transactionType, targetContract:t.contractName,
        function:t.function, arguments:t.arguments,
        to:(t.transaction||{}).to, value:(t.transaction||{}).value, input:(t.transaction||{}).input,
      }));
    }
    fs.writeFileSync(p.join(dir,"all-transactions.json"),JSON.stringify(out,null,2));
    console.log("combined "+out.length+" transactions across "+fs.readdirSync(dir).filter(x=>x.endsWith(".json")&&x!=="all-transactions.json").length+" steps");
  ' "$DUMP_DIR"
  log "TX dump → $DUMP_DIR/ (per-step JSONs + all-transactions.json)"
}

cleanup() {
  collect_txs   # capture the broadcast JSONs before they are removed below
  if [ "$MODE" = fork ]; then
    # Fork-run broadcast/cache artifacts land under chainId 1/42161 dirs (same as real deploys) — remove
    # them so they can't be mistaken for a real broadcast. On live they are the real receipts → KEEP.
    rm -rf broadcast/MigrateAccountingPolicies.s.sol broadcast/MigrateEarningPolicies.s.sol \
           broadcast/Va359ClaimSurplusInterest.s.sol cache/MigrateAccountingPolicies.s.sol \
           cache/MigrateEarningPolicies.s.sol cache/Va359ClaimSurplusInterest.s.sol 2>/dev/null || true
    rmdir broadcast cache 2>/dev/null || true   # remove if now empty
  fi
  rm -f "$PWFILE_DEPLOYER" "$PWFILE_MAINADMIN" 2>/dev/null || true
  [ "$KEEP_ANVIL" = 1 ] && { log "leaving anvil forks running (--keep-anvil)"; return; }
  for p in "${ANVIL_PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done
}
trap cleanup EXIT

start_anvil() { # <port> <fork-url> <chain-id> <label>
  local port="$1" url="$2" cid="$3" label="$4" rpc="http://127.0.0.1:$1"
  log "starting anvil ($label, chain $cid) on :$port"
  anvil --fork-url "$url" --auto-impersonate --port "$port" --chain-id "$cid" \
    >"/tmp/anvil-$label.log" 2>&1 &
  ANVIL_PIDS+=("$!")
  for _ in $(seq 1 30); do cast block-number --rpc-url "$rpc" >/dev/null 2>&1 && break; sleep 1; done
  cast block-number --rpc-url "$rpc" >/dev/null 2>&1 || fail "anvil ($label) did not come up — see /tmp/anvil-$label.log"
  cast rpc anvil_setBalance "$DEPLOYER"  "$FUND_HEX" --rpc-url "$rpc" >/dev/null
  cast rpc anvil_setBalance "$MAINADMIN" "$FUND_HEX" --rpc-url "$rpc" >/dev/null
  ok "$label fork @ block $(cast block-number --rpc-url "$rpc")  (deployer+mainAdmin funded)"
}

check_chain() { # <rpc> <chain-id> <label>   (live)
  local got; got="$(cast chain-id --rpc-url "$1" 2>/dev/null || true)"
  [ "$got" = "$2" ] || fail "$3 live RPC chain-id is '$got', expected $2 ($1)"
  ok "$3 live RPC ok (chain $2) @ block $(cast block-number --rpc-url "$1")"
}

warp() { # <rpc> <seconds>   (fork only)
  cast rpc evm_increaseTime "$2" --rpc-url "$1" >/dev/null
  cast rpc evm_mine --rpc-url "$1" >/dev/null
}

# --- the one true runners (mode-agnostic step list; mode only changes the forge flags) --------------
file_mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }

# True iff forge's broadcast receipts for <script-file> on <chain-id> are all confirmed (status 0x1) and
# fresh (written after the step started). Lets a post-broadcast Etherscan verification failure be
# downgraded to a warning instead of aborting a live run whose txs already landed. (mirrors a.DI)
broadcast_receipts_ok() { # <script-file-basename> <chain-id> <started-at-epoch>
  local run_file="broadcast/$1/$2/run-latest.json" mtime
  [ -f "$run_file" ] || return 1
  mtime="$(file_mtime "$run_file")"
  { [ -n "$mtime" ] && [ "$mtime" -ge "$3" ]; } || return 1
  node -e '
    const fs=require("fs");const d=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
    const r=d.receipts||[]; if(!r.length) process.exit(1);
    for(const x of r){const s=x.status; if(s!=="0x1"&&s!==1&&s!=="1") process.exit(1);}
    process.exit(0);
  ' "$run_file"
}

run_forge() { # <step-name> <logfile|""> <verify-active 0|1> <rpc> <contract> <forge-args...>
  local name="$1" logf="$2" vfy="$3" rpc="$4" contract="$5"; shift 5
  local out exit_code=0 started_at
  started_at="$(date +%s)"
  out="$(forge script "$@" 2>&1)" || exit_code=$?
  if [ "$exit_code" -ne 0 ]; then
    # If this step requested --verify, a confirmed-but-unverified broadcast is recoverable: the txs
    # landed (Create3 deploy is now occupied; re-running stepDeploy would revert), so warn + continue
    # and let the operator re-verify with --resume later, rather than aborting mid-migration.
    if [ "$vfy" = 1 ]; then
      local cid; cid="$(cast chain-id --rpc-url "$rpc" 2>/dev/null || true)"
      if [ -n "$cid" ] && broadcast_receipts_ok "${contract}.s.sol" "$cid" "$started_at"; then
        echo "$out" | tail -15
        log "WARNING: Etherscan verification failed for $name, but broadcast receipts are confirmed — continuing."
        UNVERIFIED_STEPS+=("$name (chain $cid): ${contract}.s.sol")
        [ -n "$logf" ] && { echo "$out" >"$logf"; grep -E "\(new\)" "$logf" || true; }
        ok "$name (broadcast confirmed; verification deferred)"
        return 0
      fi
    fi
    echo "$out" | tail -40; fail "$name reverted"
  fi
  echo "$out" | grep -qE "ONCHAIN EXECUTION COMPLETE & SUCCESSFUL|Script ran successfully" \
    || { echo "$out" | tail -40; fail "$name did not report success"; }
  if [ -n "$logf" ]; then echo "$out" >"$logf"; grep -E "\(new\)" "$logf" || true; fi
  ok "$name"
}

# wstep — a broadcasting step. The forge entrypoint + sender are IDENTICAL across modes; only the
# signing/broadcast flags differ (fork: impersonate; live: keystore + gas flags + optional verify).
wstep() { # <name> <contract> <fn> <rpc> <role> [verify] [logfile]
  local name="$1" contract="$2" fn="$3" rpc="$4" role="$5" do_verify="${6:-}" logf="${7:-}"
  should_run "$name" || return 0
  local sender; sender="$(role_addr "$role")"
  local vfy=0
  local args=("$contract" --sig "${fn}()" --rpc-url "$rpc" --sender "$sender")
  if [ "$MODE" = fork ]; then
    args+=(--unlocked)
    [ "$PHASE" = broadcast ] && args+=(--broadcast)
  else
    prep_signer "$role"
    args+=(--account "$(acct_for "$role")")
    local pf; pf="$(pwfile_for "$role")"
    [ -n "$pf" ] && args+=(--password-file "$pf" --non-interactive)
    args+=(--slow --gas-estimate-multiplier 130)
    if [ "$PHASE" = broadcast ]; then
      args+=(--broadcast)
      if [ "$do_verify" = verify ] && [ "$VERIFY_CONTRACTS" = true ]; then
        args+=(--verify --retries "$VERIFY_RETRIES" --delay "$VERIFY_DELAY"); vfy=1
      fi
    fi
  fi
  log "[$name] ${contract}.${fn}() ($MODE/$PHASE, sender=$role)"
  run_forge "$name" "$logf" "$vfy" "$rpc" "$contract" "${args[@]}"
}

# rstep — a read-only verify entrypoint. Same in both modes (no signer, no broadcast).
rstep() { # <name> <contract> <fn> <rpc> <needle>
  should_run "$1" || return 0
  forge script "$2" --sig "$3()" --rpc-url "$4" 2>&1 | grep -E "$5" || fail "$2.$3() failed"
  ok "$1"
}

# boundary — the timelock wait. fork: warp; live: stop and emit the resume command.
boundary() { # <name> <rpc> <seconds> <delay-label> <next-step>
  should_run "$1" || return 0
  if [ "$MODE" = fork ]; then
    log "warp +$3s ($4)"; warp "$2" "$3"
  else
    local cl="${5%%:*}" pre="MODE=live PHASE=$PHASE"
    [ "$PHASE" = broadcast ] && pre="$pre CONFIRM_LIVE_BROADCAST=YES"
    HALT_RESUME="$pre script/migrate/preprod/run-migration.sh --chains $(chain_flag "$cl") --start-from $5"
    [ "$RUN_VA359" = 0 ] && HALT_RESUME="$HALT_RESUME --no-va359"
    log "TIMELOCK ($4): wait $3s (~$(($3/3600))h $((($3%3600)/60))m) of REAL time on live, then resume:"
    printf '    \033[1;33m%s\033[0m\n' "$HALT_RESUME"
    HALT=1
  fi
}

migrate_chain() { # <contract> <rpc> <label>
  local c="$1" rpc="$2" L="$3"
  log "[$L] migrating via $c"
  wstep    "$L:deploy"          "$c" stepDeploy "$rpc" deployer verify "/tmp/migrate-$L-deploy.log"
  rstep    "$L:verifyDeployed"  "$c" verifyDeployed "$rpc" "verifyDeployed:"
  wstep    "$L:scheduleWiring"  "$c" stepScheduleWiring "$rpc" mainAdmin
  boundary "$L:wait-critical"   "$rpc" "$CRITICAL_DELAY" criticalDelay "$L:executeWiring"
  wstep    "$L:executeWiring"   "$c" stepExecuteWiringScheduleBuckets "$rpc" mainAdmin
  boundary "$L:wait-high"       "$rpc" "$HIGH_DELAY" highDelay "$L:executeBuckets"
  wstep    "$L:executeBuckets"  "$c" stepExecuteBuckets "$rpc" mainAdmin
  rstep    "$L:verify"          "$c" verify "$rpc" "verify:"
  [ "$HALT" = 1 ] || ok "[$L] migration sequence complete"
}

# VA-359: align preprod claimSurplusInterest to prod. Runs on BOTH chains. Same schedule→+2h→execute→
# +1h→verify cadence (the +1h is the execution-delay 1h→0 reduction setback before verify reads clean).
migrate_va359() { # <rpc> <label>
  local c="Va359ClaimSurplusInterest" rpc="$1" L="$2"
  log "[$L] VA-359 claimSurplusInterest re-config"
  wstep    "$L:va359:schedule" "$c" stepSchedule "$rpc" mainAdmin
  boundary "$L:va359:wait-critical" "$rpc" "$CRITICAL_DELAY" criticalDelay "$L:va359:execute"
  wstep    "$L:va359:execute"  "$c" stepExecute "$rpc" mainAdmin
  boundary "$L:va359:wait-high" "$rpc" "$HIGH_DELAY" "exec-delay 1h→0 setback" "$L:va359:verify"
  rstep    "$L:va359:verify"   "$c" verify "$rpc" "verify:"
  [ "$HALT" = 1 ] || ok "[$L] VA-359 complete"
}

# --- run ------------------------------------------------------------------------------------------
forge build script/migrate/preprod/MigrateAccountingPolicies.s.sol \
             script/migrate/preprod/MigrateEarningPolicies.s.sol \
             script/migrate/preprod/Va359ClaimSurplusInterest.s.sol >/dev/null || fail "compile failed"

if [ "$MODE" = fork ]; then
  case ",$CHAINS," in *,accounting,*) start_anvil 8546 "$ARB_FORK" 42161 arbitrum ;; esac
  case ",$CHAINS," in *,earning,*)    start_anvil 8545 "$ETH_FORK" 1     ethereum ;; esac
  ARB_RPC="http://127.0.0.1:8546"; ETH_RPC="http://127.0.0.1:8545"
else
  ARB_RPC="$ARB_FORK"; ETH_RPC="$ETH_FORK"
  case ",$CHAINS," in *,accounting,*) check_chain "$ARB_RPC" 42161 arbitrum ;; esac
  case ",$CHAINS," in *,earning,*)    check_chain "$ETH_RPC" 1     ethereum ;; esac
fi

case ",$CHAINS," in *,accounting,*) migrate_chain MigrateAccountingPolicies "$ARB_RPC" arbitrum ;; esac
if [ "$RUN_VA359" = 1 ]; then case ",$CHAINS," in *,accounting,*) migrate_va359 "$ARB_RPC" arbitrum ;; esac; fi
case ",$CHAINS," in *,earning,*)    migrate_chain MigrateEarningPolicies    "$ETH_RPC" ethereum ;; esac
if [ "$RUN_VA359" = 1 ]; then case ",$CHAINS," in *,earning,*) migrate_va359 "$ETH_RPC" ethereum ;; esac; fi

# --- optional dashboard convergence check (fork only) ----------------------------------------------
if [ "$RUN_DASHBOARD" = 1 ]; then
  [ -d "$DASHBOARD" ] || fail "dashboard repo not found at $DASHBOARD (set DASHBOARD_REPO)"
  log "dashboard convergence check (preprod-fork vs prod)"
  # New policy addresses are deterministic; lift them from the accounting deploy log.
  DEP=$(grep -oE 'DepositPolicy \(new\) +0x[0-9a-fA-F]{40}' /tmp/migrate-arbitrum-deploy.log | grep -oE '0x[0-9a-fA-F]{40}')
  FBP=$(grep -oE 'FundsBridgingPolicy \(new\) +0x[0-9a-fA-F]{40}' /tmp/migrate-arbitrum-deploy.log | grep -oE '0x[0-9a-fA-F]{40}')
  WEP=$(grep -oE 'WithdrawalExecutionPolicy \(new\) +0x[0-9a-fA-F]{40}' /tmp/migrate-arbitrum-deploy.log | grep -oE '0x[0-9a-fA-F]{40}')
  [ -n "$DEP$FBP$WEP" ] || fail "could not parse new policy addresses (run with --chains including accounting)"
  # NOTE: the StableVault impl upgrade is proven on-chain by verify() (proxy → new impl). We deliberately do
  # NOT re-point its dashboard ::Implementation entry / add an override here: on a fork that triggers noisy
  # immutable-recovery mismatches. So the dashboard still lists StableVault::Implementation impl_differs — a
  # known dashboard-side artifact, like AdiAdapter. Real post-migration: update the JSON addr + add the override.

  restore_dashboard() {
    git -C "$ROOT" checkout -- deployments/preprod/accounting.json deployments/preprod/earning.json 2>/dev/null || true
    git -C "$DASHBOARD" checkout -- config/bytecode-overrides.jsonc web/snapshots/preprod.json web/snapshots/index.json 2>/dev/null || true
    ( cd "$DASHBOARD" && node tools/env-diff.mjs >/dev/null 2>&1 ) || true   # regenerate report from real snapshots
  }
  trap 'restore_dashboard; cleanup' EXIT

  DEP="$DEP" FBP="$FBP" WEP="$WEP" node -e '
    const fs=require("fs");const N={DepositPolicy:process.env.DEP,FundsBridgingPolicy:process.env.FBP,WithdrawalExecutionPolicy:process.env.WEP};
    for(const f of ["deployments/preprod/accounting.json","deployments/preprod/earning.json"]){
      const j=JSON.parse(fs.readFileSync(f,"utf8"));
      for(const k in N) if(j[k]&&N[k]){j[k].address=N[k].toLowerCase();j[k].saltSeed=(j[k].saltSeed||"")+".b9461591";}
      delete j["WithdrawalExecutionPolicy::Implementation"];
      fs.writeFileSync(f,JSON.stringify(j,null,2)+"\n");
    }'
  node -e '
    const fs=require("fs"),p=process.argv[1];let t=fs.readFileSync(p,"utf8");
    for(const c of ["DepositPolicy","FundsBridgingPolicy","WithdrawalExecutionPolicy"])
      if(!t.includes("\""+c+"\"")) t=t.replace(/("AdiAdapter":\s*\{[^}]*\})/, `$1,\n    "${c}": { "commit": "b9461591", "reason": "VA-347 rehearsal" }`);
    fs.writeFileSync(p,t);' "$DASHBOARD/config/bytecode-overrides.jsonc"

  # `npm run check` exits 1 whenever any row is FAIL (its CI contract) — on a fork the source-verification
  # rows are always FAIL (anvil isn't Etherscan), so a non-zero exit here is expected. The env-diff below
  # is the real signal.
  ( cd "$DASHBOARD" && RPC_MAINNET=http://127.0.0.1:8545 RPC_ARBITRUM=http://127.0.0.1:8546 npm run check -- --env preprod >/tmp/dashboard-check.log 2>&1 ) || true
  [ -f "$DASHBOARD/web/snapshots/preprod.json" ] || { tail -20 /tmp/dashboard-check.log; fail "dashboard snapshot not produced"; }
  ( cd "$DASHBOARD" && node tools/env-diff.mjs >/dev/null )
  node -e '
    const j=require(process.argv[1]+"/reports/env-consistency.json");const d=j.envs.preprod.diffs;
    const by={};for(const x of d)by[x.category]=(by[x.category]||0)+1;
    console.log("preprod inconsistencies (post-migration, fork):",j.envs.preprod.count);console.log(by);
    console.log("remaining actionable (non-delay, non-unverified):");
    for(const x of d) if(!["delay_policy","unverified"].includes(x.category)) console.log(`  [${x.category}] ${x.section} | ${x.label}`);
  ' "$DASHBOARD"
  ok "dashboard convergence printed (sibling repos will be restored on exit)"
fi

if [ "${#UNVERIFIED_STEPS[@]}" -gt 0 ]; then
  log "broadcast confirmed but Etherscan verification failed for:"
  for e in "${UNVERIFIED_STEPS[@]}"; do echo "  - $e"; done
  echo "Re-verify later (no re-broadcast) with, e.g.:"
  echo "  forge script <Contract> --sig 'stepDeploy()' --rpc-url <rpc> --resume --verify --retries $VERIFY_RETRIES --delay $VERIFY_DELAY"
fi

if [ -n "$HALT_RESUME" ]; then
  log "halted at a live timelock boundary — wait the delay above, then run the printed resume command."
else
  ok "$([ "$MODE" = live ] && echo "live migration step(s) complete ($PHASE)" || echo "fork rehearsal complete")"
fi

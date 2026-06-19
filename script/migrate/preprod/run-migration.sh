#!/usr/bin/env bash
#
# VA-347 preprod policy migration — fork rehearsal harness.
#
# Mirrors adi-deploy/scripts/stable-vaults/run-deployment.sh: boots anvil forks of the real preprod
# chains, impersonates the deployer + MainAdmin EOAs, and runs the REAL step scripts
# (MigrateAccountingPolicies / MigrateEarningPolicies) end-to-end with evm_increaseTime between the
# timelocked steps. FORK ONLY — this script never broadcasts to a live chain.
#
# Usage:
#   script/migrate/preprod/run-migration.sh [--chains accounting,earning] [--dashboard] [--no-va359] [--keep-anvil]
#
#   --chains      which chains to rehearse (default: both). accounting=Arbitrum, earning=Ethereum.
#   --no-va359    skip the VA-359 claimSurplusInterest re-config (runs by default on the accounting chain).
#   --dashboard   after migrating, run the dashboard consistency check against the forks and diff vs
#                 prod (temporarily patches sibling deployment JSONs + bytecode-overrides; auto-restored).
#   --keep-anvil  leave the anvil forks running after the script exits (for manual poking).
#
# Requires: foundry (anvil/forge/cast), node, and ALCHEMY_KEY in ./.env (or RPC_MAINNET/RPC_ARBITRUM).
set -euo pipefail

cd "$(dirname "$0")/../../.."            # repo root (based-boosted-vaults)
ROOT="$PWD"
CONFIG="config/deployment-config.preprod.jsonc"
DASHBOARD="${DASHBOARD_REPO:-$ROOT/../stable-vault-dashboard}"

CHAINS="accounting,earning"
RUN_DASHBOARD=0
KEEP_ANVIL=0
RUN_VA359=1
DUMP_TXS=0
DUMP_DIR="docs/migration-tx-dump"   # gitignored; per-step forge broadcast JSONs + combined all-transactions.json
while [ $# -gt 0 ]; do
  case "$1" in
    --chains) CHAINS="$2"; shift 2 ;;
    --dashboard) RUN_DASHBOARD=1; shift ;;
    --keep-anvil) KEEP_ANVIL=1; shift ;;
    --no-va359) RUN_VA359=0; shift ;;
    --dump-txs) DUMP_TXS=1; shift ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

log()  { printf '\033[1;36m== %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

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
FUND_HEX=0x21e19e0c9bab2400000          # 10,000 ETH
log "deployer=$DEPLOYER  mainAdmin=$MAINADMIN  criticalDelay=${CRITICAL_DELAY}s  highDelay=${HIGH_DELAY}s"

# --- anvil lifecycle --------------------------------------------------------------------------------
ANVIL_PIDS=()
# Collect every forge broadcast JSON (one per step) into DUMP_DIR + a flat all-transactions.json. Runs
# before broadcast artifacts are removed. Each schedule()/execute() and deploy is a transaction here;
# for schedule()/execute() the wrapped op is in arguments[] (target, inner-calldata, when).
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
  # Fork-run broadcast/cache artifacts land under chainId 1/42161 dirs (same as real deploys) — remove
  # them so they can't be mistaken for a real broadcast.
  rm -rf broadcast/MigrateAccountingPolicies.s.sol broadcast/MigrateEarningPolicies.s.sol \
         broadcast/Va359ClaimSurplusInterest.s.sol cache/MigrateAccountingPolicies.s.sol \
         cache/MigrateEarningPolicies.s.sol cache/Va359ClaimSurplusInterest.s.sol 2>/dev/null || true
  rmdir broadcast cache 2>/dev/null || true   # remove if now empty
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

warp() { # <rpc> <seconds>
  cast rpc evm_increaseTime "$2" --rpc-url "$1" >/dev/null
  cast rpc evm_mine --rpc-url "$1" >/dev/null
}

step() { # <contract> <fn> <rpc> <sender> [logfile]
  local out
  out="$(forge script "$1" --sig "$2()" --rpc-url "$3" --broadcast --unlocked --sender "$4" 2>&1)" \
    || { echo "$out" | tail -30; fail "$1.$2() reverted"; }
  echo "$out" | grep -qE "ONCHAIN EXECUTION COMPLETE & SUCCESSFUL|Script ran successfully" \
    || { echo "$out" | tail -30; fail "$1.$2() did not report success"; }
  [ -n "${5:-}" ] && echo "$out" >"$5"
  ok "$1.$2()"
}

vcheck() { # <contract> <fn> <rpc> <needle> — run a read-only verify entrypoint and assert its log line
  forge script "$1" --sig "$2()" --rpc-url "$3" 2>&1 | grep -E "$4" || fail "$1.$2() failed"
  ok "$1.$2()"
}

migrate_chain() { # <contract> <rpc> <label>
  local c="$1" rpc="$2" label="$3"
  log "[$label] migrating via $c"
  step "$c" stepDeploy "$rpc" "$DEPLOYER" "/tmp/migrate-$label-deploy.log"
  grep -E "\(new\)" "/tmp/migrate-$label-deploy.log" || true
  vcheck "$c" verifyDeployed "$rpc" "verifyDeployed:"            # post-deploy checkpoint (code only)
  step "$c" stepScheduleWiring "$rpc" "$MAINADMIN"
  log "[$label] warp +${CRITICAL_DELAY}s (criticalDelay)"; warp "$rpc" "$CRITICAL_DELAY"
  step "$c" stepExecuteWiringScheduleBuckets "$rpc" "$MAINADMIN"
  log "[$label] warp +${HIGH_DELAY}s (highDelay)"; warp "$rpc" "$HIGH_DELAY"
  step "$c" stepExecuteBuckets "$rpc" "$MAINADMIN"
  vcheck "$c" verify "$rpc" "verify:"                            # full post-migration check
  ok "[$label] migration sequence complete"
}

# VA-359: align preprod claimSurplusInterest to prod (immediate + operational guardian). Runs on BOTH
# chains (the role config + MainAdmin/SecondaryAdmin grants exist on each AccessManager); the script
# branches on chainid for the accounting-only StableVaultManager grantee. Same schedule→+2h→execute→+1h
# cadence; the +1h is the execution-delay (1h→0) reduction setback.
migrate_va359() { # <rpc> <label>
  local c="Va359ClaimSurplusInterest" rpc="$1" label="$2"
  log "[$label] VA-359 claimSurplusInterest re-config"
  step "$c" stepSchedule "$rpc" "$MAINADMIN"
  log "[$label] warp +${CRITICAL_DELAY}s (criticalDelay)"; warp "$rpc" "$CRITICAL_DELAY"
  step "$c" stepExecute "$rpc" "$MAINADMIN"
  log "[$label] warp +${HIGH_DELAY}s (exec-delay 1h→0 setback)"; warp "$rpc" "$HIGH_DELAY"
  vcheck "$c" verify "$rpc" "verify:"
  ok "[$label] VA-359 complete"
}

# --- run ------------------------------------------------------------------------------------------
forge build script/migrate/preprod/MigrateAccountingPolicies.s.sol \
             script/migrate/preprod/MigrateEarningPolicies.s.sol \
             script/migrate/preprod/Va359ClaimSurplusInterest.s.sol >/dev/null || fail "compile failed"

case ",$CHAINS," in *,accounting,*) start_anvil 8546 "$ARB_FORK" 42161 arbitrum ;; esac
case ",$CHAINS," in *,earning,*)    start_anvil 8545 "$ETH_FORK" 1     ethereum ;; esac
case ",$CHAINS," in *,accounting,*) migrate_chain MigrateAccountingPolicies http://127.0.0.1:8546 arbitrum ;; esac
case ",$CHAINS," in *,accounting,*) [ "$RUN_VA359" = 1 ] && migrate_va359 http://127.0.0.1:8546 arbitrum ;; esac
case ",$CHAINS," in *,earning,*)    migrate_chain MigrateEarningPolicies    http://127.0.0.1:8545 ethereum ;; esac
case ",$CHAINS," in *,earning,*)    [ "$RUN_VA359" = 1 ] && migrate_va359 http://127.0.0.1:8545 ethereum ;; esac

# --- optional dashboard convergence check ----------------------------------------------------------
if [ "$RUN_DASHBOARD" = 1 ]; then
  [ -d "$DASHBOARD" ] || fail "dashboard repo not found at $DASHBOARD (set DASHBOARD_REPO)"
  log "dashboard convergence check (preprod-fork vs prod)"
  # New policy addresses are deterministic; lift them from the accounting deploy log.
  DEP=$(grep -oE 'DepositPolicy \(new\) +0x[0-9a-fA-F]{40}' /tmp/migrate-arbitrum-deploy.log | grep -oE '0x[0-9a-fA-F]{40}')
  FBP=$(grep -oE 'FundsBridgingPolicy \(new\) +0x[0-9a-fA-F]{40}' /tmp/migrate-arbitrum-deploy.log | grep -oE '0x[0-9a-fA-F]{40}')
  WEP=$(grep -oE 'WithdrawalExecutionPolicy \(new\) +0x[0-9a-fA-F]{40}' /tmp/migrate-arbitrum-deploy.log | grep -oE '0x[0-9a-fA-F]{40}')
  [ -n "$DEP$FBP$WEP" ] || fail "could not parse new policy addresses (run with --chains including accounting)"

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

ok "fork rehearsal complete"

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ADI_DEPLOY_DIR="$ROOT_DIR/.local/adi-deploy-forktest"

ADI_DEPLOY_REPO="${ADI_DEPLOY_REPO:-https://github.com/aave/adi-deploy.git}"
ADI_DEPLOY_REF="${ADI_DEPLOY_REF:-main}"
ADI_DEPLOY_DIR="${ADI_DEPLOY_DIR:-$DEFAULT_ADI_DEPLOY_DIR}"

ADI_FORK_MODE_WAS_SET="${ADI_FORK_MODE+x}"
ADI_FORK_MODE="${ADI_FORK_MODE:-deployed}"
ADI_DEPLOYMENT_ENV="${ADI_DEPLOYMENT_ENV:-preprod}"

if [ -n "${RUN_ADI_DEPLOY:-}" ] && [ -z "$ADI_FORK_MODE_WAS_SET" ]; then
  if [ "$RUN_ADI_DEPLOY" = "true" ]; then
    ADI_FORK_MODE="fresh"
  elif [ "$RUN_ADI_DEPLOY" = "false" ]; then
    ADI_FORK_MODE="deployed"
  fi
fi

case "$ADI_FORK_MODE" in
  preprod|prod)
    ADI_DEPLOYMENT_ENV="$ADI_FORK_MODE"
    ADI_FORK_MODE="deployed"
    ;;
esac

case "$ADI_FORK_MODE" in
  deployed|fresh)
    ;;
  *)
    echo "Unsupported ADI_FORK_MODE=$ADI_FORK_MODE. Use deployed or fresh." >&2
    exit 1
    ;;
esac

if [ "$ADI_FORK_MODE" = "deployed" ] && [ -z "$ADI_DEPLOYMENT_ENV" ]; then
  echo "ADI_DEPLOYMENT_ENV must be set when ADI_FORK_MODE=deployed." >&2
  exit 1
fi

RUN_ADI_DEPLOY="$([ "$ADI_FORK_MODE" = "fresh" ] && echo true || echo false)"
ADI_DEPLOY_SKIP_UPDATE="${ADI_DEPLOY_SKIP_UPDATE:-false}"

ETH_PORT="${ETH_PORT:-8545}"
ARB_PORT="${ARB_PORT:-8546}"
ETH_FORK_RPC="${ETH_FORK_RPC:-http://127.0.0.1:${ETH_PORT}}"
ARB_FORK_RPC="${ARB_FORK_RPC:-http://127.0.0.1:${ARB_PORT}}"
ETH_FORK_BLOCK="${ETH_FORK_BLOCK:-25196860}"
ARB_FORK_BLOCK="${ARB_FORK_BLOCK:-467697210}"
RUN_DIR="${RUN_DIR:-$ADI_DEPLOY_DIR/.forktest}"

MATCH_CONTRACT="${MATCH_CONTRACT:-AdiAdapterPigeon}"
FORGE_TEST_ARGS="${FORGE_TEST_ARGS:--vvv}"

function log() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

function require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

function checkout_adi_deploy_ref() {
  if [[ "$ADI_DEPLOY_REF" =~ ^pull/([0-9]+)/head$ ]]; then
    local pr_number="${BASH_REMATCH[1]}"
    local pr_branch="adi-deploy-pr-${pr_number}"
    git -C "$ADI_DEPLOY_DIR" fetch origin "$ADI_DEPLOY_REF"
    git -C "$ADI_DEPLOY_DIR" checkout -B "$pr_branch" FETCH_HEAD
  else
    git -C "$ADI_DEPLOY_DIR" fetch origin
    git -C "$ADI_DEPLOY_DIR" checkout "$ADI_DEPLOY_REF"
  fi
}

function log_git_checkout() {
  local adi_head
  local adi_branch
  adi_head="$(git -C "$ADI_DEPLOY_DIR" rev-parse --short HEAD)"
  adi_branch="$(git -C "$ADI_DEPLOY_DIR" branch --show-current)"

  log "adi-deploy checkout"
  echo "ADI_DEPLOY_DIR=$ADI_DEPLOY_DIR"
  echo "ADI_DEPLOY_REF=$ADI_DEPLOY_REF"
  echo "adi-deploy branch=${adi_branch:-detached}"
  echo "adi-deploy commit=$adi_head"

  if [ -d "$ADI_DEPLOY_DIR/lib/aave-delivery-infrastructure" ]; then
    local adi_infra_head
    adi_infra_head="$(git -C "$ADI_DEPLOY_DIR/lib/aave-delivery-infrastructure" rev-parse --short HEAD)"
    echo "aave-delivery-infrastructure commit=$adi_infra_head"
  fi
}

function ensure_adi_deploy_checkout() {
  if [ ! -d "$ADI_DEPLOY_DIR/.git" ]; then
    log "Cloning adi-deploy into $ADI_DEPLOY_DIR"
    mkdir -p "$(dirname "$ADI_DEPLOY_DIR")"
    git clone "$ADI_DEPLOY_REPO" "$ADI_DEPLOY_DIR"
  fi

  if [ "$ADI_DEPLOY_SKIP_UPDATE" != "true" ]; then
    log "Checking out adi-deploy ref $ADI_DEPLOY_REF"
    checkout_adi_deploy_ref
    git -C "$ADI_DEPLOY_DIR" submodule update --init --recursive
  else
    log "Using existing adi-deploy checkout without updates"
  fi

  log_git_checkout
}

function resolve_env_file() {
  if [ -n "${ENV_FILE:-}" ]; then
    ENV_FILE="$(cd "$(dirname "$ENV_FILE")" && pwd)/$(basename "$ENV_FILE")"
  elif [ -f "$ROOT_DIR/.env.forktest" ]; then
    ENV_FILE="$ROOT_DIR/.env.forktest"
  elif [ -f "$ROOT_DIR/.env" ]; then
    ENV_FILE="$ROOT_DIR/.env"
  elif [ -f "$ADI_DEPLOY_DIR/.env.forktest" ]; then
    ENV_FILE="$ADI_DEPLOY_DIR/.env.forktest"
  else
    ENV_FILE="$ROOT_DIR/.env.forktest"
  fi
  export ENV_FILE
}

function load_env() {
  resolve_env_file

  if [ -f "$ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    set +a
  fi

  if [ -z "${ETH_FORK_URL:-}" ]; then
    if [ -n "${RPC_MAINNET:-}" ]; then
      ETH_FORK_URL="$RPC_MAINNET"
    elif [ -n "${ALCHEMY_KEY:-}" ]; then
      ETH_FORK_URL="https://eth-mainnet.g.alchemy.com/v2/${ALCHEMY_KEY}"
    else
      echo "Missing ETH_FORK_URL, RPC_MAINNET, or ALCHEMY_KEY in $ENV_FILE." >&2
      exit 1
    fi
  fi

  if [ -z "${ARB_FORK_URL:-}" ]; then
    if [ -n "${RPC_ARBITRUM:-}" ]; then
      ARB_FORK_URL="$RPC_ARBITRUM"
    elif [ -n "${ALCHEMY_KEY:-}" ]; then
      ARB_FORK_URL="https://arb-mainnet.g.alchemy.com/v2/${ALCHEMY_KEY}"
    else
      echo "Missing ARB_FORK_URL, RPC_ARBITRUM, or ALCHEMY_KEY in $ENV_FILE." >&2
      exit 1
    fi
  fi

  export ETH_FORK_URL
  export ARB_FORK_URL
}

function rpc_ready() {
  cast chain-id --rpc-url "$1" >/dev/null 2>&1
}

function stop_pid_file() {
  local pid_file="$1"
  if [ -f "$pid_file" ]; then
    local pid
    pid="$(<"$pid_file")"
    if [ -n "$pid" ] && kill -0 "$pid" >/dev/null 2>&1; then
      kill "$pid"
      sleep 1
    fi
    rm -f "$pid_file"
  fi
}

function wait_for_rpc() {
  local rpc_url="$1"
  local expected_chain_id="$2"
  local label="$3"

  for _ in $(seq 1 60); do
    if rpc_ready "$rpc_url"; then
      local chain_id
      chain_id="$(cast chain-id --rpc-url "$rpc_url")"
      if [ "$chain_id" != "$expected_chain_id" ]; then
        echo "$label RPC is up, but chain id is $chain_id instead of $expected_chain_id." >&2
        exit 1
      fi
      return
    fi
    sleep 1
  done

  echo "$label RPC did not become ready: $rpc_url" >&2
  exit 1
}

function start_deployed_anvil_forks() {
  load_env
  mkdir -p "$RUN_DIR"

  if [ "${RESTART_ANVIL:-true}" = "true" ]; then
    log "Stopping previous Anvil processes from ${RUN_DIR}, if any"
    stop_pid_file "$RUN_DIR/anvil-ethereum.pid"
    stop_pid_file "$RUN_DIR/anvil-arbitrum.pid"
  fi

  if rpc_ready "$ETH_FORK_RPC"; then
    echo "Ethereum local RPC is already running at $ETH_FORK_RPC." >&2
    echo "Use RESTART_ANVIL=true to restart processes tracked in $RUN_DIR, or choose ETH_PORT." >&2
    exit 1
  fi

  if rpc_ready "$ARB_FORK_RPC"; then
    echo "Arbitrum local RPC is already running at $ARB_FORK_RPC." >&2
    echo "Use RESTART_ANVIL=true to restart processes tracked in $RUN_DIR, or choose ARB_PORT." >&2
    exit 1
  fi

  log "Starting Ethereum Anvil fork on ${ETH_FORK_RPC} at block ${ETH_FORK_BLOCK}"
  anvil \
    --host 127.0.0.1 \
    --port "$ETH_PORT" \
    --fork-url "$ETH_FORK_URL" \
    --fork-block-number "$ETH_FORK_BLOCK" \
    --chain-id 1 \
    --auto-impersonate \
    >"$RUN_DIR/anvil-ethereum.log" 2>&1 &
  echo "$!" >"$RUN_DIR/anvil-ethereum.pid"

  log "Starting Arbitrum Anvil fork on ${ARB_FORK_RPC} at block ${ARB_FORK_BLOCK}"
  anvil \
    --host 127.0.0.1 \
    --port "$ARB_PORT" \
    --fork-url "$ARB_FORK_URL" \
    --fork-block-number "$ARB_FORK_BLOCK" \
    --chain-id 42161 \
    --auto-impersonate \
    >"$RUN_DIR/anvil-arbitrum.log" 2>&1 &
  echo "$!" >"$RUN_DIR/anvil-arbitrum.pid"

  wait_for_rpc "$ETH_FORK_RPC" "1" "Ethereum"
  wait_for_rpc "$ARB_FORK_RPC" "42161" "Arbitrum"
}

function run_adi_deployment() {
  case "$ADI_FORK_MODE" in
    deployed)
      log "Using ${ADI_DEPLOYMENT_ENV} a.DI deployment from adi-deploy JSONs"
      start_deployed_anvil_forks
      ;;
    fresh)
      load_env
      log "Running adi-deploy local fork deployment with ENV_FILE=$ENV_FILE"
      (
        cd "$ADI_DEPLOY_DIR"
        ENV_FILE="$ENV_FILE" \
          ETH_PORT="$ETH_PORT" \
          ARB_PORT="$ARB_PORT" \
          ETH_FORK_BLOCK="$ETH_FORK_BLOCK" \
          ARB_FORK_BLOCK="$ARB_FORK_BLOCK" \
          RESTART_ANVIL="${RESTART_ANVIL:-true}" \
          scripts/stable-vaults/run-local-fork-deployment.sh
      )
      log "adi-deploy local fork deployment completed"
      ;;
    *)
      echo "Unsupported ADI_FORK_MODE=$ADI_FORK_MODE. Use deployed or fresh." >&2
      exit 1
      ;;
  esac
}

function json_get() {
  local json_file="$1"
  local key="$2"
  python3 - "$json_file" "$key" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    print(json.load(f)[sys.argv[2]])
PY
}

function export_deployment_env() {
  local subdir=""
  if [ "$ADI_FORK_MODE" = "deployed" ]; then
    subdir="/$ADI_DEPLOYMENT_ENV"
  fi

  local eth_json="$ADI_DEPLOY_DIR/deployments/stable-vaults${subdir}/ethereum.json"
  local arb_json="$ADI_DEPLOY_DIR/deployments/stable-vaults${subdir}/arbitrum.json"

  if [ ! -f "$eth_json" ] || [ ! -f "$arb_json" ]; then
    echo "Missing adi-deploy deployment JSONs:" >&2
    echo "  $eth_json" >&2
    echo "  $arb_json" >&2
    exit 1
  fi

  export FORK_TEST=true
  export ETH_FORK_RPC
  export ARB_FORK_RPC
  export STABLE_VAULTS_OWNER
  export ETH_CCC
  export ARB_CCC
  export ETH_ARB_ADAPTER
  export ETH_CCIP_ADAPTER
  export ETH_LZ_ADAPTER
  export ETH_HL_ADAPTER
  export ARB_CCIP_ADAPTER
  export ARB_LZ_ADAPTER
  export ARB_HL_ADAPTER

  STABLE_VAULTS_OWNER="${STABLE_VAULTS_OWNER:-$(json_get "$eth_json" owner)}"
  ETH_CCC="${ETH_CCC:-$(json_get "$eth_json" crossChainController)}"
  ARB_CCC="${ARB_CCC:-$(json_get "$arb_json" crossChainController)}"
  ETH_ARB_ADAPTER="${ETH_ARB_ADAPTER:-$(json_get "$eth_json" arbAdapter)}"
  ETH_CCIP_ADAPTER="${ETH_CCIP_ADAPTER:-$(json_get "$eth_json" ccipAdapter)}"
  ETH_LZ_ADAPTER="${ETH_LZ_ADAPTER:-$(json_get "$eth_json" lzAdapter)}"
  ETH_HL_ADAPTER="${ETH_HL_ADAPTER:-$(json_get "$eth_json" hlAdapter)}"
  ARB_CCIP_ADAPTER="${ARB_CCIP_ADAPTER:-$(json_get "$arb_json" ccipAdapter)}"
  ARB_LZ_ADAPTER="${ARB_LZ_ADAPTER:-$(json_get "$arb_json" lzAdapter)}"
  ARB_HL_ADAPTER="${ARB_HL_ADAPTER:-$(json_get "$arb_json" hlAdapter)}"

  log "Stable Vaults fork test config"
  echo "ADI_FORK_MODE=$ADI_FORK_MODE"
  if [ "$ADI_FORK_MODE" = "deployed" ]; then
    echo "ADI_DEPLOYMENT_ENV=$ADI_DEPLOYMENT_ENV"
  fi
  echo "ETH_FORK_RPC=$ETH_FORK_RPC"
  echo "ARB_FORK_RPC=$ARB_FORK_RPC"
  echo "ETH_DEPLOYMENT_JSON=$eth_json"
  echo "ARB_DEPLOYMENT_JSON=$arb_json"
  echo "STABLE_VAULTS_OWNER=$STABLE_VAULTS_OWNER"
  echo "ETH_CCC=$ETH_CCC"
  echo "ARB_CCC=$ARB_CCC"
  echo "ETH_ARB_ADAPTER=$ETH_ARB_ADAPTER"
  echo "ETH_CCIP_ADAPTER=$ETH_CCIP_ADAPTER"
  echo "ETH_LZ_ADAPTER=$ETH_LZ_ADAPTER"
  echo "ETH_HL_ADAPTER=$ETH_HL_ADAPTER"
  echo "ARB_CCIP_ADAPTER=$ARB_CCIP_ADAPTER"
  echo "ARB_LZ_ADAPTER=$ARB_LZ_ADAPTER"
  echo "ARB_HL_ADAPTER=$ARB_HL_ADAPTER"
}

function log_fork_status() {
  log "Local fork status"

  if ! command -v cast >/dev/null 2>&1; then
    echo "cast not found; skipping RPC health details"
    return
  fi

  echo "Ethereum chain id: $(cast chain-id --rpc-url "$ETH_FORK_RPC")"
  echo "Ethereum block:    $(cast block-number --rpc-url "$ETH_FORK_RPC")"
  echo "Arbitrum chain id: $(cast chain-id --rpc-url "$ARB_FORK_RPC")"
  echo "Arbitrum block:    $(cast block-number --rpc-url "$ARB_FORK_RPC")"
}

function run_forge_tests() {
  log "Running Stable Vaults Pigeon fork tests"
  cd "$ROOT_DIR"
  # shellcheck disable=SC2086
  forge test --match-contract "$MATCH_CONTRACT" $FORGE_TEST_ARGS
  log "Stable Vaults Pigeon fork tests completed"
}

require_command git
require_command forge
require_command python3
if [ "$ADI_FORK_MODE" = "deployed" ]; then
  require_command anvil
  require_command cast
fi

ensure_adi_deploy_checkout
run_adi_deployment
export_deployment_env
log_fork_status
run_forge_tests

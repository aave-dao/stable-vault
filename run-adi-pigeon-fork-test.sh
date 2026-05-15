#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_ADI_DEPLOY_DIR="$ROOT_DIR/.local/adi-deploy-forktest"

ADI_DEPLOY_REPO="${ADI_DEPLOY_REPO:-https://github.com/aave/adi-deploy.git}"
ADI_DEPLOY_PR="${ADI_DEPLOY_PR:-2}"
ADI_DEPLOY_REF="${ADI_DEPLOY_REF:-pull/${ADI_DEPLOY_PR}/head}"
ADI_DEPLOY_DIR="${ADI_DEPLOY_DIR:-$DEFAULT_ADI_DEPLOY_DIR}"
RUN_ADI_DEPLOY="${RUN_ADI_DEPLOY:-true}"
ADI_DEPLOY_SKIP_UPDATE="${ADI_DEPLOY_SKIP_UPDATE:-$([ "$RUN_ADI_DEPLOY" = "false" ] && echo true || echo false)}"

ETH_PORT="${ETH_PORT:-8545}"
ARB_PORT="${ARB_PORT:-8546}"
ETH_FORK_RPC="${ETH_FORK_RPC:-http://127.0.0.1:${ETH_PORT}}"
ARB_FORK_RPC="${ARB_FORK_RPC:-http://127.0.0.1:${ARB_PORT}}"

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
    git -C "$ADI_DEPLOY_DIR" fetch origin "$ADI_DEPLOY_REF:refs/heads/$pr_branch"
    git -C "$ADI_DEPLOY_DIR" checkout "$pr_branch"
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

function run_adi_deployment() {
  if [ "$RUN_ADI_DEPLOY" != "true" ]; then
    log "Skipping adi-deploy run; reading existing deployment JSONs"
    return
  fi

  resolve_env_file
  log "Running adi-deploy local fork deployment with ENV_FILE=$ENV_FILE"
  (
    cd "$ADI_DEPLOY_DIR"
    ENV_FILE="$ENV_FILE" \
      ETH_PORT="$ETH_PORT" \
      ARB_PORT="$ARB_PORT" \
      RESTART_ANVIL="${RESTART_ANVIL:-true}" \
      scripts/stable-vaults/run-local-fork-deployment.sh
  )
  log "adi-deploy local fork deployment completed"
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
  local eth_json="$ADI_DEPLOY_DIR/deployments/stable-vaults/ethereum.json"
  local arb_json="$ADI_DEPLOY_DIR/deployments/stable-vaults/arbitrum.json"

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

ensure_adi_deploy_checkout
run_adi_deployment
export_deployment_env
log_fork_status
run_forge_tests

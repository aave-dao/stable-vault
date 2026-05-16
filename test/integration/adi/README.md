# ADI Pigeon Fork Tests

These tests exercise the `AdiAdapter` against local Ethereum and Arbitrum forks,
with a.DI bridge events relayed by Pigeon helpers. They are skipped during a
normal `forge test` run unless `FORK_TEST=true` is set.

## Prerequisites

Run these commands from the repository root.

```sh
git submodule update --init --recursive
cp .env.example .env
```

Set `ALCHEMY_KEY` in `.env`. The wrapper script passes this env file through to
`adi-deploy`, which uses it to start the local fork deployment.

You also need Foundry commands on your `PATH`:

- `forge` to run the tests
- `anvil` to run the local forks
- `cast` for optional fork status output

## Run the Full Pigeon Suite

```sh
./run-adi-pigeon-fork-test.sh
```

By default, the wrapper:

1. Clones `https://github.com/aave/adi-deploy.git` into
   `.local/adi-deploy-forktest`.
2. Checks out `pull/2/head`.
3. Runs `scripts/stable-vaults/run-local-fork-deployment.sh` from `adi-deploy`.
4. Exports the deployed a.DI addresses from
   `deployments/stable-vaults/ethereum.json` and
   `deployments/stable-vaults/arbitrum.json`.
5. Runs:

```sh
forge test --match-contract AdiAdapterPigeon -vvv
```

## Run One Contract or Test

Use `MATCH_CONTRACT` to run a narrower contract:

```sh
MATCH_CONTRACT=AdiAdapterPigeonIouWithdrawal ./run-adi-pigeon-fork-test.sh
```

Use `FORGE_TEST_ARGS` to pass extra Foundry flags:

```sh
MATCH_CONTRACT=AdiAdapterPigeonIouWithdrawal \
FORGE_TEST_ARGS="--match-test test_iouWithdrawalOverAdi_bridgeMintAndBurnLockedAccountingIous -vvvv" \
./run-adi-pigeon-fork-test.sh
```

## Reuse an Existing Local Deployment

If the local forks are already running and the `adi-deploy` deployment JSONs
already exist, skip the deployment step:

```sh
RUN_ADI_DEPLOY=false ./run-adi-pigeon-fork-test.sh
```

The script reads the deployment JSONs from `ADI_DEPLOY_DIR`, which defaults to
`.local/adi-deploy-forktest`. Override it when using a different checkout:

```sh
ADI_DEPLOY_DIR=/path/to/adi-deploy RUN_ADI_DEPLOY=false ./run-adi-pigeon-fork-test.sh
```

## Useful Overrides

```sh
ADI_DEPLOY_REF=main ./run-adi-pigeon-fork-test.sh
ETH_PORT=9545 ARB_PORT=9546 ./run-adi-pigeon-fork-test.sh
ENV_FILE=.env.forktest ./run-adi-pigeon-fork-test.sh
RESTART_ANVIL=false ./run-adi-pigeon-fork-test.sh
```

`ETH_FORK_RPC` and `ARB_FORK_RPC` default to `http://127.0.0.1:8545` and
`http://127.0.0.1:8546`, or to the ports set with `ETH_PORT` and `ARB_PORT`.

## Manual Mode

For debugging, you can bypass the wrapper and run Forge directly against
already-running forks. Export the fork RPCs and the deployment addresses first:

```sh
export FORK_TEST=true
export ETH_FORK_RPC=http://127.0.0.1:8545
export ARB_FORK_RPC=http://127.0.0.1:8546

export STABLE_VAULTS_OWNER=<owner-from-adi-deploy-json>
export ETH_CCC=<ethereum-cross-chain-controller>
export ARB_CCC=<arbitrum-cross-chain-controller>
export ETH_ARB_ADAPTER=<ethereum-arbitrum-native-adapter>
export ETH_CCIP_ADAPTER=<ethereum-ccip-adapter>
export ETH_LZ_ADAPTER=<ethereum-layerzero-adapter>
export ETH_HL_ADAPTER=<ethereum-hyperlane-adapter>
export ARB_CCIP_ADAPTER=<arbitrum-ccip-adapter>
export ARB_LZ_ADAPTER=<arbitrum-layerzero-adapter>
export ARB_HL_ADAPTER=<arbitrum-hyperlane-adapter>

forge test --match-contract AdiAdapterPigeon -vvv
```

The wrapper is preferred because it exports these values from the deployment
JSONs automatically.

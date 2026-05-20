# beelocal

Spin up a local Kubernetes cluster (k3d) with [go-ethereum](https://github.com/ethereum/go-ethereum) and [Bee](https://github.com/ethersphere/bee) running on top — useful for development and end-to-end testing without touching a public network.

It is also invoked from the Bee CI workflow ([`.github/workflows/beekeeper.yml`](https://github.com/ethersphere/bee/blob/master/.github/workflows/beekeeper.yml), via `make beelocal`) to bring up a k3s cluster on the GitHub Actions runner so that [Beekeeper](https://github.com/ethersphere/beekeeper) checks can run against a freshly built Bee image on every PR.

## Usage

```sh
./beelocal.sh
```

The script is driven by environment variables. Defaults (see top of `beelocal.sh`) target the `ethersphere/bee:latest` image against a local `geth-swap` chain in namespace `local`.

```sh
# install with the clef signer enabled
ACTION=install OPTS="clef" ./beelocal.sh

# build a local image and install, skipping the local push step
ACTION=install OPTS="clef skip-local" ./beelocal.sh

# tear down
ACTION=destroy ./beelocal.sh
```

`ACTION` accepts: `build`, `check`, `prepare`, `destroy`, `geth`, `install`, `k8s-local`, `uninstall`, `start`, `stop`, `run` (default).

`OPTS` accepts: `skip-local`, `skip-vet`, `skip-push`, `ci`.

## P2P-WSS support

Enable P2P WebSocket Secure (WSS) support by setting `P2P_WSS_ENABLE=true`. This additionally deploys:

- **[Pebble](https://github.com/letsencrypt/pebble)** — ACME test CA for certificate issuance
- **[p2p-forge](https://github.com/ipshipyard/p2p-forge)** — DNS server for ACME DNS-01 challenge handling

Configure Bee nodes with:

```bash
--autotls-domain="local.test"
--autotls-registration-endpoint="http://p2p-forge.local.svc.cluster.local:8080"
--autotls-ca-endpoint="https://pebble:14000/dir"
```

## Layout

- `beelocal.sh` — main entry script
- `config/` — k3d, geth-swap, pebble and p2p-forge manifests
- `hack/registries.yaml` — k3d registry config

## Maintainers

- [Bee](https://github.com/orgs/ethersphere/teams/bee) team
- [DevOps](https://github.com/orgs/ethersphere/teams/devops) team


# beelocal

Spinup local k8s infra with geth and bee up and running.

## P2P-WSS Support

Enable P2P WebSocket Secure (WSS) support by setting `P2P_WSS_ENABLE=true`. This deploys:

- **Pebble**: ACME test CA for certificate issuance
- **p2p-forge**: DNS server for ACME DNS-01 challenge handling

### Bee Node Configuration

When `P2P_WSS_ENABLE=true`, configure your Bee nodes with:

```bash
--autotls-domain="local.test"
--autotls-registration-endpoint="http://p2p-forge.local.svc.cluster.local:8080"
--autotls-ca-endpoint="https://pebble:14000/dir"
```

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
--autotls-registration-endpoint="http://p2p-forge:8080/v1/_acme-challenge"
--autotls-ca-endpoint="https://pebble:14000/dir"
```

**Get Pebble's root CA certificate:**

```bash
# Retrieve Pebble root CA certificate
kubectl run -n local --rm -i --restart=Never get-ca --image=curlimages/curl:latest -- \
  curl -k -s https://pebble:15000/roots/0 > pebble-root-ca.pem
```

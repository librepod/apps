# Bootstrap PVC Component

Bootstraps Step Certificates CA on a PersistentVolumeClaim instead of Kubernetes Secrets/ConfigMaps.

## How It Works

1. **PreSync Job** runs before each ArgoCD sync
2. Checks if CA exists at `/home/step/config/ca.json` on PVC
3. If not found, runs `step ca init` and writes CA material to PVC
4. Writes passwords to `/home/step/secrets/passwords/` for the StatefulSet
5. **StatefulSet** mounts the same PVC and starts step-ca

## Security Benefits

- CA private keys never stored in Kubernetes Secrets/ConfigMaps
- No RBAC permissions needed (no kubectl access)
- Data isolated to PVC backup scope

## Configuration

Edit `job.env` to configure:
- `CA_NAME` - CA name
- `CA_DNS_*` - DNS names for the CA certificate
- `CA_ADDRESS` - Bind address (use `0.0.0.0:9000` for health probes)
- `CA_URL` - CA URL for clients

## Differences from ConfigMap Approach

| ConfigMap Approach | PVC Approach |
|-------------------|--------------|
| Secrets in etcd | Secrets on PVC only |
| Needs RBAC for Secrets/ConfigMaps | No RBAC needed |
| Job pushes to Kubernetes API | Job writes to PVC directly |
| Sync complexity (Job → Secrets → Deployment) | Simple (Job → PVC → Deployment) |
| Visible in `kubectl get secrets` | Requires PVC inspection |

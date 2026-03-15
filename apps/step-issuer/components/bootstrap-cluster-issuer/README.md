# bootstrap-cluster-issuer

A Kustomize component for `step-issuer` that automatically creates a `StepClusterIssuer` resource after `step-certificates` is bootstrapped. It eliminates the need to manually extract CA credentials or store sensitive data in Git.

## Why this exists

The `StepClusterIssuer` custom resource requires three pieces of data that are only available at runtime — after the Step CA has been initialized:

- The root CA certificate (base64-encoded) for the `caBundle` field
- The JWK provisioner's `kid`, parsed from `ca.json`
- A reference to the provisioner password Secret (created by `bootstrap-step-resources`)

This component automates the extraction and wires everything together on first deployment.

## How it works

A Kubernetes `Job` runs at deployment time and:

1. Mounts the `step-certificates` PVC (read-only) to access `ca.json` and `root_ca.crt`
2. Polls until the `step-certificates-provisioner-password` Secret is available
3. Base64-encodes `root_ca.crt` to produce the `caBundle` value
4. Parses `ca.json` with `jq` to extract the JWK provisioner's `kid` from `.key.kid`
5. Generates and applies the `StepClusterIssuer` manifest via `kubectl apply`

```
step-certificates PVC (read-only)
    ↓
Job container (cr.smallstep.com/smallstep/step-ca image)
    ↓
  root_ca.crt  ──→  base64  ──→  caBundle
  ca.json      ──→  jq      ──→  provisioner kid
    ↓
wait for: step-certificates-provisioner-password Secret
    ↓
kubectl apply StepClusterIssuer
```

### Generated StepClusterIssuer

```yaml
apiVersion: certmanager.step.sm/v1beta1
kind: StepClusterIssuer
metadata:
  name: step-cluster-issuer
  namespace: step-ca
spec:
  url: https://step-certificates.step-ca.svc.cluster.local:9000
  caBundle: <base64-encoded root_ca.crt>
  provisioner:
    name: default-jwk
    kid: <extracted from ca.json .authority.provisioners[].key.kid>
    passwordRef:
      name: step-certificates-provisioner-password
      namespace: step-ca
      key: password
```

## File structure

```
components/bootstrap-cluster-issuer/
├── kustomization.yaml   # Component definition; generates ConfigMaps from job.env and job.sh
├── job.yaml             # Kubernetes Job definition
├── job.sh               # Bootstrap script (mounted as ConfigMap)
├── job.env              # Environment variables (mounted as ConfigMap)
├── serviceaccount.yaml  # ServiceAccount for the Job
├── role.yaml            # ClusterRole (StepClusterIssuer) + Role (Secrets in step-ca)
└── rolebinding.yaml     # ClusterRoleBinding + RoleBinding
```

## Configuration

Environment variables are defined in `job.env` and injected via a generated ConfigMap:

| Variable | Value | Description |
|---|---|---|
| `STEPISSUER_NAMESPACE` | `step-ca` | Namespace where the StepClusterIssuer is created |
| `STEPPATH` | `/home/step` | Mount path of the step-certificates PVC |
| `STEP_ISSUER_URL` | `https://step-certificates.step-ca.svc.cluster.local:9000` | CA URL for the issuer spec |
| `PROVISIONER_NAME` | `default-jwk` | Name of the JWK provisioner to use |

## RBAC

The Job uses a dedicated `ServiceAccount` with two separate bindings:

- **ClusterRole + ClusterRoleBinding** — grants `get/create/update/patch` on `stepclusterissuers.certmanager.step.sm` (cluster-scoped resource)
- **Role + RoleBinding** (namespace `step-ca`) — grants `get/list/watch` on `secrets` to poll for the provisioner password

## FluxCD integration

The `step-issuer` FluxCD `Kustomization` (in `infrastructure/apps/step-issuer.yaml`) has:

```yaml
dependsOn:
  - name: step-certificates
  - name: cert-manager
wait: true
```

This ensures that `step-certificates` (and its PVC data) and the `cert-manager` CRDs are fully available before the Job runs. The Job's `ttlSecondsAfterFinished: 10` ensures it is cleaned up by Kubernetes shortly after completion.

> **Note:** The Job manifest carries `argocd.argoproj.io/hook` annotations (PostSync, wave 5, `BeforeHookCreation`). These are ignored by FluxCD but are preserved for potential ArgoCD compatibility.

## Error handling

| Failure | Behaviour |
|---|---|
| Required PVC files missing (`ca.json`, `root_ca.crt`) | Exit 1 with descriptive message |
| `kid` not found in `ca.json` | Exit 1 with parse error |
| Provisioner password Secret not available after 60s (30 × 2s) | Exit 1 with timeout message |
| `kubectl apply` fails | kubectl error output, exit non-zero |

`backoffLimit: 0` — the Job fails fast. On transient failures, re-running is triggered by the next FluxCD reconciliation (interval: 1h).

## Pod security

- Runs as non-root (UID/GID 1000)
- All Linux capabilities dropped
- No privilege escalation
- PVC and script ConfigMap mounted read-only
- Writable `/tmp` via `emptyDir`

## Usage

This component is included in the `librepod` overlay:

```yaml
# overlays/librepod/kustomization.yaml
resources:
  - ../../base
components:
  - ../../components/bootstrap-cluster-issuer
```

To validate the rendered manifests locally:

```bash
kustomize build apps/step-issuer/overlays/librepod
```

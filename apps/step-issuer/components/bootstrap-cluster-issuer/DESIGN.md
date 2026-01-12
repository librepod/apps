# Design: bootstrap-cluster-issuer Component

**Date:** 2026-01-13
**Status:** Design Approved

## Overview

This component automatically creates a `StepClusterIssuer` resource after step-certificates is bootstrapped, eliminating manual credential extraction from Git. It follows the same pattern as `bootstrap-step-resources` but focuses specifically on the cluster-scoped issuer.

## Problem Statement

Currently, the `StepClusterIssuer` manifest requires:
- Manually extracting the CA certificate from the step-certificates PVC
- Base64-encoding the certificate for the `caBundle` field
- Parsing `ca.json` to find the JWK provisioner's `kid`
- Storing sensitive data in Git (provisioner password reference)

This violates GitOps principles and requires manual intervention during cluster setup.

## Solution

An ArgoCD PostSync hook Job that:
1. Mounts the step-certificates PVC (read-only)
2. Extracts the root CA certificate and base64-encodes it
3. Parses `ca.json` to dynamically extract the provisioner `kid`
4. Verifies the provisioner password Secret exists (from `bootstrap-step-resources`)
5. Generates and applies the `StepClusterIssuer` manifest

## Architecture

### Components

#### Job (`job.yaml`)
- **Image:** `cr.smallstep.com/smallstep/step-ca`
- **Hook:** PostSync, wave 5, delete before recreation
- **Volumes:** PVC mount, script ConfigMap, tmp emptyDir
- **Security:** Non-root, drop all capabilities

#### Script (`job.sh`)
1. Download kubectl if not available
2. Extract `root_ca.crt` from PVC
3. Base64-encode for `caBundle` field
4. Parse `ca.json` with `jq` to extract JWK provisioner `kid`
5. Wait for provisioner password Secret (from `bootstrap-step-resources`)
6. Generate and apply `StepClusterIssuer` manifest

#### RBAC (`role.yaml`)
```yaml
rules:
- apiGroups: ["certmanager.step.sm"]
  resources: ["stepclusterissuers"]
  verbs: ["get", "create", "update", "patch"]
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list", "watch"]
```

### Data Flow

```
step-certificates PVC
    ↓
job container (read-only mount)
    ↓
extract data:
  - root_ca.crt → base64 → caBundle
  - ca.json → parse → provisioner kid
    ↓
verify Secret exists
    ↓
kubectl apply StepClusterIssuer
```

## ArgoCD Integration

**Hook Configuration:**
- Type: `PostSync`
- Delete Policy: `BeforeHookCreation`
- Sync Wave: `5` (same as `bootstrap-step-resources`)

**Dependencies:**
- Must run after `bootstrap-step-resources` creates the provisioner password Secret
- Script includes `kubectl wait` with timeout for Secret availability
- Relies on ArgoCD's resource ordering within the same wave

## Configuration

### Environment Variables (`job.env`)

```bash
STEPISSUER_NAMESPACE=step-ca
STEPPATH=/home/step
STEP_ISSUER_URL=https://step-certificates.step-ca.svc.cluster.local:9000
PROVISIONER_NAME=default-jwk
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
  caBundle: <base64-encoded-cert>
  provisioner:
    name: default-jwk
    kid: <extracted-from-ca.json>
    passwordRef:
      name: step-certificates-provisioner-password
      namespace: step-ca
      key: password
```

## Error Handling

**Pre-flight Checks:**
- PVC contains required files (`ca.json`, `root_ca.crt`, passwords)
- Provisioner password Secret exists (with timeout)
- `kid` can be extracted from `ca.json`
- `kubectl` can authenticate to cluster

**Failure Scenarios:**
- Missing PVC data → Exit error 1
- Secret not found after timeout → Exit with descriptive error
- Invalid `ca.json` structure → Exit with parse error
- StepClusterIssuer creation fails → Output kubectl error

**Retry Strategy:**
- `backoffLimit: 0` (fail fast for debugging)
- ArgoCD re-runs on next sync for transient issues

## Security Considerations

**RBAC Scope:**
- Uses namespace-scoped Role (as per requirement)
- Note: Creating cluster-scoped resources with namespace Role is unusual
- May require additional cluster permissions in some Kubernetes distributions

**Data Access:**
- PVC mounted read-only
- No credentials stored in Git
- Secrets referenced, not embedded

**Pod Security:**
- Non-root user (UID 1000)
- All capabilities dropped
- No privilege escalation

## Testing

1. **Static Validation:** `kustomize build` to verify YAML structure
2. **Cluster Deployment:** Apply to test cluster
3. **Dependency Verification:** Confirm it works after `bootstrap-step-resources`
4. **Failure Testing:** Break dependencies to verify error handling
5. **StepClusterIssuer Verification:** Use cert-manager to request a certificate

## Implementation Notes

**kid Extraction:**
The `ca.json` structure contains the JWK provisioner configuration:
```json
{
  "authority": {
    "provisioners": [
      {
        "type": "jwk",
        "name": "default-jwk",
        "key": {...},
        "kid": "_IL5Qmp4l5mMO1bxNgBejbVJdBEQTE0WMs6BA-HfAX0"
      }
    ]
  }
}
```

The script will extract this using:
```bash
kid=$(jq -r '.authority.provisioners[] | select(.type=="jwk") | .kid' "$CA_CONFIG_DIR/ca.json")
```

**Dependencies:**
- `step-certificates` must be initialized (PVC populated)
- `bootstrap-step-resources` must run first (creates password Secret)
- `cert-manager` CRDs must be installed
- `step-issuer` CRDs must be installed

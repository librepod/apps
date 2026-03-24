# OCI-First Bootstrap Architecture — Design Spec

**Date:** 2026-03-24
**Status:** Approved

---

## 1. Goal

Simplify the bootstrap OCI artifact by removing bundled system apps. Instead, all apps (system and user) are published as individual OCI artifacts. The bootstrap artifact becomes a thin orchestration layer that references app artifacts via OCIRepository resources.

This eliminates:
- Manual maintenance of the system app list in `publish-bootstrap.yaml`
- Bundling all system app directories into the bootstrap artifact
- The `librepod-apps` GitRepository dependency

## 2. Constraints and Assumptions

- **Same target environment:** Clean k3s cluster + FluxCD
- **OCI artifacts are pre-published:** User triggers CI to publish all app artifacts before applying bootstrap
- **Retry behavior is acceptable:** GitRepository for private Gogs may show `Ready=False` until Gogs is running
- **Consistency is valued:** System and user apps use identical patterns for publishing and installation
- **No installer UI changes:** This is a backend architecture change; user experience remains git-first

## 3. Architecture Overview

### 3.1 Before (Current)

```
Bootstrap Artifact (large)
├── clusters/
├── infrastructure/
└── apps/                    # All system apps bundled
    ├── traefik/
    ├── cert-manager/
    ├── gogs/
    └── ... (13 apps)

System apps reference GitRepository:
  sourceRef:
    kind: GitRepository
    name: librepod-apps
    path: ./apps/traefik/overlays/librepod
```

### 3.2 After (Proposed)

```
Bootstrap Artifact (thin)
├── clusters/
└── infrastructure/
    ├── apps/
    │   ├── kustomization.yaml
    │   ├── traefik.yaml      # OCIRepository + Kustomization
    │   ├── gogs.yaml         # OCIRepository + Kustomization
    │   └── ...
    └── cluster-config/

System apps reference OCI artifacts:
  sourceRef:
    kind: OCIRepository
    name: traefik
  path: ./overlays/librepod

App artifacts published separately:
  oci://ghcr.io/librepod/marketplace/apps/traefik:latest
  oci://ghcr.io/librepod/marketplace/apps/gogs:latest
  ... (all apps)
```

## 4. Bootstrap Artifact Contents

### 4.1 Directory Structure

```
bootstrap artifact/
├── clusters/
│   └── librepod/
│       ├── flux-system/
│       │   └── (flux-instance configs, no GitRepository)
│       ├── infra-apps.yaml
│       └── infra-configs.yaml
└── infrastructure/
    ├── apps/
    │   ├── kustomization.yaml
    │   ├── traefik.yaml
    │   ├── cert-manager.yaml
    │   ├── step-certificates.yaml
    │   ├── step-issuer.yaml
    │   ├── nfs-provisioner.yaml
    │   ├── gogs.yaml
    │   ├── casdoor.yaml
    │   ├── oauth2-proxy.yaml
    │   ├── reflector.yaml
    │   ├── flux-operator-mcp.yaml
    │   ├── external-secrets.yaml
    │   ├── wg-easy.yaml
    │   └── whoami.yaml
    ├── cluster-config/
    │   ├── kustomization.yaml
    │   ├── gitrepository.yaml
    │   └── kustomization-cr.yaml
    └── configs/
```

### 4.2 No Bundled Apps

The bootstrap artifact no longer contains the `apps/` directory. All apps are fetched via OCI artifacts.

### 4.3 No GitRepository

The `librepod-apps` GitRepository is removed from `clusters/librepod/flux-system/`. All sources are OCI-based.

## 5. System App Infrastructure Files

Each `infrastructure/apps/<app>.yaml` contains two resources: an `OCIRepository` and a `Kustomization`.

### 5.1 Pattern

```yaml
# infrastructure/apps/<app>.yaml
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: OCIRepository
metadata:
  name: <app>
  namespace: flux-system
spec:
  interval: 10m
  url: oci://ghcr.io/librepod/marketplace/apps/<app>
  ref:
    tag: "<version>"
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: <app>
  namespace: flux-system
spec:
  dependsOn:
    - name: <dependency>
  interval: 1h
  retryInterval: 2m
  timeout: 5m
  sourceRef:
    kind: OCIRepository
    name: <app>
  path: ./overlays/librepod
  prune: true
  wait: true
  postBuild:
    substitute:
      BASE_DOMAIN: "${BASE_DOMAIN}"
```

### 5.2 Example: Gogs

```yaml
# infrastructure/apps/gogs.yaml
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: OCIRepository
metadata:
  name: gogs
  namespace: flux-system
spec:
  interval: 10m
  url: oci://ghcr.io/librepod/marketplace/apps/gogs
  ref:
    tag: "0.13.0"
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: gogs
  namespace: flux-system
spec:
  dependsOn:
    - name: nfs-provisioner
    - name: traefik
  interval: 1h
  retryInterval: 2m
  timeout: 5m
  sourceRef:
    kind: OCIRepository
    name: gogs
  path: ./overlays/librepod
  prune: true
  wait: true
  postBuild:
    substitute:
      BASE_DOMAIN: "${BASE_DOMAIN}"
```

### 5.3 Dependency Chain

The existing `dependsOn` relationships are preserved:

```
step-certificates → step-issuer → traefik
                                → cert-manager
nfs-provisioner (independent)
external-secrets (independent)
gogs (depends on nfs-provisioner + traefik)
casdoor, oauth2-proxy, wg-easy, whoami (various dependencies)
```

## 6. Cluster Config Source

The `infrastructure/cluster-config/` directory is part of the bootstrap artifact and its resources are applied directly by the `infra-apps` Kustomization.

### 6.1 File Deletion

`infrastructure/apps/cluster-config-source.yaml` is deleted. It is no longer needed as a Flux Kustomization wrapper.

### 6.2 Retry Behavior

The `cluster-config` GitRepository (pointing at private Gogs) is applied immediately. It will show `Ready=False` until Gogs is running and the init job has created the repo. Flux retries on its 1-minute interval and succeeds once Gogs is ready.

This is acceptable and follows standard Flux patterns for resources with runtime dependencies.

## 7. CI Workflow Changes

### 7.1 publish-apps.yaml

**Current behavior:** Filters out system apps, only publishes user apps.

**New behavior:** Remove the filter. All apps with `metadata.yaml` are published.

```yaml
# REMOVED: System app filtering logic
# SYSTEM_APPS=$(grep '^\s*-.*\.yaml' infrastructure/apps/kustomization.yaml \
#   | sed 's/.*- //' | sed 's/\.yaml//')
# for app in $CHANGED; do
#   if echo "$SYSTEM_APPS" | grep -qx "$app"; then
#     continue
#   fi
#   ...
# done

# NEW: Publish all apps with metadata.yaml
for app in $CHANGED; do
  if [ ! -f "apps/$app/metadata.yaml" ]; then
    continue
  fi
  # Publish app artifact
done
```

### 7.2 publish-bootstrap.yaml

**Current triggers:** `clusters/**`, `infrastructure/**`, and explicit list of 14 system app directories.

**New triggers:** Only `clusters/**` and `infrastructure/**`.

```yaml
on:
  push:
    branches: [master]
    paths:
      - 'clusters/**'
      - 'infrastructure/**'
```

**Current artifact building:** Copies `clusters/`, `infrastructure/`, and system app directories from `infrastructure/apps/kustomization.yaml`.

**New artifact building:** Only copies `clusters/` and `infrastructure/`.

```yaml
- name: Build bootstrap artifact directory
  run: |
    mkdir -p /tmp/bootstrap
    cp -r clusters /tmp/bootstrap/
    cp -r infrastructure /tmp/bootstrap/
    # REMOVED: System app copying logic
```

### 7.3 Publishing Order

1. `publish-apps.yaml` runs (triggered by app changes or manual trigger)
2. All app OCI artifacts exist in registry
3. `publish-bootstrap.yaml` runs (triggered by infrastructure changes or manual trigger)
4. User applies bootstrap artifact
5. Flux pulls app artifacts and reconciles

## 8. System App Metadata Files

All system apps get a `metadata.yaml` following the same schema as user apps.

### 8.1 Schema

```yaml
apiVersion: marketplace/v1
kind: AppDefinition
metadata:
  name: <app>
spec:
  displayName: "<Display Name>"
  description: "<Description>"
  icon: "<icon-url>"
  category: "Infrastructure"
  website: "<project-url>"

  version: "<version>"
  appVersion: "<app-version>"

  source:
    type: oci-kustomize
    url: "oci://ghcr.io/librepod/marketplace/apps/<app>"
    path: ./overlays/librepod

  params:
    required:
      - name: BASE_DOMAIN
        description: "Base domain for the application"
        type: string
        example: "example.com"

  templates:
    source: |
      # OCIRepository template
    release: |
      # Kustomization template
    secret: |
      # Secret template (if needed)
```

### 8.2 Files to Create

| App | File |
|-----|------|
| traefik | `apps/traefik/metadata.yaml` |
| cert-manager | `apps/cert-manager/metadata.yaml` |
| step-certificates | `apps/step-certificates/metadata.yaml` |
| step-issuer | `apps/step-issuer/metadata.yaml` |
| nfs-provisioner | `apps/nfs-provisioner/metadata.yaml` |
| gogs | `apps/gogs/metadata.yaml` |
| casdoor | `apps/casdoor/metadata.yaml` |
| oauth2-proxy | `apps/oauth2-proxy/metadata.yaml` |
| reflector | `apps/reflector/metadata.yaml` |
| flux-operator-mcp | `apps/flux-operator-mcp/metadata.yaml` |
| external-secrets | `apps/external-secrets/metadata.yaml` |
| wg-easy | `apps/wg-easy/metadata.yaml` |
| whoami | `apps/whoami/metadata.yaml` |

### 8.3 Template Usage

The `templates` section is populated for consistency, even though system apps are installed via infrastructure files (not user-initiated Gogs commits). This maintains consistency and could be useful for:
- Documentation generation
- Future installer UI
- Manual recovery procedures

## 9. Summary of Changes

### 9.1 New Files

| File | Purpose |
|------|---------|
| `apps/traefik/metadata.yaml` | System app metadata |
| `apps/cert-manager/metadata.yaml` | System app metadata |
| `apps/step-certificates/metadata.yaml` | System app metadata |
| `apps/step-issuer/metadata.yaml` | System app metadata |
| `apps/nfs-provisioner/metadata.yaml` | System app metadata |
| `apps/gogs/metadata.yaml` | System app metadata |
| `apps/casdoor/metadata.yaml` | System app metadata |
| `apps/oauth2-proxy/metadata.yaml` | System app metadata |
| `apps/reflector/metadata.yaml` | System app metadata |
| `apps/flux-operator-mcp/metadata.yaml` | System app metadata |
| `apps/external-secrets/metadata.yaml` | System app metadata |
| `apps/wg-easy/metadata.yaml` | System app metadata |
| `apps/whoami/metadata.yaml` | System app metadata |

### 9.2 Modified Files

| File | Change |
|------|--------|
| `infrastructure/apps/traefik.yaml` | Convert to OCIRepository + Kustomization |
| `infrastructure/apps/cert-manager.yaml` | Convert to OCIRepository + Kustomization |
| `infrastructure/apps/step-certificates.yaml` | Convert to OCIRepository + Kustomization |
| `infrastructure/apps/step-issuer.yaml` | Convert to OCIRepository + Kustomization |
| `infrastructure/apps/nfs-provisioner.yaml` | Convert to OCIRepository + Kustomization |
| `infrastructure/apps/gogs.yaml` | Convert to OCIRepository + Kustomization |
| `infrastructure/apps/casdoor.yaml` | Convert to OCIRepository + Kustomization |
| `infrastructure/apps/oauth2-proxy.yaml` | Convert to OCIRepository + Kustomization |
| `infrastructure/apps/reflector.yaml` | Convert to OCIRepository + Kustomization |
| `infrastructure/apps/flux-operator-mcp.yaml` | Convert to OCIRepository + Kustomization |
| `infrastructure/apps/external-secrets.yaml` | Convert to OCIRepository + Kustomization |
| `infrastructure/apps/wg-easy.yaml` | Convert to OCIRepository + Kustomization |
| `infrastructure/apps/whoami.yaml` | Convert to OCIRepository + Kustomization |
| `.github/workflows/publish-apps.yaml` | Remove system app filter |
| `.github/workflows/publish-bootstrap.yaml` | Remove app triggers and bundling |
| `clusters/librepod/flux-system/kustomization.yaml` | Remove GitRepository from resources |
| `infrastructure/apps/kustomization.yaml` | Remove cluster-config-source.yaml from resources |

### 9.3 Deleted Files

| File | Reason |
|------|--------|
| `infrastructure/apps/cluster-config-source.yaml` | cluster-config applied directly |
| `clusters/librepod/flux-system/gitrepository.yaml` (or similar) | GitRepository no longer needed |

## 10. Benefits

1. **No manual list maintenance** — System apps are determined by `infrastructure/apps/kustomization.yaml`, not a hardcoded list in CI
2. **Smaller bootstrap artifact** — Only orchestration logic, no bundled apps
3. **Consistent patterns** — System and user apps use identical OCI-based installation
4. **Simpler mental model** — One artifact type per app, bootstrap is just configuration
5. **Independent versioning** — Each app can be versioned and updated independently

## 11. Migration Path

1. Create `metadata.yaml` for all system apps
2. Update `publish-apps.yaml` to remove system app filter
3. Run CI to publish all app artifacts
4. Convert `infrastructure/apps/*.yaml` to OCIRepository + Kustomization pattern
5. Update `publish-bootstrap.yaml` to remove app bundling
6. Remove `librepod-apps` GitRepository
7. Delete `cluster-config-source.yaml`
8. Run CI to publish new bootstrap artifact
9. Test bootstrap on fresh cluster

# Portable Marketplace — Design Spec

**Date:** 2026-03-24
**Status:** Draft

---

## 1. Goal

Make this repository's apps installable on any clean k3s cluster. A user with
bare Kubernetes and FluxCD points Flux at a published OCI artifact and gets:

- Full infrastructure (Traefik, cert-manager, step-certificates, Gogs, etc.)
- A private Git repository on the local Gogs instance for cluster-specific state
- Flux watching that private repo so apps can be installed by committing manifests

Phase 1 is git-first — no installer UI. Users install apps by copying template
manifests into the private Gogs repo. The installer UI is Phase 2.

## 2. Constraints and Assumptions

- **Target environment:** Clean k3s cluster + FluxCD. Nothing else assumed.
- **Monorepo:** System infrastructure and user-installable apps live in this
  repository. One repo to maintain, two types of OCI artifacts published.
- **LibrePod infrastructure is the standard.** No abstraction over ingress
  controllers, storage classes, or TLS providers. Apps ship with
  `overlays/librepod/` and that's the supported configuration.
- **Git is the source of truth.** Desired state lives in the private Gogs repo,
  not in a database or the live cluster.
- **No installer UI in Phase 1.** Users manage apps via Git commits to the
  private Gogs repo.
- **Secrets in the private Gogs repo are acceptable.** The threat model is a
  trusted home network. SOPS/sealed-secrets is a Phase 2 concern.

## 3. OCI Artifact Strategy

### 3.1 Bootstrap Artifact

Published as:

```
oci://ghcr.io/librepod/marketplace/bootstrap:<semver>
oci://ghcr.io/librepod/marketplace/bootstrap:latest
```

Contains the full infrastructure stack that turns a bare k3s + Flux cluster into
a functioning marketplace:

```
bootstrap artifact contents/
├── clusters/librepod/
│   ├── flux-system/
│   ├── infra-apps.yaml
│   └── infra-configs.yaml
├── infrastructure/
│   ├── apps/
│   │   ├── kustomization.yaml
│   │   ├── traefik.yaml
│   │   ├── cert-manager.yaml
│   │   ├── step-certificates.yaml
│   │   ├── step-issuer.yaml
│   │   ├── nfs-provisioner.yaml
│   │   ├── gogs.yaml
│   │   ├── casdoor.yaml
│   │   ├── oauth2-proxy.yaml
│   │   ├── reflector.yaml
│   │   ├── flux-operator-mcp.yaml
│   │   ├── external-secrets.yaml
│   │   └── cluster-config-source.yaml   # NEW
│   └── configs/
├── apps/
│   ├── traefik/
│   ├── cert-manager/
│   ├── step-certificates/
│   ├── step-issuer/
│   ├── nfs-provisioner/
│   ├── gogs/          # includes components/repo-init
│   ├── casdoor/
│   ├── oauth2-proxy/
│   ├── reflector/
│   ├── flux-operator-mcp/
│   └── external-secrets/
```

System apps included in bootstrap are those referenced in
`infrastructure/apps/kustomization.yaml`. Everything else in `apps/` is a
user-installable app published as a separate artifact.

### 3.2 Per-App Artifacts

Published as:

```
oci://ghcr.io/librepod/marketplace/apps/<app-name>:<version>
oci://ghcr.io/librepod/marketplace/apps/<app-name>:latest
```

Each artifact contains the full app directory including the LibrePod overlay:

```
oci://ghcr.io/librepod/marketplace/apps/vaultwarden:1.30.5
└── artifact contents
    ├── base/
    │   ├── kustomization.yaml
    │   ├── namespace.yaml
    │   ├── deployment.yaml
    │   ├── service.yaml
    │   └── pvc.yaml
    ├── overlays/
    │   └── librepod/
    │       ├── kustomization.yaml
    │       └── ingressroute.yaml
    └── metadata.yaml
```

Key: OCI artifacts include `overlays/librepod/`, not just `base/`. The
Kustomization in the private Gogs repo references `path: ./overlays/librepod`.

### 3.3 Catalog

Published as a static YAML file (GitHub Pages or raw file in repo) and
optionally as an OCI artifact:

```
oci://ghcr.io/librepod/marketplace/catalog:<date>
```

Contains the list of available user-installable apps with version, description,
category, icon URL, and OCI artifact URL.

## 4. Bootstrap Flow

### 4.1 User Experience

A user with a fresh k3s cluster and Flux installed runs:

```bash
flux create source oci librepod-marketplace \
  --url=oci://ghcr.io/librepod/marketplace/bootstrap \
  --tag=1.0.0

flux create kustomization librepod-bootstrap \
  --source=OCIRepository/librepod-marketplace \
  --path=./clusters/librepod \
  --prune=true \
  --substitute="BASE_DOMAIN=mydomain.com"
```

Flux pulls the bootstrap artifact and starts reconciling.

### 4.2 Sequencing

The existing `dependsOn` chain handles ordering. The full dependency graph:

```
step-certificates → step-issuer → traefik
                                → cert-manager
nfs-provisioner (independent)
        ↓
      gogs (depends on nfs-provisioner + traefik)
        │
        └── gogs includes repo-init component (Job)
              ↓
      cluster-config-source (GitRepository + Kustomization watching Gogs repo)
```

### 4.3 Gogs Repo Init Component

Instead of a standalone app, the init job is a Kustomize component at
`apps/gogs/components/repo-init/`. It is included via the
`overlays/librepod/kustomization.yaml` components list.

The component adds a Kubernetes Job that:

1. Waits for the Gogs API to be reachable
2. Creates the `librepod` user (or uses a pre-configured admin account)
3. Creates the `cluster-config` repository via the Gogs API
4. Pushes an initial commit with:
   - `repo-metadata.yaml` (layout version)
   - `kustomization.yaml` (root, empty resources list)
5. Creates a deploy key or access token for Flux
6. Stores the credentials in a Kubernetes Secret (`cluster-config-auth`)

The Job is **idempotent**: if the repo already exists (cluster rebuild with
restored Gogs data), it skips creation and ensures the deploy key secret exists.

Component structure:

```
apps/gogs/components/repo-init/
├── kustomization.yaml          # kind: Component
├── init-job.yaml               # Kubernetes Job
└── init-script-configmap.yaml  # Shell script using curl against Gogs API
```

### 4.4 Cluster Config Source

A new infrastructure Kustomization at
`infrastructure/apps/cluster-config-source.yaml` deploys:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: cluster-config
  namespace: flux-system
spec:
  interval: 1m
  url: http://gogs.gogs.svc.cluster.local:3000/librepod/cluster-config.git
  ref:
    branch: main
  secretRef:
    name: cluster-config-auth
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cluster-config
  namespace: flux-system
spec:
  interval: 1m
  sourceRef:
    kind: GitRepository
    name: cluster-config
  path: ./
  prune: true
  wait: true
```

This depends on Gogs being healthy. The GitRepository will retry on its 1-minute
interval until the init job has created the repo and the auth secret.

## 5. App Install Flow (Git-First)

### 5.1 Installing an App

To install an app (e.g., vaultwarden), the user adds three files to the
`cluster-config` repo in Gogs:

**`apps/vaultwarden/source.yaml`:**

```yaml
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: OCIRepository
metadata:
  name: marketplace-vaultwarden
  namespace: flux-system
  labels:
    marketplace.io/managed: "true"
    marketplace.io/app: "vaultwarden"
spec:
  interval: 10m
  url: oci://ghcr.io/librepod/marketplace/apps/vaultwarden
  ref:
    tag: "1.30.5"
```

**`apps/vaultwarden/release.yaml`:**

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: marketplace-vaultwarden
  namespace: flux-system
  labels:
    marketplace.io/managed: "true"
    marketplace.io/app: "vaultwarden"
spec:
  interval: 10m
  targetNamespace: vaultwarden
  sourceRef:
    kind: OCIRepository
    name: marketplace-vaultwarden
  path: ./overlays/librepod
  prune: true
  wait: true
  postBuild:
    substitute:
      BASE_DOMAIN: "mydomain.com"
    substituteFrom:
      - kind: Secret
        name: vaultwarden-config
```

**`apps/vaultwarden/secret.yaml`:**

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: vaultwarden-config
  namespace: vaultwarden
  labels:
    marketplace.io/managed: "true"
    marketplace.io/app: "vaultwarden"
type: Opaque
stringData:
  ADMIN_TOKEN: "some-generated-token"
```

Plus update the root `kustomization.yaml` to include `apps/vaultwarden/`.

The user commits and pushes to Gogs. Flux detects the change, pulls the
vaultwarden OCI artifact, and deploys it.

### 5.2 Template Manifests

Each app's `metadata.yaml` includes or references template manifests that users
can copy into their Gogs repo. This is the primary install mechanism in Phase 1.

### 5.3 Updating an App

Edit manifests in Gogs:

- Change the OCI tag in `source.yaml` for version upgrades
- Change `postBuild.substitute` values in `release.yaml` for config changes
- Change `stringData` in `secret.yaml` for secret rotation

Commit and push. Flux reconciles.

### 5.4 Uninstalling an App

Remove the app directory from the Gogs repo. Update the root
`kustomization.yaml`. Commit and push. Flux prunes the resources.

## 6. App Metadata Schema

Each user-installable app needs a `metadata.yaml`:

```yaml
apiVersion: marketplace/v1
kind: AppDefinition
metadata:
  name: vaultwarden
spec:
  displayName: "Vaultwarden"
  description: "Lightweight Bitwarden-compatible password manager"
  icon: "https://..."
  category: "Security"
  website: "https://github.com/dani-garcia/vaultwarden"

  version: "1.30.5"
  appVersion: "1.30.5"

  source:
    type: oci-kustomize
    url: "oci://ghcr.io/librepod/marketplace/apps/vaultwarden"
    path: ./overlays/librepod

  params:
    required:
      - name: BASE_DOMAIN
        description: "Base domain for the application"
        type: string
        example: "example.com"
    optional:
      - name: STORAGE_CLASS
        description: "Kubernetes storage class"
        type: string
        default: "nfs-client"

  secrets:
    - name: ADMIN_TOKEN
      description: "Admin panel access token"
      generate:
        type: random
        length: 64

  dependencies:
    required:
      - kind: IngressController
      - kind: StorageClass
```

## 7. CI Pipeline

### 7.1 Bootstrap Publishing

**File:** `.github/workflows/publish-bootstrap.yaml`

**Trigger:** Push to `main` changing `clusters/`, `infrastructure/`, or any
system app directory.

**Action:** Uses `flux push artifact` to publish the bootstrap OCI artifact
containing `clusters/`, `infrastructure/`, and system app directories.

System apps are identified by their inclusion in
`infrastructure/apps/kustomization.yaml`.

### 7.2 Per-App Publishing

**File:** `.github/workflows/publish-apps.yaml`

**Trigger:** Push to `main` changing any user-installable app directory.

**Action:** For each changed app, reads the version from `metadata.yaml` and
uses `flux push artifact` to publish the app OCI artifact.

### 7.3 Catalog Publishing

**File:** `.github/workflows/publish-catalog.yaml`

**Trigger:** Runs after per-app publishing.

**Action:** Runs `scripts/generate-catalog.sh` which scans all user-installable
apps' `metadata.yaml` files and produces `catalog.yaml`.

## 8. System vs. User App Classification

| System (in bootstrap artifact) | User-installable (per-app artifact) |
|---|---|
| traefik | vaultwarden |
| cert-manager | open-webui |
| step-certificates | seafile |
| step-issuer | obsidian-livesync |
| nfs-provisioner | litellm |
| gogs | baikal |
| casdoor | happy-server |
| oauth2-proxy | wg-easy |
| reflector | defguard |
| flux-operator-mcp | |
| external-secrets | |

The authoritative marker is inclusion in
`infrastructure/apps/kustomization.yaml`.

## 9. Labeling Convention

All marketplace-generated resources carry:

```yaml
labels:
  marketplace.io/managed: "true"
  marketplace.io/app: "<app-name>"
  marketplace.io/version: "<version>"
```

## 10. Recovery

1. User rebuilds or reprovisions the cluster
2. User restores Gogs PVC or backup of the private repo
3. User runs the bootstrap commands (Section 4.1)
4. Flux reconciles infrastructure, Gogs comes up with existing data
5. Init job detects existing repo and skips creation
6. Flux GitRepository connects to the restored Gogs repo
7. All apps are re-deployed from the private repo state

## 11. Concrete Changes Required

### New files to create

| File | Purpose |
|---|---|
| `apps/<user-app>/metadata.yaml` (9 apps) | App metadata for catalog and templates |
| `apps/gogs/components/repo-init/kustomization.yaml` | Kustomize Component definition |
| `apps/gogs/components/repo-init/init-job.yaml` | Kubernetes Job for Gogs repo bootstrap |
| `apps/gogs/components/repo-init/init-script-configmap.yaml` | Shell script for Gogs API calls |
| `infrastructure/apps/cluster-config-source.yaml` | Flux GitRepository + Kustomization for private repo |
| `.github/workflows/publish-bootstrap.yaml` | CI for bootstrap OCI artifact |
| `.github/workflows/publish-apps.yaml` | CI for per-app OCI artifacts |
| `.github/workflows/publish-catalog.yaml` | CI for catalog generation |
| `scripts/generate-catalog.sh` | Catalog generator script |
| `catalog.yaml` | Generated catalog index |
| `docs/user-guide.md` | Bootstrap and app install instructions |

### Existing files to modify

| File | Change |
|---|---|
| `infrastructure/apps/kustomization.yaml` | Add `cluster-config-source` reference |
| `apps/gogs/overlays/librepod/kustomization.yaml` | Add `components: [../../components/repo-init]` |
| `clusters/librepod/infra-apps.yaml` | Ensure `postBuild.substitute` passes `BASE_DOMAIN` |
| User app overlays (9 apps) | Audit that all user-facing config uses `${VARIABLE}` substitution |

### Not in scope (Phase 2+)

| Item | Phase |
|---|---|
| Marketplace installer UI/API | Phase 2 |
| Abstract ingress/storage/TLS support | Phase 2 |
| SOPS/sealed-secrets integration | Phase 2 |
| CLI tool for app management | Phase 2 |
| Community app submission workflow | Phase 3 |

## 12. Open Decisions

1. **BASE_DOMAIN injection:** User passes `--substitute="BASE_DOMAIN=mydomain.com"`
   when creating the bootstrap Kustomization. This flows through
   `postBuild.substitute` to all infrastructure apps.

2. **Gogs init job implementation:** Shell script using `curl` against the Gogs
   API. Simplest possible approach. Runs as a Kubernetes Job with a
   `busybox`/`alpine` image.

3. **Versioning:** Bootstrap artifact uses repository tags. Per-app artifacts
   use the version from `metadata.yaml`. These are independent.

4. **Catalog delivery:** Static YAML file published to GitHub Pages. Can also
   be published as an OCI artifact if needed later.

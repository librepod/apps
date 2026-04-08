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
  trusted home network.
- **Default branch is `master`.** All CI triggers and Flux references use
  `master`, matching the existing repository convention.

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
│   │   ├── wg-easy.yaml
│   │   ├── whoami.yaml
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
│   ├── external-secrets/
│   ├── wg-easy/
│   └── whoami/
```

System apps included in bootstrap are those referenced in
`infrastructure/apps/kustomization.yaml`. Everything else in `apps/` is a
user-installable app published as a separate artifact.

Note: `external-secrets` exists as `infrastructure/apps/external-secrets.yaml`
but is not currently listed in `infrastructure/apps/kustomization.yaml`. It must
be added to kustomization.yaml as part of this work.

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

A user with a fresh k3s cluster and Flux installed applies these manifests:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: OCIRepository
metadata:
  name: librepod-marketplace
  namespace: flux-system
spec:
  interval: 10m
  url: oci://ghcr.io/librepod/marketplace/bootstrap
  ref:
    tag: "1.0.0"
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: librepod-bootstrap
  namespace: flux-system
spec:
  interval: 10m
  sourceRef:
    kind: OCIRepository
    name: librepod-marketplace
  path: ./clusters/librepod
  prune: true
  postBuild:
    substitute:
      BASE_DOMAIN: "mydomain.com"
```

The user saves this as a YAML file and applies with `kubectl apply -f`. This is
more reliable than `flux create kustomization` because the `--substitute` flag
availability depends on CLI version, and applying raw YAML is explicit and
reproducible.

Flux pulls the bootstrap artifact and starts reconciling.

### 4.2 Sequencing

The existing `dependsOn` chain handles ordering of infrastructure apps. These
are Flux Kustomization-level dependencies defined in the individual
`infrastructure/apps/*.yaml` files.

Relevant dependency chain:

```
step-certificates → step-issuer → traefik
                                → cert-manager
nfs-provisioner (independent)
external-secrets (independent)
gogs (depends on nfs-provisioner + traefik)
casdoor, oauth2-proxy, wg-easy, whoami (various dependencies)
```

**Important:** `cluster-config-source.yaml` is a resource within the `infra-apps`
Kustomization, meaning its GitRepository and Kustomization manifests are applied
at the same time as other infrastructure resources. The GitRepository will fail
to connect until Gogs is running and the init job has created the repo and auth
secret. This is expected — the GitRepository retries on its 1-minute interval
and succeeds once Gogs is ready. The `cluster-config` Kustomization similarly
retries until the GitRepository has a valid source. Flux handles this gracefully;
it will show `Ready=False` during bootstrap and transition to `Ready=True` once
Gogs is operational. This is the standard Flux pattern for resources with
runtime dependencies that can't be expressed via `dependsOn`.

### 4.3 Gogs Repo Init Component

The init job is a Kustomize component at `apps/gogs/components/repo-init/`.

The existing Gogs app already uses a component pattern: the `postgres` component
is referenced from `base/kustomization.yaml` (line 23-24: `components:
[../components/postgres]`). The `repo-init` component follows the same pattern
and is added alongside postgres in `base/kustomization.yaml`.

The component adds:

- A **ServiceAccount** for the init Job
- A **Role** in the `flux-system` namespace granting Secret create/update
- A **RoleBinding** connecting the ServiceAccount to the Role
- A Kubernetes **Job** that:

1. Waits for the Gogs API to be reachable
2. Creates the `librepod` user (or uses a pre-configured admin account)
3. Creates the `cluster-config` repository via the Gogs API
4. Pushes an initial commit with:
   - `repo-metadata.yaml` (layout version)
   - `kustomization.yaml` (root, empty resources list)
5. Creates a deploy key or access token for Flux
6. Creates the `cluster-config-auth` Secret **in the `flux-system` namespace**
   (requires cross-namespace RBAC, see component structure below)

The Job is **idempotent**: if the repo already exists (cluster rebuild with
restored Gogs data), it skips creation. It always ensures the
`cluster-config-auth` Secret exists in `flux-system`, even when the repo is
pre-existing — this handles the case where Gogs PVC was restored but the
cluster was rebuilt and the Secret was lost.

Component structure:

```
apps/gogs/components/repo-init/
├── kustomization.yaml          # kind: Component
├── init-job.yaml               # Kubernetes Job
├── init-script-configmap.yaml  # Shell script using curl against Gogs API
├── rbac.yaml                   # ServiceAccount + Role + RoleBinding
│                                 (grants Secret write in flux-system ns)
```

### 4.4 Cluster Config Source

A new resource file at `infrastructure/apps/cluster-config-source.yaml`
containing a Flux Kustomization that deploys the GitRepository and root
Kustomization for the private Gogs repo:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cluster-config-source
  namespace: flux-system
spec:
  dependsOn:
    - name: gogs
  interval: 1m
  sourceRef:
    kind: GitRepository
    name: librepod-apps
  path: ./infrastructure/cluster-config
  prune: true
  wait: true
```

This is a **Flux Kustomization** (not a raw resource in infra-apps), which
allows proper `dependsOn` on the `gogs` Kustomization. It points to a new
directory `infrastructure/cluster-config/` containing the actual manifests:

```yaml
# infrastructure/cluster-config/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - gitrepository.yaml
  - kustomization-cr.yaml

# infrastructure/cluster-config/gitrepository.yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: cluster-config
  namespace: flux-system
spec:
  interval: 1m
  url: http://gogs.gogs.svc.cluster.local:80/librepod/cluster-config.git
  ref:
    branch: main
  secretRef:
    name: cluster-config-auth

# infrastructure/cluster-config/kustomization-cr.yaml
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

This approach means the cluster-config GitRepository is only created **after**
the Gogs Kustomization is Ready, reducing noisy errors during bootstrap.

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

The `substituteFrom` Secret must be in the **same namespace as the
Kustomization** (`flux-system`), not in the app's target namespace. FluxCD
resolves `substituteFrom` references relative to the Kustomization's own
namespace.

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: vaultwarden-config
  namespace: flux-system
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

**Note on `targetNamespace`:** Setting `targetNamespace` forces all resources
from the OCI artifact into the specified namespace. This works for simple apps
where all resources belong to one namespace. Apps with cross-namespace resources
(e.g., a ClusterRole) should not use `targetNamespace` and should instead define
namespaces explicitly in their manifests.

**Note on `BASE_DOMAIN`:** In Phase 1, users must manually set `BASE_DOMAIN` in
each app's `release.yaml`. There is no automatic injection from the bootstrap
configuration. The template manifests (Section 5.2) include a `${BASE_DOMAIN}`
placeholder that the user replaces with their actual domain. This is a UX
limitation accepted for Phase 1; the installer UI in Phase 2 will automate this.

### 5.2 Template Manifests

Each app's `metadata.yaml` includes a `templates` section with the exact
manifests a user should copy into their Gogs repo, with placeholder values
marked for replacement:

```yaml
# in metadata.yaml
spec:
  templates:
    source: |
      apiVersion: source.toolkit.fluxcd.io/v1beta2
      kind: OCIRepository
      ...
    release: |
      apiVersion: kustomize.toolkit.fluxcd.io/v1
      kind: Kustomization
      ...
    secret: |
      apiVersion: v1
      kind: Secret
      ...
```

This is the primary install mechanism in Phase 1. Users copy these templates,
fill in their values, and commit to the Gogs repo.

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

  templates:
    # Inline template manifests for git-first install (see Section 5.2)
    source: |
      ...
    release: |
      ...
    secret: |
      ...
```

## 7. CI Pipeline

All CI triggers use the `master` branch, matching the existing repository
convention.

### 7.1 Bootstrap Publishing

**File:** `.github/workflows/publish-bootstrap.yaml`

**Trigger:** Push to `master` changing `clusters/`, `infrastructure/`, or any
system app directory.

**Action:** Uses `flux push artifact` to publish the bootstrap OCI artifact
containing `clusters/`, `infrastructure/`, and system app directories.

System apps are identified by their inclusion in
`infrastructure/apps/kustomization.yaml`.

### 7.2 Per-App Publishing

**File:** `.github/workflows/publish-apps.yaml`

**Trigger:** Push to `master` changing any user-installable app directory.

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
| oauth2-proxy | defguard |
| reflector | |
| flux-operator-mcp | |
| external-secrets | |
| wg-easy | |
| whoami | |

The authoritative marker is inclusion in
`infrastructure/apps/kustomization.yaml`.

**Migration notes:**
- `wg-easy` and `whoami` are currently in `infrastructure/apps/kustomization.yaml`
  and remain system apps. They are included in the bootstrap artifact.
- `open-webui` is currently in `infrastructure/apps/kustomization.yaml` (under a
  `# USERS APPS FOR TESTING` comment). It must be **removed** from
  `infrastructure/apps/kustomization.yaml` as part of this work and published as
  a user-installable per-app artifact instead.
- `external-secrets` exists as `infrastructure/apps/external-secrets.yaml` but is
  **not** currently listed in `infrastructure/apps/kustomization.yaml`. It must be
  **added** to the kustomization resources list.

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
3. User applies the bootstrap manifests (Section 4.1)
4. Flux reconciles infrastructure, Gogs comes up with existing data
5. Init job detects existing repo, skips repo creation, but **recreates the
   `cluster-config-auth` Secret** in `flux-system` (which was lost when the
   cluster was rebuilt). This ensures Flux can authenticate to the restored
   Gogs repo.
6. Flux GitRepository connects to the restored Gogs repo
7. All apps are re-deployed from the private repo state

## 11. Concrete Changes Required

### New files to create

| File | Purpose |
|---|---|
| `apps/<user-app>/metadata.yaml` (8 apps) | App metadata for catalog and templates |
| `apps/gogs/components/repo-init/kustomization.yaml` | Kustomize Component definition |
| `apps/gogs/components/repo-init/init-job.yaml` | Kubernetes Job for Gogs repo bootstrap |
| `apps/gogs/components/repo-init/init-script-configmap.yaml` | Shell script for Gogs API calls |
| `apps/gogs/components/repo-init/rbac.yaml` | ServiceAccount + Role + RoleBinding for cross-namespace Secret creation |
| `infrastructure/apps/cluster-config-source.yaml` | Flux Kustomization (dependsOn gogs) pointing to cluster-config dir |
| `infrastructure/cluster-config/kustomization.yaml` | Kustomize resources for GitRepository + Kustomization |
| `infrastructure/cluster-config/gitrepository.yaml` | Flux GitRepository for private Gogs repo |
| `infrastructure/cluster-config/kustomization-cr.yaml` | Flux Kustomization CR for private Gogs repo |
| `.github/workflows/publish-bootstrap.yaml` | CI for bootstrap OCI artifact |
| `.github/workflows/publish-apps.yaml` | CI for per-app OCI artifacts |
| `.github/workflows/publish-catalog.yaml` | CI for catalog generation |
| `scripts/generate-catalog.sh` | Catalog generator script |
| `catalog.yaml` | Generated catalog index |
| `docs/user-guide.md` | Bootstrap and app install instructions |

### Existing files to modify

| File | Change |
|---|---|
| `infrastructure/apps/kustomization.yaml` | Add `cluster-config-source.yaml` and `external-secrets.yaml` to resources; remove `open-webui.yaml` |
| `apps/gogs/base/kustomization.yaml` | Add `../components/repo-init` to existing `components:` list (alongside postgres) |
| `clusters/librepod/infra-apps.yaml` | Ensure `postBuild.substitute` passes `BASE_DOMAIN` |
| User app overlays (8 apps) | Audit that all user-facing config uses `${VARIABLE}` substitution |

### Not in scope (Phase 2+)

| Item | Phase |
|---|---|
| Marketplace installer UI/API | Phase 2 |
| Abstract ingress/storage/TLS support | Phase 2 |
| CLI tool for app management | Phase 2 |
| Automatic BASE_DOMAIN injection into user app templates | Phase 2 |
| Community app submission workflow | Phase 3 |

## 12. Open Decisions

1. **BASE_DOMAIN injection:** User sets `BASE_DOMAIN` in the bootstrap
   Kustomization's `postBuild.substitute`. For user-installed apps, the user
   manually sets it in each app's `release.yaml`. Automatic propagation is a
   Phase 2 concern.

2. **Gogs init job implementation:** Shell script using `curl` against the Gogs
   API. Runs as a Kubernetes Job with an `alpine:3.21` image (installs `curl`,
   `git`, and `kubectl` at startup). Requires a ServiceAccount with RBAC
   permissions to create Secrets in `flux-system` and exec into the postgres pod.

3. **Versioning:** Bootstrap artifact uses repository tags. Per-app artifacts
   use the version from `metadata.yaml`. These are independent.

4. **Catalog delivery:** Static YAML file published to GitHub Pages. Can also
   be published as an OCI artifact if needed later.

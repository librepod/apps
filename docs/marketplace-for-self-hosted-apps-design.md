# Marketplace for Self-Hosted Apps — Design Document

**Version:** 1.0
**Date:** 2026-03-20
**Status:** Draft — For Analysis and Implementation Planning

---

## 1. Overview

### 1.1 Problem Statement

Self-hosted application deployment on Kubernetes requires significant expertise in writing manifests, configuring Kustomize overlays, and managing Flux reconciliation. While a curated marketplace repository of pre-configured apps works well for a single cluster owner, sharing these apps with the broader self-hosted community presents challenges:

- Users need to customize app parameters (domains, credentials, storage) without forking the marketplace repository
- Apps must be distributed in a generic, reusable format
- Installation should be accessible to users without deep Kubernetes/GitOps expertise
- Users should be able to recover their app configurations after a cluster rebuild

### 1.2 Proposed Solution

A lightweight app marketplace system consisting of:

1. **A centralized marketplace repository** where apps are defined using Kustomize and published as OCI artifacts
2. **A marketplace controller** deployed to each user's cluster providing a web UI for browsing, installing, configuring, and removing apps
3. **An optional config export/import mechanism** for preserving app configurations across cluster rebuilds

### 1.3 Design Principles

- **Simplicity first** — no database, no CRDs, no external git repos required
- **Flux-native** — all app deployment uses standard Flux resources; the controller is convenience, not a hard dependency
- **The cluster is the source of truth** — installed app state is derived from labeled Flux resources
- **Non-destructive ejection** — users who outgrow the UI can manage the generated Flux manifests directly

---

## 2. Architecture

### 2.1 High-Level Architecture

```
┌──────────────────────────────────────────────────────┐
│                 MARKETPLACE (maintainer)               │
│                                                       │
│  apps-repo (git)                                      │
│  ├── apps/                                            │
│  │   ├── bitwarden/                                   │
│  │   │   ├── base/              (kustomize manifests) │
│  │   │   ├── kustomization.yaml                       │
│  │   │   └── metadata.yaml      (app definition)      │
│  │   ├── mattermost/                                  │
│  │   └── sonarr/                                      │
│  └── catalog.yaml               (app index)           │
│                                                       │
│  CI Pipeline:                                         │
│    For each app:                                      │
│      flux push artifact oci://registry/apps/<name>    │
│    Push catalog:                                      │
│      oci://registry/marketplace/catalog               │
└───────────────────────┬──────────────────────────────┘
                        │
                        │ OCI pull
                        ▼
┌──────────────────────────────────────────────────────┐
│                    USER CLUSTER                        │
│                                                       │
│  ┌─────────────────────────────────────────────┐      │
│  │        Marketplace Controller                │      │
│  │                                              │      │
│  │  - Fetches catalog from OCI registry         │      │
│  │  - Renders web UI for app management         │      │
│  │  - Creates/deletes Flux resources via k8s API│      │
│  │  - Reads Flux resource status for health     │      │
│  │  - Provides config export/import             │      │
│  └──────────────────┬──────────────────────────┘      │
│                     │                                  │
│                     │ kubectl apply/delete              │
│                     ▼                                  │
│  ┌─────────────────────────────────────────────┐      │
│  │  Flux Resources (per installed app)          │      │
│  │    - Namespace                               │      │
│  │    - Secret (user config + credentials)      │      │
│  │    - OCIRepository (source)                  │      │
│  │    - Kustomization (deployment)              │      │
│  └──────────────────┬──────────────────────────┘      │
│                     │                                  │
│                     │ Flux reconciles                   │
│                     ▼                                  │
│              Running Application                       │
└──────────────────────────────────────────────────────┘
```

### 2.2 Component Responsibilities

| Component | Responsibility | Runs Where |
|---|---|---|
| Apps Repository | Source of truth for app definitions and kustomize bases | GitHub/GitLab (maintainer) |
| CI Pipeline | Builds and publishes OCI artifacts per app + catalog index | GitHub Actions / similar |
| OCI Registry | Hosts app artifacts and catalog | ghcr.io / Docker Hub / self-hosted |
| Marketplace Controller | Web UI + API for app lifecycle management | User's cluster |
| Flux CD | Reconciles OCI artifacts into running workloads | User's cluster |

---

## 3. Marketplace Repository Structure

### 3.1 Repository Layout

```
marketplace-apps/
├── apps/
│   ├── bitwarden/
│   │   ├── base/
│   │   │   ├── deployment.yaml
│   │   │   ├── service.yaml
│   │   │   ├── ingress.yaml
│   │   │   ├── pvc.yaml
│   │   │   └── kustomization.yaml
│   │   └── metadata.yaml
│   ├── mattermost/
│   │   ├── base/
│   │   │   └── ...
│   │   └── metadata.yaml
│   └── sonarr/
│       ├── base/
│       │   └── ...
│       └── metadata.yaml
├── catalog.yaml
└── .github/
    └── workflows/
        └── publish.yaml
```

### 3.2 App Metadata Schema

Each app includes a `metadata.yaml` that the marketplace controller uses to render the install UI, validate user input, and generate Flux resources.

```yaml
apiVersion: marketplace/v1
kind: AppDefinition
metadata:
  name: bitwarden
spec:
  # Display information
  displayName: "Vaultwarden"
  description: "Lightweight Bitwarden-compatible password manager server"
  icon: "https://raw.githubusercontent.com/.../vaultwarden.png"
  category: "Security"
  website: "https://github.com/dani-garcia/vaultwarden"

  # Versioning
  version: "1.30.5"          # Marketplace package version
  appVersion: "1.30.5"       # Upstream application version

  # User-configurable parameters
  params:
    required:
      - name: APP_DOMAIN
        description: "Domain name for the application"
        type: string
        example: "vault.example.com"

    optional:
      - name: STORAGE_CLASS
        description: "Kubernetes storage class for persistent data"
        type: string
        default: ""
      - name: INGRESS_CLASS
        description: "Ingress controller class name"
        type: string
        default: "nginx"
      - name: PV_SIZE
        description: "Persistent volume size"
        type: string
        default: "10Gi"
      - name: REPLICAS
        description: "Number of replicas"
        type: integer
        default: 1

  # Secrets the user must provide or can auto-generate
  secrets:
    - name: ADMIN_TOKEN
      description: "Admin panel access token"
      generate: true
      length: 64
    - name: SMTP_PASSWORD
      description: "SMTP password for outgoing email"
      required: false

  # Infrastructure dependencies
  dependencies:
    required:
      - kind: IngressController
      - kind: StorageClass
    optional:
      - kind: CertManager
        description: "Required for automatic TLS certificates"

  # Resource requirements
  resources:
    minimum:
      cpu: "100m"
      memory: "256Mi"
    recommended:
      cpu: "500m"
      memory: "512Mi"
```

### 3.3 Kustomize Base with Variable Placeholders

App manifests use `${VARIABLE}` placeholders that Flux's `postBuild.substitute` resolves at reconciliation time.

```yaml
# apps/bitwarden/base/ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: bitwarden
  annotations:
    cert-manager.io/cluster-issuer: "${CLUSTER_ISSUER:=letsencrypt-prod}"
spec:
  ingressClassName: "${INGRESS_CLASS:=nginx}"
  rules:
    - host: "${APP_DOMAIN}"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: bitwarden
                port:
                  number: 80
  tls:
    - hosts:
        - "${APP_DOMAIN}"
      secretName: bitwarden-tls
```

```yaml
# apps/bitwarden/base/pvc.yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: bitwarden-data
spec:
  storageClassName: "${STORAGE_CLASS}"
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: "${PV_SIZE:=10Gi}"
```

### 3.4 Catalog Index

```yaml
# catalog.yaml
apiVersion: marketplace/v1
kind: Catalog
metadata:
  generatedAt: "2024-01-15T10:00:00Z"
apps:
  - name: bitwarden
    version: "1.30.5"
    displayName: "Vaultwarden"
    category: "Security"
    icon: "https://..."
    ociRepository: "oci://ghcr.io/marketplace/apps/bitwarden"

  - name: mattermost
    version: "9.2.0"
    displayName: "Mattermost"
    category: "Communication"
    icon: "https://..."
    ociRepository: "oci://ghcr.io/marketplace/apps/mattermost"

  - name: sonarr
    version: "4.0.0"
    displayName: "Sonarr"
    category: "Media"
    icon: "https://..."
    ociRepository: "oci://ghcr.io/marketplace/apps/sonarr"
```

---

## 4. CI Pipeline — OCI Publishing

### 4.1 Publishing Workflow

```yaml
# .github/workflows/publish.yaml
name: Publish Apps

on:
  push:
    branches: [main]
    paths: ["apps/**"]

jobs:
  detect-changes:
    runs-on: ubuntu-latest
    outputs:
      changed-apps: ${{ steps.changes.outputs.apps }}
    steps:
      - uses: actions/checkout@v4
      - id: changes
        # Detect which apps/ subdirectories changed

  publish:
    needs: detect-changes
    runs-on: ubuntu-latest
    strategy:
      matrix:
        app: ${{ fromJSON(needs.detect-changes.outputs.changed-apps) }}
    steps:
      - uses: actions/checkout@v4
      - uses: fluxcd/flux2/action@main
      - run: |
          VERSION=$(yq '.spec.version' apps/${{ matrix.app }}/metadata.yaml)
          flux push artifact \
            oci://ghcr.io/marketplace/apps/${{ matrix.app }}:${VERSION} \
            --path=./apps/${{ matrix.app }} \
            --source="$(git config --get remote.origin.url)" \
            --revision="$(git rev-parse HEAD)"

  publish-catalog:
    needs: publish
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: fluxcd/flux2/action@main
      - run: |
          # Generate catalog.yaml from all metadata.yaml files
          ./scripts/generate-catalog.sh
          flux push artifact \
            oci://ghcr.io/marketplace/catalog:latest \
            --path=./catalog.yaml \
            --source="$(git config --get remote.origin.url)" \
            --revision="$(git rev-parse HEAD)"
```

### 4.2 OCI Artifact Structure

Each published app artifact contains:

```
oci://ghcr.io/marketplace/apps/bitwarden:1.30.5
└── (artifact contents)
    ├── base/
    │   ├── deployment.yaml
    │   ├── service.yaml
    │   ├── ingress.yaml
    │   ├── pvc.yaml
    │   └── kustomization.yaml
    └── metadata.yaml
```

---

## 5. Marketplace Controller

### 5.1 Overview

The marketplace controller is a lightweight application deployed to the user's cluster. It provides a web UI and REST API for managing marketplace apps. It has **no database** — it derives all state from Flux resources in the cluster.

### 5.2 API Specification

```
┌──────────────────────────────────────────────────────────┐
│  Endpoint                  │ Description                  │
├──────────────────────────────────────────────────────────┤
│  GET    /api/catalog       │ List all available apps      │
│  GET    /api/installed     │ List installed apps + status │
│  POST   /api/apps/install  │ Install an app               │
│  PUT    /api/apps/:name    │ Update app configuration     │
│  DELETE /api/apps/:name    │ Uninstall an app             │
│  GET    /api/apps/:name    │ Get app detail + status      │
│  GET    /api/export        │ Export all app configs        │
│  POST   /api/import        │ Import app configs            │
└──────────────────────────────────────────────────────────┘
```

### 5.3 Install Flow

**Request:**
```json
POST /api/apps/install
{
  "app": "bitwarden",
  "version": "1.30.5",
  "namespace": "bitwarden",
  "params": {
    "APP_DOMAIN": "vault.mydomain.com",
    "STORAGE_CLASS": "longhorn",
    "PV_SIZE": "20Gi"
  },
  "secrets": {
    "ADMIN_TOKEN": "a7f3b2c8d1e..."
  }
}
```

**Controller actions:**

1. Validate params against `metadata.yaml` schema (required fields, types)
2. Create Namespace
3. Create Secret containing user-provided secrets
4. Create OCIRepository pointing to the marketplace artifact
5. Create Kustomization with `postBuild.substitute` for params and `substituteFrom` for secrets
6. Return `202 Accepted`

**Generated Flux resources:**

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: bitwarden
  labels:
    marketplace.io/managed: "true"
---
apiVersion: v1
kind: Secret
metadata:
  name: bitwarden-config
  namespace: flux-system
  labels:
    marketplace.io/managed: "true"
    marketplace.io/app: "bitwarden"
type: Opaque
stringData:
  ADMIN_TOKEN: "a7f3b2c8d1e..."
---
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: OCIRepository
metadata:
  name: marketplace-bitwarden
  namespace: flux-system
  labels:
    marketplace.io/managed: "true"
    marketplace.io/app: "bitwarden"
    marketplace.io/version: "1.30.5"
spec:
  interval: 10m
  url: oci://ghcr.io/marketplace/apps/bitwarden
  ref:
    tag: "1.30.5"
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: marketplace-bitwarden
  namespace: flux-system
  labels:
    marketplace.io/managed: "true"
    marketplace.io/app: "bitwarden"
    marketplace.io/version: "1.30.5"
spec:
  interval: 10m
  targetNamespace: bitwarden
  sourceRef:
    kind: OCIRepository
    name: marketplace-bitwarden
  path: ./base
  prune: true
  wait: true
  postBuild:
    substitute:
      APP_DOMAIN: "vault.mydomain.com"
      STORAGE_CLASS: "longhorn"
      PV_SIZE: "20Gi"
    substituteFrom:
      - kind: Secret
        name: bitwarden-config
```

### 5.4 Uninstall Flow

**Request:**
```
DELETE /api/apps/bitwarden
```

**Controller actions:**

1. Delete the Kustomization (Flux prunes all child resources due to `prune: true`)
2. Delete the OCIRepository
3. Delete the Secret
4. Optionally delete the Namespace

### 5.5 Listing Installed Apps

The controller queries the cluster for Flux resources with the `marketplace.io/managed: "true"` label:

```go
func ListInstalled() []InstalledApp {
    ksList := fluxClient.ListKustomizations(
        client.MatchingLabels{"marketplace.io/managed": "true"},
    )

    var apps []InstalledApp
    for _, ks := range ksList {
        app := InstalledApp{
            Name:    ks.Labels["marketplace.io/app"],
            Version: ks.Labels["marketplace.io/version"],
            Status:  deriveStatus(ks.Status.Conditions),
            Params:  ks.Spec.PostBuild.Substitute,
        }
        apps = append(apps, app)
    }
    return apps
}
```

### 5.6 Update Flow

**Request:**
```json
PUT /api/apps/bitwarden
{
  "params": {
    "PV_SIZE": "50Gi"
  }
}
```

**Controller actions:**

1. Patch the Kustomization's `postBuild.substitute` with updated values
2. If secrets changed, update the Secret
3. Flux detects the change and reconciles

---

## 6. Config Export/Import

### 6.1 Purpose

Allows users to preserve app configurations across cluster rebuilds. This is **optional** — users who don't export simply reinstall from scratch.

### 6.2 Export

**Request:**
```
GET /api/export
Headers:
  X-Passphrase: "user-chosen-passphrase"
```

**Controller actions:**

1. List all marketplace-managed Kustomizations
2. For each, read `postBuild.substitute` (params) and referenced Secrets (credentials)
3. Assemble into a single structured document
4. Encrypt with the user-provided passphrase (AES-256-GCM)
5. Return the encrypted file for download

**Export format (pre-encryption):**

```yaml
apiVersion: marketplace/v1
kind: ConfigExport
metadata:
  exportedAt: "2025-01-15T10:30:00Z"
apps:
  - name: bitwarden
    version: "1.30.5"
    namespace: bitwarden
    params:
      APP_DOMAIN: "vault.mydomain.com"
      STORAGE_CLASS: "longhorn"
      PV_SIZE: "20Gi"
    secrets:
      ADMIN_TOKEN: "a7f3b2c8d1e..."

  - name: sonarr
    version: "4.0.0"
    namespace: sonarr
    params:
      APP_DOMAIN: "sonarr.mydomain.com"
    secrets:
      API_KEY: "abc123..."
```

### 6.3 Import

**Request:**
```
POST /api/import
Headers:
  X-Passphrase: "user-chosen-passphrase"
Body: <encrypted export file>
```

**Controller actions:**

1. Decrypt the file with the provided passphrase
2. Validate the export format
3. Return the list of apps found for user confirmation (via a subsequent API call or as part of a multi-step UI flow)
4. For each confirmed app, execute the standard install flow with the preserved params and secrets

### 6.4 Storage

The export file is downloaded by the user. The marketplace controller does not store it. Users can save it wherever they choose — local disk, cloud storage, password manager, etc.

---

## 7. Marketplace Controller Deployment

### 7.1 Prerequisites

- Kubernetes cluster with Flux CD installed
- An ingress controller (for accessing the web UI)

### 7.2 Installation

The marketplace controller itself is deployed via Flux:

```yaml
# User adds this to their Flux bootstrap repo
---
apiVersion: source.toolkit.fluxcd.io/v1beta2
kind: OCIRepository
metadata:
  name: marketplace-controller
  namespace: flux-system
spec:
  interval: 30m
  url: oci://ghcr.io/marketplace/controller
  ref:
    semver: ">=1.0.0"
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: marketplace-controller
  namespace: flux-system
spec:
  interval: 30m
  sourceRef:
    kind: OCIRepository
    name: marketplace-controller
  path: ./
  prune: true
  postBuild:
    substitute:
      MARKETPLACE_DOMAIN: "apps.mydomain.com"
      OCI_REGISTRY: "ghcr.io/marketplace"
```

### 7.3 RBAC

The controller needs a ServiceAccount with permissions to:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: marketplace-controller
rules:
  # Manage Flux resources
  - apiGroups: ["kustomize.toolkit.fluxcd.io"]
    resources: ["kustomizations"]
    verbs: ["get", "list", "create", "update", "patch", "delete"]
  - apiGroups: ["source.toolkit.fluxcd.io"]
    resources: ["ocirepositories"]
    verbs: ["get", "list", "create", "update", "patch", "delete"]
  # Manage namespaces and secrets
  - apiGroups: [""]
    resources: ["namespaces", "secrets"]
    verbs: ["get", "list", "create", "update", "patch", "delete"]
```

---

## 8. User Flows

### 8.1 First-Time Setup

```
1. User has a Kubernetes cluster with Flux installed
2. User installs the marketplace controller (Flux Kustomization)
3. User accesses the web UI at their configured domain
4. UI displays the app catalog fetched from OCI registry
5. User browses and installs desired apps
```

### 8.2 App Installation

```
1. User selects an app from the catalog
2. UI renders an install form based on metadata.yaml
   - Required fields are marked mandatory
   - Optional fields show defaults
   - Secret fields offer auto-generate option
3. User fills in the form and clicks Install
4. Controller validates input and creates Flux resources
5. UI shows installation progress
6. Flux reconciles and deploys the app
7. UI shows the app as Running
```

### 8.3 App Configuration Update

```
1. User navigates to an installed app
2. UI shows current configuration
3. User modifies parameters
4. Controller patches Flux resources
5. Flux reconciles with updated config
```

### 8.4 App Removal

```
1. User clicks Remove on an installed app
2. UI asks for confirmation
3. Controller deletes Flux resources
4. Flux prunes all app resources from the cluster
5. UI removes the app from the installed list
```

### 8.5 Cluster Rebuild

```
1. User exports configs (optional, before rebuild)
2. User provisions new cluster
3. User installs Flux and marketplace controller
4. Option A: User imports config export
   - All apps restored with identical configuration
   - Apps reconnect to surviving persistent volumes
5. Option B: User reinstalls apps manually
   - Fresh configuration for each app
```

---

## 9. Labeling Convention

All resources created by the marketplace controller carry consistent labels for discovery and management.

```yaml
labels:
  marketplace.io/managed: "true"          # Identifies marketplace-managed resources
  marketplace.io/app: "<app-name>"        # App identifier
  marketplace.io/version: "<version>"     # Installed version
```

These labels enable:
- Listing all installed apps without a database
- Associating related resources (Kustomization ↔ OCIRepository ↔ Secret)
- Filtering in `kubectl` for debugging

---

## 10. Upgrade Strategy

### 10.1 App Upgrades

When the marketplace publishes a new version of an app:

1. The catalog index is updated with the new version
2. The controller's catalog syncer detects the update
3. The UI shows an "Update Available" badge
4. User can review the changelog and click Update
5. Controller patches the OCIRepository tag and Kustomization version label
6. Flux pulls the new artifact and reconciles

### 10.2 Version Pinning

Users install a specific version. Updates are **opt-in only** — the OCIRepository references an explicit tag, not a semver range. This prevents unexpected breaking changes.

```yaml
spec:
  ref:
    tag: "1.30.5"    # Pinned, not semver range
```

---

## 11. Security Considerations

| Concern | Approach |
|---|---|
| Secrets at rest | Stored as Kubernetes Secrets, protected by cluster RBAC and etcd encryption |
| Config export encryption | AES-256-GCM with user-provided passphrase |
| Controller access | Protected by ingress authentication (basic auth, OAuth proxy, or similar) |
| RBAC | Controller ServiceAccount scoped to required operations only |
| OCI artifact integrity | Flux verifies artifact digests; optional cosign signature verification |
| Supply chain | Apps are reviewed in the marketplace repo before publishing |

---

## 12. Implementation Phases

### Phase 1 — MVP

| Item | Description |
|---|---|
| App repository structure | Define kustomize bases with variable placeholders for 5–10 apps |
| Metadata schema | Finalize `metadata.yaml` format |
| CI pipeline | Publish OCI artifacts on push to main |
| Catalog index | Auto-generated from metadata files |
| Controller API | Core CRUD endpoints (install, remove, list, status) |
| Web UI | Catalog browser, install form, installed apps dashboard |
| Deployment | Controller packaged as OCI artifact, deployed via Flux |

### Phase 2 — Polish

| Item | Description |
|---|---|
| Config export/import | Encrypted backup and restore of app configurations |
| Update notifications | UI shows available updates with changelogs |
| Dependency checks | Warn if required infrastructure (ingress, storage) is missing |
| Health monitoring | Detailed app health beyond Flux status (pod readiness, endpoint checks) |
| Ingress auth | Built-in authentication for the controller UI |

### Phase 3 — Community

| Item | Description |
|---|---|
| Community app submissions | PR workflow for adding new apps to the marketplace |
| App validation pipeline | Automated testing of submitted app definitions |
| App catalog expansion | Grow to 50+ apps |
| Documentation | User guides, app packaging guide for contributors |

---

## 13. Technology Choices

| Component | Technology | Rationale |
|---|---|---|
| App definitions | Kustomize | Already in use, Flux-native, no templating engine needed |
| Artifact distribution | OCI / Flux OCI support | Standard distribution mechanism, no custom infrastructure |
| Orchestration | Flux CD | Already the deployment engine, mature OCI + Kustomize support |
| Controller backend | Go | Kubernetes-native ecosystem, strong k8s client libraries |
| Controller frontend | Lightweight SPA (React/Svelte/Vue) | Simple catalog + forms UI |
| Config encryption | age or AES-256-GCM | Simple, no external dependencies |
| OCI registry | ghcr.io | Free for public packages, integrated with GitHub CI |

---

## 14. Open Questions

| # | Question | Impact |
|---|---|---|
| 1 | Should the controller support multiple OCI registries (mirrors)? | Distribution reliability |
| 2 | How to handle apps that require shared infrastructure (e.g., a shared PostgreSQL instance)? | App dependency model |
| 3 | Should the controller support rollback to a previous app version? | Upgrade safety |
| 4 | Should the export file support partial import (select specific apps)? | UX flexibility |
| 5 | How to handle PVC lifecycle on app removal — delete or retain? | Data safety |
| 6 | Should there be a CLI alternative to the web UI? | Power user workflow |
| 7 | Authentication model for the web UI — built-in vs. external proxy? | Security posture |

---

## 15. Success Criteria

- A user with a Flux-enabled cluster can install the marketplace controller in under 5 minutes
- A user can browse, install, and access an app within 10 minutes
- A user can export their config, rebuild their cluster, import the config, and have all apps running with identical configuration
- Generated Flux resources are clean and standard — usable without the controller
- Adding a new app to the marketplace requires only a kustomize base and a metadata.yaml

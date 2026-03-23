# Marketplace for Self-Hosted Apps — Design Document

**Version:** 1.1
**Date:** 2026-03-23
**Status:** Draft — Revised Architecture

---

## 1. Overview

### 1.1 Problem Statement

Self-hosted application deployment on Kubernetes requires significant expertise in writing manifests, configuring Kustomize overlays, and managing Flux reconciliation. While a curated marketplace repository of pre-configured apps works well for a single cluster owner, sharing these apps with the broader self-hosted community presents challenges:

- Users need to customize app parameters, domains, credentials, and storage without forking the public marketplace repository
- Apps must be distributed in a generic, reusable format
- Installation should be accessible to users without deep Kubernetes or GitOps expertise
- Users should be able to recover their app configurations after a cluster rebuild
- User-specific secrets must never be committed to the shared public marketplace repository

### 1.2 Proposed Solution

A lightweight marketplace system consisting of:

1. **A public marketplace repository** where apps are packaged, versioned, and published as OCI artifacts
2. **A private per-cluster configuration repository** hosted on the user's local Gogs instance and used as the GitOps source of truth for installed apps
3. **A thin marketplace installer** deployed to the user's cluster that renders install forms, generates secrets when needed, writes standard Flux and Kubernetes manifests into the private Gogs repo, and lets Flux reconcile them

This removes the need for a custom export/import format. Recovery comes from restoring the private Gogs repository and re-bootstrapping Flux.

### 1.3 Design Principles

- **Simplicity first** — no database, no CRDs, no custom state store outside Git
- **Flux-native** — all app deployment uses standard Flux and Kubernetes resources
- **Git is the source of truth** — desired app state lives in the user's private Gogs repository, not only in the live cluster
- **No shared secrets** — the public marketplace repository never contains user-specific secrets
- **Controller stays thin** — it writes commits to Git; Flux remains the deployment engine
- **Non-destructive ejection** — users who outgrow the UI can manage the generated manifests in their private repo directly

---

## 2. Architecture

### 2.1 High-Level Architecture

```
┌────────────────────────────────────────────────────────────┐
│                 MARKETPLACE (maintainer)                  │
│                                                            │
│  public marketplace repo                                   │
│  ├── apps/                                                 │
│  │   ├── bitwarden/                                        │
│  │   │   ├── base/ or chart config                         │
│  │   │   └── metadata.yaml                                 │
│  │   ├── mattermost/                                       │
│  │   └── sonarr/                                           │
│  └── catalog.yaml                                          │
│                                                            │
│  CI pipeline                                               │
│    - publish app OCI artifacts                             │
│    - publish catalog                                       │
└───────────────────────────┬────────────────────────────────┘
                            │
                            │ OCI pull for app packages
                            ▼
┌────────────────────────────────────────────────────────────┐
│                        USER CLUSTER                        │
│                                                            │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Marketplace Installer / UI                          │  │
│  │  - reads public catalog                             │  │
│  │  - renders install and update forms                 │  │
│  │  - generates secrets for new installs               │  │
│  │  - writes standard manifests to private Gogs repo   │  │
│  └───────────────────────────┬──────────────────────────┘  │
│                              │ git push                     │
│                              ▼                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Private Gogs Repo (per cluster)                     │  │
│  │  - Namespace manifests                              │  │
│  │  - Secret manifests                                 │  │
│  │  - Flux sources                                     │  │
│  │  - HelmRelease / Kustomization manifests            │  │
│  └───────────────────────────┬──────────────────────────┘  │
│                              │                              │
│                              │ Flux GitRepository pull      │
│                              ▼                              │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ Flux CD                                              │  │
│  │  - watches private Gogs repo                         │  │
│  │  - fetches public marketplace OCI artifacts          │  │
│  │  - reconciles user apps                              │  │
│  └───────────────────────────┬──────────────────────────┘  │
│                              ▼                              │
│                        Running Apps                         │
└────────────────────────────────────────────────────────────┘
```

### 2.2 Component Responsibilities

| Component | Responsibility | Runs Where |
|---|---|---|
| Public Marketplace Repo | Source of truth for app packages, metadata, and catalog | GitHub/GitLab or similar |
| CI Pipeline | Builds and publishes OCI artifacts and catalog | GitHub Actions or similar |
| OCI Registry | Hosts public app artifacts | ghcr.io, Docker Hub, or self-hosted |
| Private Gogs Repo | Source of truth for installed app manifests and secrets for one cluster | User's cluster or home network |
| Marketplace Installer | Web UI and API that writes commits to the private repo | User's cluster |
| Flux CD | Reconciles manifests from the private repo and public artifacts | User's cluster |
| Gogs | Provides local Git hosting and persistence for user configuration | User's cluster |

---

## 3. Repository Structure

### 3.1 Public Marketplace Repository Layout

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

Each app includes a `metadata.yaml` that the installer uses to render the install UI, validate input, and generate the manifests that will be committed to the private Gogs repo.

```yaml
apiVersion: marketplace/v1
kind: AppDefinition
metadata:
  name: bitwarden
spec:
  displayName: "Vaultwarden"
  description: "Lightweight Bitwarden-compatible password manager server"
  icon: "https://raw.githubusercontent.com/.../vaultwarden.png"
  category: "Security"
  website: "https://github.com/dani-garcia/vaultwarden"

  version: "1.30.5"
  appVersion: "1.30.5"

  source:
    type: oci-kustomize
    url: "oci://ghcr.io/marketplace/apps/bitwarden"
    path: ./base

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
      - name: PV_SIZE
        description: "Persistent volume size"
        type: string
        default: "10Gi"

  secrets:
    - name: ADMIN_TOKEN
      description: "Admin panel access token"
      required: false
      generate:
        type: random
        length: 64
    - name: SMTP_PASSWORD
      description: "SMTP password for outgoing email"
      required: false

  dependencies:
    required:
      - kind: IngressController
      - kind: StorageClass
    optional:
      - kind: CertManager
        description: "Required for automatic TLS certificates"
```

### 3.3 Package Template Rules

Public marketplace packages must be secret-free:

- No real passwords, client secrets, API keys, or tokens in the public repo
- Packages may contain placeholders such as `${APP_DOMAIN}`
- Secret material must be referenced through standard Kubernetes `Secret` refs or Flux substitutions
- App packages should prefer `HelmRelease` when an upstream chart already exists
- App packages should use Kustomize only when Helm is not a good fit

### 3.4 Catalog Index

```yaml
apiVersion: marketplace/v1
kind: Catalog
metadata:
  generatedAt: "2026-03-23T10:00:00Z"
apps:
  - name: bitwarden
    version: "1.30.5"
    displayName: "Vaultwarden"
    category: "Security"
    icon: "https://..."
    sourceType: oci-kustomize
    sourceUrl: "oci://ghcr.io/marketplace/apps/bitwarden"

  - name: mattermost
    version: "9.2.0"
    displayName: "Mattermost"
    category: "Communication"
    icon: "https://..."
    sourceType: helm
    sourceUrl: "oci://ghcr.io/marketplace/charts/mattermost"
```

### 3.5 Private Gogs Repository Layout

The private Gogs repo is generated and versioned. It contains only standard manifests plus a small metadata file describing the repo layout version.

```
cluster-config/
├── repo-metadata.yaml
├── kustomization.yaml
├── namespaces/
│   ├── bitwarden.yaml
│   └── sonarr.yaml
├── apps/
│   ├── bitwarden/
│   │   ├── secret.yaml
│   │   ├── source.yaml
│   │   └── release.yaml
│   └── sonarr/
│       ├── secret.yaml
│       ├── source.yaml
│       └── release.yaml
└── flux-system/
    └── gotk-sync.yaml
```

Example metadata file:

```yaml
apiVersion: marketplace/v1
kind: RepoMetadata
metadata:
  name: cluster-config
spec:
  layoutVersion: 1
  managedBy: marketplace-installer
```

---

## 4. CI Pipeline — Public App Publishing

### 4.1 Publishing Workflow

```yaml
name: Publish Apps

on:
  push:
    branches: [main]
    paths: ["apps/**", "catalog.yaml"]

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
      - run: ./scripts/generate-catalog.sh
      - run: cp catalog.yaml public/catalog.yaml
```

### 4.2 OCI Artifact Structure

Each published app artifact contains only reusable package content:

```
oci://ghcr.io/marketplace/apps/bitwarden:1.30.5
└── artifact contents
    ├── base/
    │   ├── deployment.yaml
    │   ├── service.yaml
    │   ├── ingress.yaml
    │   ├── pvc.yaml
    │   └── kustomization.yaml
    └── metadata.yaml
```

User-specific manifests and secrets are never part of the public artifact.

---

## 5. Marketplace Installer

### 5.1 Overview

The marketplace installer is a lightweight application deployed to the user's cluster. It provides a web UI and a small API for managing apps, but it does not create Flux resources directly through the Kubernetes API during normal installs. Its main job is to write commits to the private Gogs repository.

The installer has no database. Desired state lives in Git.

### 5.2 API Specification

```
┌─────────────────────────────────────────────────────────────┐
│ Endpoint                   │ Description                   │
├─────────────────────────────────────────────────────────────┤
│ GET    /api/catalog        │ List available apps           │
│ GET    /api/installed      │ List installed apps + status  │
│ POST   /api/apps/install   │ Generate manifests and commit │
│ PUT    /api/apps/:name     │ Update repo manifests         │
│ DELETE /api/apps/:name     │ Remove app manifests          │
│ GET    /api/apps/:name     │ Get app config + status       │
└─────────────────────────────────────────────────────────────┘
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
    "SMTP_PASSWORD": "user-provided-if-needed"
  }
}
```

**Installer actions:**

1. Validate params against `metadata.yaml`
2. Generate any secrets marked as auto-generated and merge them with user-provided secrets
3. Render standard Kubernetes and Flux manifests for the app
4. Write those manifests into the private Gogs repo
5. Commit and push to Gogs
6. Return `202 Accepted` with the commit SHA

**Generated manifests in the private repo:**

```yaml
---
apiVersion: v1
kind: Namespace
metadata:
  name: bitwarden
  labels:
    marketplace.io/managed: "true"
    marketplace.io/app: "bitwarden"
---
apiVersion: v1
kind: Secret
metadata:
  name: bitwarden-config
  namespace: bitwarden
  labels:
    marketplace.io/managed: "true"
    marketplace.io/app: "bitwarden"
type: Opaque
stringData:
  ADMIN_TOKEN: "generated-per-cluster"
  SMTP_PASSWORD: "user-provided-if-needed"
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

### 5.4 Update Flow

**Request:**

```json
PUT /api/apps/bitwarden
{
  "params": {
    "PV_SIZE": "50Gi"
  }
}
```

**Installer actions:**

1. Update the app manifests in the private Gogs repo
2. If secrets changed, update the generated `Secret` manifest in the repo
3. Commit and push the changes
4. Flux detects the new revision and reconciles

### 5.5 Uninstall Flow

**Request:**

```
DELETE /api/apps/bitwarden
```

**Installer actions:**

1. Remove the app's manifests from the private Gogs repo
2. Commit and push the removal
3. Flux prunes app resources because the `Kustomization` or `HelmRelease` no longer exists
4. Namespace deletion remains an explicit policy choice per app

### 5.6 Listing Installed Apps

The installer should combine:

- the desired state from the private Gogs repo
- the live status from Flux resources in the cluster

For MVP, status can remain Flux-only:

```go
type InstalledApp struct {
    Name       string
    Version    string
    DesiredRef string
    Status     string
}
```

The installer does not need a richer health model in the first version.

---

## 6. Private Config Repository and Recovery

### 6.1 Purpose

The private Gogs repo replaces the old export/import design.

It provides:

- a Git history of all app installs and updates
- a private place to store cluster-specific manifests and secrets
- a standard GitOps recovery path after cluster rebuild

### 6.2 Recovery Model

Recovery works by restoring Gogs persistence or a backup of the private repo, then re-bootstrapping Flux.

```
1. User rebuilds or reprovisions the cluster
2. User restores Gogs data or recreates the private repo from backup
3. User bootstraps Flux and points it at the private Gogs repo
4. Flux fetches the repo and reconciles all app manifests
5. Apps come back with the same configuration and secrets
```

This is cleaner than a custom encrypted export format because desired state remains in Git at all times.

### 6.3 Backup Expectations

If Gogs is the configuration source of truth, its persistence must be treated as important cluster state.

Recommended policy:

- back up the Gogs repository data directory or its underlying PVC
- document that full machine loss without Gogs backup means loss of app configuration history and secrets
- keep backup and restore instructions part of the LibrePod system app documentation

### 6.4 Repo Layout Evolution

The private repo layout is versioned through `repo-metadata.yaml`.

This allows the marketplace installer to evolve the generated directory structure over time without making every path a permanent public contract. The supported contract is:

- the repo contains standard Flux and Kubernetes manifests
- the repo has a layout version
- the installer can migrate older layouts forward when needed

---

## 7. Deployment Model

### 7.1 Prerequisites

- Kubernetes cluster with Flux CD installed
- Gogs installed as a LibrePod system app
- A private Git repository in Gogs for cluster configuration
- Credentials for Flux to read from the private Gogs repo
- An ingress controller for accessing the installer UI

### 7.2 Bootstrap

The bootstrap repo installs:

- Gogs
- the marketplace installer
- a Flux `GitRepository` that points to the user's private Gogs repo
- a top-level `Kustomization` that reconciles the manifests stored there

Example:

```yaml
---
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

### 7.3 Installer Permissions

The installer no longer needs broad write access to cluster resources for normal app installs. Its main permissions are:

- read app status from Flux resources
- read the public catalog
- read and write the private Gogs repo

This is a smaller and safer scope than direct cluster mutation.

---

## 8. User Flows

### 8.1 First-Time Setup

```
1. User boots a Kubernetes cluster with Flux
2. LibrePod installs Gogs as a system app
3. Flux is configured to watch the user's private Gogs repo
4. User opens the marketplace installer UI
5. UI shows the public marketplace catalog
```

### 8.2 App Installation

```
1. User selects an app from the catalog
2. UI renders an install form based on metadata.yaml
3. User fills in required fields
4. Installer generates any required secrets
5. Installer writes manifests into the private Gogs repo and pushes a commit
6. Flux reconciles the new commit
7. UI shows the app as installed and then ready
```

### 8.3 App Configuration Update

```
1. User navigates to an installed app
2. UI shows current configuration from the private repo and live Flux status
3. User modifies parameters or secrets
4. Installer updates repo manifests and pushes a commit
5. Flux reconciles with the updated configuration
```

### 8.4 App Removal

```
1. User clicks Remove on an installed app
2. UI asks for confirmation
3. Installer removes the app manifests from the private repo
4. Flux prunes the app resources
5. UI removes the app from the installed list
```

### 8.5 Cluster Rebuild

```
1. User restores Gogs persistence or a backup of the private repo
2. User provisions a new cluster
3. User installs Flux, Gogs, and the marketplace installer
4. Flux is pointed at the restored private Gogs repo
5. Flux reconciles the repo and restores the apps
```

---

## 9. Labeling Convention

All generated resources should carry consistent labels for discovery and management.

```yaml
labels:
  marketplace.io/managed: "true"
  marketplace.io/app: "<app-name>"
  marketplace.io/version: "<version>"
```

These labels enable:

- listing installed apps in the UI
- associating related resources such as `Secret`, `OCIRepository`, `Kustomization`, and `HelmRelease`
- debugging with `kubectl`

---

## 10. Upgrade Strategy

### 10.1 App Upgrades

When the marketplace publishes a new version of an app:

1. The catalog index is updated
2. The installer UI shows that a newer version is available
3. User chooses to upgrade
4. Installer updates the app source reference in the private repo
5. Installer commits and pushes the change
6. Flux pulls the new revision and reconciles

### 10.2 Version Pinning

Users install explicit versions. Updates remain opt-in only.

```yaml
spec:
  ref:
    tag: "1.30.5"
```

### 10.3 Repo Migrations

If a new marketplace release requires a private repo layout change:

1. Installer reads `repo-metadata.yaml`
2. Installer migrates the repo to the new layout version
3. Installer commits the migration before or together with app changes

This keeps layout evolution explicit and auditable.

---

## 11. Security Considerations

| Concern | Approach |
|---|---|
| Public repo secrets | Forbidden; the public marketplace repo must contain only reusable app packages |
| Private repo secrets | Stored in the user's private Gogs repo; acceptable for the LibrePod trusted-home threat model |
| Secrets in cluster | Materialized as Kubernetes `Secret` objects from the private repo |
| Installer access | Protected by ingress authentication or existing LibrePod auth patterns |
| Flux access to Gogs | Uses dedicated credentials or deploy keys for the private repo |
| Gogs persistence | Must be backed up because it becomes part of the GitOps control plane |
| OCI artifact integrity | Flux verifies source revisions and can optionally verify signatures |
| Supply chain | Apps are reviewed in the public marketplace repo before publishing |

---

## 12. Implementation Phases

### Phase 1 — MVP

| Item | Description |
|---|---|
| Public app packaging | Define reusable app packages with no secrets in the public repo |
| Metadata schema | Finalize install metadata and secret generation hints |
| CI pipeline | Publish public OCI artifacts and catalog |
| Gogs integration | Bootstrap a private per-cluster config repo |
| Installer API | Install, update, remove, list, and status endpoints |
| Web UI | Catalog browser, install form, installed apps dashboard |
| Flux wiring | Reconcile the private repo and public app artifacts together |

### Phase 2 — Hardening

| Item | Description |
|---|---|
| Secret cleanup | Remove remaining hardcoded secrets from existing system apps |
| Repo migrations | Support layout version upgrades in the private repo |
| Backup guidance | Document Gogs backup and recovery procedures |
| Dependency checks | Warn when required infrastructure is missing |
| Update UX | Show available updates and upgrade notes |

### Phase 3 — Community

| Item | Description |
|---|---|
| Community app submissions | PR workflow for adding new apps |
| App validation pipeline | Automated checks that apps contain no hardcoded secrets |
| App catalog expansion | Grow to 50+ apps |
| Documentation | User guides and app packaging guide |

---

## 13. Technology Choices

| Component | Technology | Rationale |
|---|---|---|
| App definitions | Kustomize and HelmRelease | Use the simplest standard packaging per app |
| Public artifact distribution | OCI and static catalog | Standard delivery with minimal custom infrastructure |
| Private state store | Gogs Git repository | User-owned, persistent, and GitOps-friendly |
| Orchestration | Flux CD | Already the deployment engine |
| Installer backend | Go | Strong Git and Kubernetes client support |
| Installer frontend | Lightweight SPA | Simple forms and status UI |
| Secret generation | Installer-generated random values | Stable per-cluster secrets without storing them in the public repo |

---

## 14. Open Questions

| # | Question | Impact |
|---|---|---|
| 1 | Should the catalog be served as static YAML, JSON, or also published to OCI? | Catalog delivery simplicity |
| 2 | How should Flux authenticate to the private Gogs repo: HTTP token, robot account, or SSH deploy key? | Operational security |
| 3 | Which apps should use HelmRelease versus OCI Kustomize bundles? | Packaging consistency |
| 4 | How should PVC lifecycle be handled on app removal: delete or retain? | Data safety |
| 5 | Should the installer also support a CLI that writes to Gogs? | Power user workflow |
| 6 | How should repo migration failures be rolled back safely? | Upgrade safety |
| 7 | How should Gogs itself be backed up and restored in LibrePod? | Disaster recovery |

---

## 15. Success Criteria

- A user can install the marketplace installer and Gogs-backed config repo in under 10 minutes
- A user can browse, install, and access an app without editing YAML manually
- User-specific secrets are never committed to the public marketplace repository
- A cluster rebuild can be recovered by restoring Gogs and re-bootstrapping Flux
- Generated manifests in the private repo are standard and directly usable without the installer
- Adding a new app to the marketplace requires only a reusable package and metadata, not user-specific configuration

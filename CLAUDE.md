# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**LibrePod Apps** is a Marketplace of pre-configured applications for one-click installation 
on LibrePod Kubernetes clusters. We use GitOps principles with FluxCD for deploying and
managing applications.

## Repository Structure

```
apps/                   # Individual application deployments
├── traefik/            # Traefik ingress controller
├── wg-easy/            # WireGuard VPN
└── [other apps]/       # Additional applications (baikal, litellm, vaultwarden, etc.)
```

## Development Environment

A development Kubernetes cluster is available for testing:

- **Cluster name**: `librepod-dev`
- **Access**: hostname `librepod-dev` (IP may change; the kubeconfig file always has the current address)
- **Kubeconfig**: `./librepod-dev.config` (in repo root, gitignored)

Always use the kubeconfig flag when interacting with the cluster:

```bash
kubectl --kubeconfig ./librepod-dev.config get pods -A
```

## Common Development Commands

### Root-level Commands (run from `/apps`)

```bash
# Build kustomize manifests
kustomize build ./apps/<app-name>/overlays/librepod

# Apply to dev cluster
kustomize build ./apps/<app-name>/overlays/librepod | kubectl --kubeconfig ./librepod-dev.config apply -f -
```

## Architecture Patterns

**Key conventions:**
- Each app creates its own namespace (named after the app)

### 2. FluxCD Integration

FluxCD is the central GitOps operator. Its configs are located under `clusters/` and
`infrastructure/` directories. The FluxCD is being installed by the LibrePod server
deployment step using helm charts flux-operator and flux-instance. The
FluxInstance CRD is pointed to this repository (i.e. `./clusters/librepod`
folder) in order to pull its original state.

## Development Workflow

1. **Create/Edit App**: Modify Kustomization code in `apps/<app-name>/base.yaml` or `overlay/librepod/` files
2. **Test Build**: Run `kustomize build apps/<app-name>/overlay/librepod` to verify manifests
3. **Deploy to Dev**: Apply to `librepod-dev` cluster for testing
4. **Commit**: Generated YAML in `<app-name>/` is committed to Git

For the full FluxCD-based workflow — including how to validate manifests locally,
diff changes against the live cluster, test from a feature branch, and verify
reconciliation — see @docs/FLUX_WORKFLOW.md

## Important Notes

- **Do not parse the entire `./apps/` folder** unless explicitly asked to. Each app is self-contained — only dive into the specific app you're working on.
- **Do not create namespaces manually** - Apps are responsible for creating their own namespaces
- **Testing**: Uses Kustomize build command

### PVC/PV Deletion with NFS Storage

The cluster uses NFS as the default storage class. When a PVC and its PV are deleted, the underlying
NFS folder on the NFS server **is not deleted**. If a new PVC is created with the same name, it will
rebind to the same NFS folder and contain the old data. To truly reset PVC data, you must manually
clean the NFS folder contents (e.g., via a temporary job running as root with `rm -rf /data/*`).

<!-- GSD:project-start source:PROJECT.md -->
## Project

**Cosign Artifact Signing**

Add Cosign-based OCI artifact signing to the LibrePod Marketplace CI/CD pipeline. Every artifact pushed to GHCR (bootstrap + per-app) will be cryptographically signed with a Cosign key pair, and FluxCD will verify signatures before pulling artifacts into the cluster. This establishes a supply-chain trust boundary — unsigned or tampered artifacts are rejected at deploy time.

**Core Value:** All OCI artifacts in the registry are verifiably signed, and FluxCD refuses to deploy anything that isn't signed with the trusted key.

### Constraints

- **Tech stack**: GitHub Actions, Cosign CLI, FluxCD OCIRepository verification
- **Registry**: GHCR (ghcr.io) — must support Cosign signatures (it does natively)
- **Key management**: Private key stored as GitHub Actions secret; public key referenced in FluxCD manifests
- **No workflow disruption**: Existing push flow must continue to work; signing is additive
<!-- GSD:project-end -->

<!-- GSD:stack-start source:codebase/STACK.md -->
## Technology Stack

## Languages & Formats
| Language/Format | Usage | Prevalence |
|-----------------|-------|------------|
| YAML | Kubernetes manifests, Kustomize configs, FluxCD resources | Primary (~95% of files) |
| Shell | `shell.nix` dev environment, justfile recipes | Minimal |
| Nix | `shell.nix` for dev toolchain (fluxcd, just) | Single file |
## Runtime & Platform
- **Kubernetes**: k3s distribution (dev cluster accessible via `librepod-dev`)
- **Container Runtime**: Docker (via k3s)
- **OS**: Linux (k3s nodes)
## Orchestration & GitOps
| Component | Version/Source | Purpose |
|-----------|---------------|---------|
| FluxCD v2 | Installed via flux-operator Helm chart | GitOps reconciliation, source tracking, automated deployments |
| Kustomize | Native k8s tool | Manifest templating, overlays, patches, variable substitution |
| Helm | Via FluxCD HelmRelease CRDs | Chart-based deployments for complex apps |
## Core Infrastructure Components
| Component | Source | Purpose |
|-----------|--------|---------|
| Traefik | OCI chart (`ghcr.io`) | Ingress controller, TLS termination, routing |
| Cert-Manager | OCI chart | Certificate lifecycle management |
| Step Certificates | Helm chart | Private PKI (ACME server) |
| Step Issuer | Helm chart | cert-manager issuer backed by Step CA |
| NFS Provisioner | Kustomize manifest | Dynamic PV provisioning via NFS |
| External Secrets | Helm chart | Sync secrets from external stores into k8s |
| Reflector | OCI chart | Replicate secrets/configmaps across namespaces |
| Flux Operator MCP | OCI chart | MCP server for FluxCD management |
## Application Stack
| App | Deployment Method | Components |
|-----|------------------|------------|
| Casdoor | HelmRelease + OCI | SSO/OIDC identity provider |
| OAuth2 Proxy | HelmRelease | OIDC reverse proxy for authentication |
| Gogs | Kustomize manifests | Self-hosted Git server (with PostgreSQL) |
| Vaultwarden | Kustomize manifests | Password manager (Bitwarden-compatible) |
| Seafile | Kustomize manifests | File sync/share (with MySQL + Redis) |
| Baikal | Kustomize manifests | CalDAV/CardDAV server |
| LiteLLM | Kustomize manifests | LLM proxy (with PostgreSQL) |
| Open WebUI | HelmRelease | LLM chat interface |
| WG-Easy | Kustomize manifests | WireGuard VPN management (with sing-box) |
| Happy Server | Kustomize manifests | Custom server app (with Postgres, Redis, MinIO) |
| Obsidian LiveSync | Kustomize manifests | CouchDB-based Obsidian sync |
| Whoami | Kustomize manifests | Simple test/debug HTTP server |
## Development Tools
| Tool | Purpose |
|------|---------|
| `flux` CLI | Build, diff, reconcile, tree, logs |
| `kubectl` | Direct cluster interaction |
| `kustomize` | Local manifest building |
| `helm` | Chart management |
| `just` | Task runner (via `shell.nix`) |
| `kubeconform` | YAML schema validation |
## Configuration Patterns
- **Base + Overlay**: Each app has `base/` (shared config) and `overlays/librepod/` (environment-specific)
- **Components**: Shared building blocks (e.g., `apps/gogs/components/postgres/`, `apps/seafile/components/mysql/`)
- **Variable Substitution**: FluxCD postBuild substituteFrom for environment-specific values
- **Patches**: Strategic merge patches and JSON 6902 patches in overlays
- **Helm Sources**: Both `HelmRepository` and `OCIRepository` for chart sources
## Cluster Environments
| Environment | Cluster Config | Path |
|-------------|---------------|------|
| Production (`librepod`) | `clusters/librepod/` | `gotk-sync.yaml`, `system-apps.yaml`, `system-configs.yaml` |
| Development (`librepod-dev`) | `clusters/librepod-dev/` | `gotk-sync.yaml`, `system-apps.yaml`, `system-configs.yaml`, `user-apps-source.yaml` |
## Storage
- **Default StorageClass**: NFS-based (`nfs-client`)
- **PVC Pattern**: Each app creates its own PVC in `base/pvc.yaml`
- **NFS behavior**: Deleting PVC/PV does NOT delete underlying NFS data (manual cleanup required)
<!-- GSD:stack-end -->

<!-- GSD:conventions-start source:CONVENTIONS.md -->
## Conventions

## File Structure
## Naming Patterns
- Lowercase kebab case: `wg-easy`, `vaultwarden`, `open-webui`
- Match official app names when possible
- Lowercase kebab case: `kustomization.yaml`, `namespace.yaml`, `deployment.yaml`
- Descriptive names: `init-container.env`, `step-ca-init-script`
- Component files include component name: `bootstrap-cluster-issuer/job.env`
- Kubernetes resources use lowercase kebab case: `oauth2-proxy`, `wg-easy`
- Namespaces match app names: `oauth2-proxy`, `vaultwarden`
## YAML Conventions
- Consistent 2-space indentation
- Always include `apiVersion` and `kind`
- Metadata includes `name` field matching the resource
- Container names match deployment name when single container
- Consistent labeling pattern:
- Uses `includeSelectors: true` and `includeTemplates: true` for kustomizations
## Probe Configuration
## Environment Configuration
- `.env` files for environment variables
- ConfigMap generation for sensitive data
- Secret generation for passwords and API keys
- Uppercase snake case: `CA_URL`, `CA_NAME`, `CA_DNS_1`
- Consistent across components: `BASE_DOMAIN`, `LITELLM_MASTER_KEY`
## Security Context
## Storage Patterns
- Consistent naming: `[app-name]-data`, `[app-name]-config`
- StorageClass: `nfs-client`
- Access mode: `ReadWriteOnce`
## Network Configuration
- Named ports: `http`, `wireguard`, etc.
- Protocol specification: `TCP`, `UDP`
- Container port matches service port
- Uses Traefik IngressRoute resources
- Consistent domain pattern: `https://[app-name].${BASE_DOMAIN:=libre.pod}`
## Helm Integration
## Environment Variable Substitution
- Environment variables with defaults: `CA_PASSWORD=${CA_PASSWORD:-$(generate_password)}`
- Idempotent operations with marker files
## Error Handling
- Multiple probe types: liveness, readiness, startup
- Increasing failure thresholds for startup probes
- Pre-flight checks for required variables
- Idempotent operations (check before execution)
- Proper exit codes
<!-- GSD:conventions-end -->

<!-- GSD:architecture-start source:ARCHITECTURE.md -->
## Architecture

## Pattern Overview
- Two-tier deployment system: system apps (core infrastructure) and user apps (optional services)
- OCI artifact registry as distribution mechanism for both apps and bootstrap
- Kustomize overlays for environment-specific configurations
- Private Git repository (Gogs) for user app state management
- Dependency-driven orchestration with explicit dependency declarations
## Layers
- Purpose: Source control and CI/CD pipeline
- Location: `./apps/`, `./infrastructure/`, `./clusters/`
- Contains: Kustomize manifests, OCI source definitions, CI workflows
- Depends on: Git version control, GitHub Actions
- Used by: CI pipeline, developers, FluxCD
- Purpose: App artifact distribution and storage
- Location: External (`ghcr.io/librepod/marketplace/`)
- Contains: Pre-built app artifacts, bootstrap orchestrator
- Depends on: Container registry infrastructure
- Used by: FluxCD source controller
- Purpose: Runtime environment for deployed applications
- Location: Kubernetes cluster via FluxCD
- Contains: FluxCD operators, running applications, user repositories
- Depends on: Kubernetes cluster, FluxCD installation
- Used by: End users, system administrators
- Purpose: User application state management
- Location: Gogs Git repository within cluster
- Contains: User app manifests, custom configurations
- Depends on: Gogs service, FluxCD git repository controller
- Used by: FluxCD, user deployments
## Data Flow
- All state stored in Kubernetes resources and Git repositories
- No external databases or configuration stores
- Secrets managed via Kubernetes Secrets with templating
- Persistent volumes backed by NFS provisioner
## Key Abstractions
- Purpose: Standardized app packaging and metadata
- Examples: `[apps/vaultwarden/metadata.yaml]`, `[apps/traefik/metadata.yaml]`
- Pattern: `metadata.yaml` with version, dependencies, templates
- Purpose: Environment-specific configuration customization
- Examples: `[apps/vaultwarden/overlays/librepod/kustomization.yaml]`
- Pattern: `overlays/<env>/` directory with kustomization.yaml
- Purpose: External artifact reference and retrieval
- Examples: `[infrastructure/system-apps/traefik.yaml]`, `[apps/traefik/base/ocirepository.yaml]`
- Pattern: Flux OCIRepository resource with interval and ref
- Purpose: Reusable application sub-components
- Examples: `[apps/step-certificates/components/root-ca-server/kustomization.yaml]`
- Pattern: Kustomize Component with generator configuration
## Entry Points
- Location: `[clusters/librepod/system-apps.yaml]`
- Triggers: Manual user application of bootstrap manifests
- Responsibilities: Deploys entire system infrastructure including Flux, Gogs, and core apps
- Location: `[.github/workflows/publish-apps.yaml]`, `[.github/workflows/publish-bootstrap.yaml]`
- Triggers: Git pushes to master branch
- Responsibilities: Builds and publishes OCI artifacts for apps/bootstrap
- Location: `[infrastructure/user-apps-source/user-apps.yaml]`
- Triggers: Changes to private Gogs repository
- Responsibilities: Watches user-apps repo and deploys user applications
- Location: `[apps/<app>/metadata.yaml]`
- Triggers: Template copying by users
- Responsibilities: Defines app structure, dependencies, and installation templates
## Error Handling
- FluxCD `retryInterval` and `timeout` configuration on Kustomizations
- `dependsOn` declarations for ordering
- `wait: true` for resource readiness before proceeding
- Health probes on application deployments
## Cross-Cutting Concerns
<!-- GSD:architecture-end -->

<!-- GSD:skills-start source:skills/ -->
## Project Skills

| Skill | Description | Path |
|-------|-------------|------|
| casdoor-export | Use when exporting Casdoor SSO configuration from the librepod Kubernetes cluster. Triggers on "casdoor export", "export casdoor config", "backup casdoor", "save casdoor init data". | `.claude/skills/casdoor-export/SKILL.md` |
<!-- GSD:skills-end -->

<!-- GSD:workflow-start source:GSD defaults -->
## GSD Workflow Enforcement

Before using Edit, Write, or other file-changing tools, start work through a GSD command so planning artifacts and execution context stay in sync.

Use these entry points:
- `/gsd-quick` for small fixes, doc updates, and ad-hoc tasks
- `/gsd-debug` for investigation and bug fixing
- `/gsd-execute-phase` for planned phase work

Do not make direct repo edits outside a GSD workflow unless the user explicitly asks to bypass it.
<!-- GSD:workflow-end -->

<!-- GSD:profile-start -->
## Developer Profile

> Profile not yet configured. Run `/gsd-profile-user` to generate your developer profile.
> This section is managed by `generate-claude-profile` -- do not edit manually.
<!-- GSD:profile-end -->

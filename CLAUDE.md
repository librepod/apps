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
└── [other apps]/       # Additional applications (baikal, defguard, vaultwarden, etc.)
```

## Development Environment

A development Kubernetes cluster is available for testing:

- **Cluster name**: `librepod-dev`
- **IP address**: `192.168.2.180`
- **Kubeconfig**: `./192.168.2.180.config` (in repo root, gitignored)

Always use the kubeconfig flag when interacting with the cluster:

```bash
kubectl --kubeconfig ./192.168.2.180.config get pods -A
```

## Common Development Commands

### Root-level Commands (run from `/apps`)

```bash
# Build kustomize manifests
kustomize build ./apps/<app-name>/overlays/librepod

# Apply to dev cluster
kustomize build ./apps/<app-name>/overlays/librepod | kubectl --kubeconfig ./192.168.2.180.config apply -f -
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

- **Do not create namespaces manually** - Apps are responsible for creating their own namespaces
- **Testing**: Uses Kustomize build command

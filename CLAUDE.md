# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

**LibrePod** is a personal Kubernetes application management platform built with Kustomize. It uses GitOps principles with ArgoCD for deploying and managing applications on a home lab Kubernetes cluster.

## Repository Structure

```
apps/                    # Individual application deployments
├── argocd/             # ArgoCD operator configuration (defines projects and app sync)
├── traefik-cdk/        # Traefik ingress controller
├── wg-easy/            # WireGuard VPN
└── [other apps]/       # Additional applications (baikal, defguard, vaultwarden, etc.)
```

## Development Environment

A development Kubernetes cluster is available for testing:

- **Cluster name**: `librepod-dev`
- **IP address**: `192.168.2.180`
- **Kubeconfig**: `./192.168.2.180.config` (in repo root)

Always use the kubeconfig flag when interacting with the cluster:

```bash
kubectl --kubeconfig ./192.168.2.180.config get pods -A
```

## Common Development Commands

### Root-level Commands (run from `/apps`)

```bash
# Build kustomize manifests
kustomize build --enable-helm ./apps/<app-name>/overlays/librepod

# Apply to dev cluster
kustomize build --enable-helm ./apps/<app-name>/overlays/librepod | kubectl --kubeconfig ./192.168.2.180.config apply -f -
```

## Architecture Patterns

**Key conventions:**
- Each app creates its own namespace (named after the app)

### 2. ArgoCD Integration

ArgoCD is the central GitOps operator. The `apps/argocd/` directory defines:
- **Projects**: Two ArgoCD projects organize applications:
  - `librepod-system`: System-critical applications (Traefik, ArgoCD itself, etc.)
  - `librepod-apps`: User-deployed applications
- **Applications**: Each app is registered as an ArgoCD Application resource that syncs its overlay folder

## StepIssuer Bootstrap

The `step-certificates` app includes an automatic StepIssuer bootstrap component:

- **bootstrap-step-resources**: Runs as an ArgoCD PostSync hook (wave: 5) after step-certificates initializes
- Extracts the root CA certificate from PVC and creates a StepIssuer resource
- Requires cert-manager and step-issuer CRD to be installed first
- The StepIssuer is created in the `step-ca` namespace as `step-issuer`

### Required Dependencies

1. **cert-manager**: Must be installed for Certificate/StepIssuer resources
3. **step-certificates**: Must be bootstrapped first (via bootstrap-pvc component)
2. **step-issuer**: The external cert-manager issuer controller ([GitHub](https://github.com/smallstep/step-issuer))

## Development Workflow

1. **Create/Edit App**: Modify Kustomization code in `apps/<app-name>/base.yaml` or `overlay/librepod/` files
2. **Test Build**: Run `kustomize build --enable-helm apps/<app-name>/overlay/librepod` to verify manifests
3. **Deploy to Dev**: Apply to `librepod-dev` cluster for testing
4. **Commit**: Generated YAML in `<app-name>/` is committed to Git

## Important Notes

- **Do not create namespaces manually** - Apps are responsible for creating their own namespaces
- **Testing**: Uses Kustomize build command

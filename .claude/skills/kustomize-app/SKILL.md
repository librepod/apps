---
name: kustomize-app
description: This skill helps you create new Kubernetes applications using Kustomize in the current repository. It follows the established patterns for structure, labeling, configuration management, and deployment.
allowed-tools: Read, Grep, Glob, Edit, Write, Bash
---

# Kustomize App Skill

## Overview

Kustomize is a Kubernetes-native configuration management tool that uses declarative customization to manage environment-specific configurations without templates. It follows the principles of declarative application management and integrates directly with kubectl. You are an expert at creating Kubernetes applications using Kustomize for the LibrePod repository. Follow these patterns and conventions:

### Core Concepts

- **Base**: A directory containing a `kustomization.yaml` and a set of resources (typically common/shared configurations)
- **Overlay**: A directory with a `kustomization.yaml` that refers to a base and applies customizations (environment-specific configs)
- **Patch**: A partial resource definition that modifies existing resources
- **Component**: Reusable customization bundles that can be included in multiple kustomizations
- **Generator**: Creates ConfigMaps and Secrets from files, literals, or env files
- **Transformer**: Modifies resources (labels, annotations, namespaces, replicas, etc.)

### Key Principles

1. **Bases are reusable**: Define common configuration once, customize per environment
2. **Overlays are composable**: Stack multiple customizations
3. **Resources are not modified**: Original base files remain unchanged
4. **No templating**: Uses declarative merging instead of variable substitution
5. **kubectl integration**: `kubectl apply -k <directory>` natively supports Kustomize

## When to use this skill

Use this skill when you want to:
- Create a new application from scratch using Kustomize
- Migrate an existing Helm chart to Kustomize
- Ensure consistency with the existing LibrePod app patterns

## Using the Kustomize App skill

Invoke this skill by asking Claude to:
- "Create a new app using kustomize"
- "Help me set up a kustomize app for [app-name]"
- "Migrate this helm chart to kustomize"

## Repository Context

**LibrePod** is a personal Kubernetes application management platform using:
- Kustomize for resource management
- GitOps with ArgoCD
- Traefik for ingress (IngressRoute CRD)
- Each app creates its own namespace (named after the app)

## Directory Structure

Every app follows this structure:

```
apps/<app-name>/
├── base/
│   ├── kustomization.yaml    # Base configuration with common labels
│   ├── namespace.yaml         # Namespace declaration
│   ├── deployment.yaml        # Application deployment (no image tag)
│   ├── service.yaml           # ClusterIP service
│   ├── pvc.yaml              # Persistent storage (if needed)
│   └── <app>.env             # Environment variables for ConfigMap
└── overlays/
    └── librepod/
        ├── kustomization.yaml  # Environment-specific config + image tag
        └── ingressroute.yaml   # Traefik ingress configuration
```

## Base Layer Files (`apps/<app-name>/base/`)

### 1. `kustomization.yaml` - Base Configuration

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

namespace: <app-name>

labels:
- includeSelectors: true
  includeTemplates: true
  pairs:
    app.kubernetes.io/name: <app-name>

configMapGenerator:
- name: <app-name>
  envs:
  - <app-name>.env

resources:
- namespace.yaml
- pvc.yaml          # Only if app needs persistent storage
- service.yaml
- deployment.yaml
```

**Key points:**
- Use `labels` section to apply common labels across all resources making sure
  that specified here labels are not explicitly defined in the resources (i.e. Deployments) 
- Use `configMapGenerator` for environment variables (generates hash-suffixed ConfigMap)

### 2. `namespace.yaml` - Namespace Declaration

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: <app-name>
```

### 3. `deployment.yaml` - Application Deployment

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: <app-name>
spec:
  replicas: 1
  strategy:
    type: Recreate
  template:
    spec:
      containers:
        - name: <app-name>
          image: <image-name>  # NO TAG - tag specified in overlay
          imagePullPolicy: IfNotPresent
          envFrom:
            - configMapRef:
                name: <app-name>  # References generated ConfigMap
          # Add ports, probes, volumeMounts, etc.
```

**Important:**
- **Do NOT specify image tag** in the deployment - use only the image name (e.g., `nginx` not `nginx:1.25`)
- Use `envFrom` with `configMapRef` for environment variables
- Include appropriate health probes (liveness, readiness, startup)

### 4. `service.yaml` - ClusterIP Service

```yaml
apiVersion: v1
kind: Service
metadata:
  name: <app-name>
spec:
  type: ClusterIP
  ports:
    - port: 80
      targetPort: http
      protocol: TCP
      name: http
```

### 5. `pvc.yaml` - Persistent Storage (if needed)

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: <app-name>-data
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: nfs-client  # Use appropriate storage class
```

### 6. `<app-name>.env` - Environment Variables

```
ENV_VAR_1=value1
ENV_VAR_2=value2
```

## Overlay Layer Files (`apps/<app-name>/overlays/librepod/`)

### 1. `kustomization.yaml` - Environment Configuration

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
- ../../base
- ingressroute.yaml

images:
- name: <image-name-from-deployment>
  newTag: <version-tag>  # e.g., "1.32.1-alpine" or "latest"
```

**Key points:**
- References base resources
- Adds environment-specific resources (ingressroute)
- Specifies image tag via `images` transformer

### 2. `ingressroute.yaml` - Traefik Ingress

```yaml
apiVersion: traefik.io/v1alpha1
kind: IngressRoute
metadata:
  name: <app-name>
spec:
  entryPoints:
  - web
  - websecure
  routes:
  - kind: Rule
    match: Host(`<app-name>.libre.pod`)
    priority: 1
    services:
    - name: <app-name>
      port: 80
  tls:
    secretName: tls-<app-name>
```

## Common Patterns

### Strategic Merge Patch (Default)

Strategic merge is the default patch strategy. It uses Kubernetes-aware merging logic.

#### Strategic Merge Characteristics

- Merges maps/objects by key
- Replaces arrays by default (unless special directives)
- Uses `$patch: delete` and `$patch: replace` directives
- More intuitive for Kubernetes resources

#### Strategic Merge Use Cases

- Simple field updates (replicas, image, env vars)
- Adding or replacing containers
- Updating resource limits
- Most common use case

### JSON Patch (RFC 6902)

JSON Patch provides precise array manipulation and field operations.

#### JSON Patch Characteristics

- Operations: add, remove, replace, move, copy, test
- Uses JSON Pointer paths (e.g., `/spec/template/spec/containers/0/image`)
- Precise array element targeting
- More verbose but more precise

#### JSON Patch Use Cases

- Precise array element manipulation
- Conditional patches (test operation)
- Complex nested updates
- When strategic merge is too coarse

### Labels
All resources automatically get `app.kubernetes.io/name: <app-name>` via the base kustomization.yaml.
Do not explicitly specify common labels in resources - use kustomization.yaml
for common labels.

### Image Tag Management
- Base deployment: `image: nginx` (no tag)
- Overlay specifies: `newTag: 1.25-alpine`
- Final output: `image: nginx:1.25-alpine`

### Configuration Updates
When you change `.env` file contents, the ConfigMap hash changes (e.g., `myapp-abc123` → `myapp-def456`), triggering a rolling deployment update.

## Helm Integration

```yaml
# Use kustomize to customize Helm output
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

helmCharts:
  - name: postgresql
    repo: https://charts.bitnami.com/bitnami
    version: 12.1.2
    releaseName: myapp-db
    namespace: database
    valuesInline:
      auth:
        username: myapp
        database: myapp_prod

patches:
  - path: patch-postgresql.yaml
    target:
      kind: StatefulSet
      name: myapp-db-postgresql
```

## Testing

Always test your Kustomize build:

```bash
kustomize build ./apps/<app-name>/overlays/librepod
# or use kubectl (includes additional validation)
kubectl kustomize build ./apps/<app-name>/overlays/librepod
```

OR if using helm chart with kustomiz:

```bash
kustomize build --enable-helm ./apps/<app-name>/overlays/librepod
```

## Best Practices

### Directory Organization

1. **Keep bases generic**: Avoid environment-specific values in base
2. **One concern per patch**: Create separate patch files for different modifications
3. **Use descriptive names**: `patch-replicas.yaml`, `patch-monitoring.yaml`, not `patch1.yaml`
4. **Group related resources**: Keep services, deployments, and configs together
5. **Use components for features**: Extract optional features (monitoring, ingress) as components

### Patch Hygiene

1. **Minimize patch size**: Only include fields being changed
2. **Document complex patches**: Add comments explaining why patch is needed
3. **Prefer strategic merge**: Use JSON patch only when necessary
4. **Validate patches**: Run `kustomize build` to verify output
5. **Test combinations**: Ensure patches compose correctly

### Resource Management

1. **Use generators for dynamic data**: ConfigMaps and Secrets should use generators
2. **Enable name suffixes**: Add content hash to ConfigMap/Secret names for immutability
3. **Reference by resource**: Use `nameReference` for automatic name updates
4. **Common labels**: Apply consistent labels across all resources
5. **Namespace management**: Set namespace in kustomization, not individual resources

## Your Task

When creating a new Kustomize app:

1. **Ask for details**: Get the app name, image, port, storage needs, environment variables
2. **Create base files**: namespace, deployment (no tag), service, pvc (if needed), .env file
3. **Create base kustomization.yaml**: Add labels and configMapGenerator
  - **Use generators** for ConfigMaps and Secrets with content hashing
  - **Use transformers** for cross-cutting modifications
  - **Prefer strategic merge** for simplicity, JSON patch for precision
4. **Create overlay files**: kustomization.yaml with image tag, ingressroute.yaml
5. **Create components** for optional, reusable features
6. **Test the build**: Run kustomize build to verify
7. **Provide insights**: Explain the patterns used and benefits

Follow the exact patterns shown above. Maintain consistency with existing apps in the repository.

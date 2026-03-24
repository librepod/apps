# Portable Marketplace Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make this repository publishable as OCI artifacts so any user with a clean k3s cluster + FluxCD can bootstrap the full LibrePod marketplace.

**Architecture:** A bootstrap OCI artifact deploys all infrastructure (Traefik, cert-manager, Gogs, etc.) and initializes a private Gogs repo for user state. Per-app OCI artifacts are published separately. Users install apps by committing template manifests to the Gogs repo. CI pipelines on GitHub Actions handle all publishing.

**Tech Stack:** Kustomize, FluxCD, OCI artifacts (via `flux push artifact`), Gogs API, GitHub Actions, shell scripts

**Spec:** `docs/superpowers/specs/2026-03-24-portable-marketplace-design.md`

---

## File Structure

### New files

| File | Responsibility |
|---|---|
| `apps/gogs/components/repo-init/kustomization.yaml` | Kustomize Component: wires Job, RBAC, ConfigMap |
| `apps/gogs/components/repo-init/serviceaccount.yaml` | ServiceAccount for the init Job |
| `apps/gogs/components/repo-init/role.yaml` | Role granting Secret write in `flux-system` |
| `apps/gogs/components/repo-init/rolebinding.yaml` | Binds ServiceAccount to Role |
| `apps/gogs/components/repo-init/job.yaml` | Kubernetes Job that bootstraps the Gogs repo |
| `apps/gogs/components/repo-init/job.env` | Environment variables for the init script |
| `apps/gogs/components/repo-init/init.sh` | Shell script: creates Gogs repo, pushes seed, creates auth Secret |
| `infrastructure/cluster-config/kustomization.yaml` | Kustomize resources list for cluster-config |
| `infrastructure/cluster-config/gitrepository.yaml` | Flux GitRepository pointing at private Gogs repo |
| `infrastructure/cluster-config/kustomization-cr.yaml` | Flux Kustomization CR for private Gogs repo |
| `infrastructure/apps/cluster-config-source.yaml` | Flux Kustomization with `dependsOn: gogs` |
| `apps/vaultwarden/metadata.yaml` | App metadata + install templates |
| `apps/open-webui/metadata.yaml` | App metadata + install templates |
| `apps/seafile/metadata.yaml` | App metadata + install templates |
| `apps/obsidian-livesync/metadata.yaml` | App metadata + install templates |
| `apps/litellm/metadata.yaml` | App metadata + install templates |
| `apps/baikal/metadata.yaml` | App metadata + install templates |
| `apps/happy-server/metadata.yaml` | App metadata + install templates |
| `scripts/generate-catalog.sh` | Reads metadata.yaml files, produces catalog.yaml |
| `catalog.yaml` | Generated catalog index |
| `.github/workflows/publish-bootstrap.yaml` | CI: publish bootstrap OCI artifact |
| `.github/workflows/publish-apps.yaml` | CI: publish per-app OCI artifacts |
| `.github/workflows/publish-catalog.yaml` | CI: generate and publish catalog |
| `docs/user-guide.md` | Bootstrap and app install instructions |

### Files to modify

| File | Change |
|---|---|
| `apps/gogs/base/kustomization.yaml` | Add `../components/repo-init` to `components:` list |
| `infrastructure/apps/kustomization.yaml` | Add `cluster-config-source.yaml`, `external-secrets.yaml`; remove `open-webui.yaml` |

---

## Chunk 1: Gogs Repo Init Component

This is the most critical and complex piece — the Kubernetes Job that bootstraps the private Gogs repository after Gogs starts.

### Task 1: Create the repo-init component RBAC

The init Job needs to create a Secret in the `flux-system` namespace (for Flux to authenticate to Gogs). Since the Job runs in the `gogs` namespace, it needs cross-namespace RBAC. Follow the exact pattern from `apps/step-certificates/components/bootstrap-step-resources/`.

**Files:**
- Create: `apps/gogs/components/repo-init/serviceaccount.yaml`
- Create: `apps/gogs/components/repo-init/role.yaml`
- Create: `apps/gogs/components/repo-init/rolebinding.yaml`

- [ ] **Step 1: Create ServiceAccount**

```yaml
# apps/gogs/components/repo-init/serviceaccount.yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: gogs-repo-init
```

- [ ] **Step 2: Create Role in flux-system namespace**

This is a `ClusterRole` (not a namespaced Role) because the Job runs in `gogs` but needs to create Secrets in `flux-system`. A namespaced Role in the component would be scoped to `gogs` namespace. We use ClusterRole + ClusterRoleBinding to grant cross-namespace access.

```yaml
# apps/gogs/components/repo-init/role.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: gogs-repo-init
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "create", "update", "patch"]
  - apiGroups: [""]
    resources: ["pods"]
    verbs: ["get", "list"]
  - apiGroups: [""]
    resources: ["pods/exec"]
    verbs: ["create"]
```

- [ ] **Step 3: Create ClusterRoleBinding**

```yaml
# apps/gogs/components/repo-init/rolebinding.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: gogs-repo-init
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: gogs-repo-init
subjects:
  - kind: ServiceAccount
    name: gogs-repo-init
    namespace: gogs
```

- [ ] **Step 4: Commit RBAC files**

```bash
git add apps/gogs/components/repo-init/serviceaccount.yaml \
        apps/gogs/components/repo-init/role.yaml \
        apps/gogs/components/repo-init/rolebinding.yaml
git commit -m "feat(gogs): add RBAC for repo-init component"
```

### Task 2: Create the repo-init Job and init script

The Job waits for Gogs to be ready, then creates the admin user via postgres
(since `INSTALL_LOCK=true` prevents the install wizard and the Gogs admin API
requires an existing admin), creates the `cluster-config` repo via the Gogs API,
pushes a seed commit, and creates a Flux auth Secret. It must be idempotent.

**Image choice:** `alpine:3.21` — lightweight base image. The init script
installs `curl` and `git` via `apk add` at startup. `kubectl` is downloaded
from the Kubernetes release URL and cached in `/tmp`. This avoids depending on
a third-party image (like `bitnami/kubectl`) whose contents are not guaranteed.
The image only needs internet access during the first run; subsequent idempotent
runs skip most work.

**Admin user creation:** Gogs' `POST /api/v1/admin/users` endpoint requires
admin auth, creating a chicken-and-egg problem on a fresh install. The init Job
solves this by registering a user via the Gogs signup form endpoint (`POST
/user/sign_up`), then promoting that user to admin via `kubectl exec` into the
postgres pod to run a SQL UPDATE.

**Important dependency:** The Gogs `app.ini` must NOT set `DISABLE_REGISTRATION
= true`, otherwise the signup-based admin bootstrap will fail. The current
app.ini does not set this, but a comment should be added to app.ini documenting
this requirement.

**Files:**
- Create: `apps/gogs/components/repo-init/job.env`
- Create: `apps/gogs/components/repo-init/init.sh`
- Create: `apps/gogs/components/repo-init/job.yaml`

- [ ] **Step 1: Create environment config**

```env
# apps/gogs/components/repo-init/job.env
GOGS_URL=http://gogs.gogs.svc.cluster.local:80
GOGS_ADMIN_USER=librepod
GOGS_ADMIN_PASSWORD=librepod
GOGS_ADMIN_EMAIL=admin@librepod.local
REPO_NAME=cluster-config
FLUX_SECRET_NAME=cluster-config-auth
FLUX_SECRET_NAMESPACE=flux-system
POSTGRES_HOST=gogs-postgres.gogs.svc.cluster.local
POSTGRES_PORT=5432
POSTGRES_DB=gogs
POSTGRES_USER=gogs
POSTGRES_PASSWORD=gogs
```

- [ ] **Step 2: Create init script**

```bash
#!/bin/bash
# apps/gogs/components/repo-init/init.sh
#
# Bootstraps the cluster-config repo in Gogs for Flux GitOps.
# Idempotent — safe to run multiple times.
#
# Runs in alpine:3.21. Installs curl, git at startup.
# The initContainer already waited for Gogs to be ready, so we skip that here.

set -e

echo "=== Gogs Repo Init ==="

# --- Install dependencies ---
echo "Installing dependencies..."
apk add --no-cache curl git > /dev/null 2>&1

# --- Download kubectl ---
echo "Downloading kubectl..."
KUBECTL_VERSION=$(curl -sL https://dl.k8s.io/release/stable.txt)
curl -sL -o /tmp/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
chmod +x /tmp/kubectl
export PATH="/tmp:$PATH"

# --- Create admin user via postgres (if not exists) ---
# Gogs INSTALL_LOCK=true prevents the install wizard, and the admin API
# requires an existing admin. We create the user directly in postgres.
# Gogs stores passwords as pbkdf2 hashes. We use kubectl exec to run psql
# in the postgres pod.
echo "Ensuring admin user '${GOGS_ADMIN_USER}' exists..."

# Check if user exists via Gogs API (unauthenticated endpoint)
USER_EXISTS=$(curl -s -o /dev/null -w "%{http_code}" \
  "${GOGS_URL}/api/v1/users/${GOGS_ADMIN_USER}")

if [ "$USER_EXISTS" = "200" ]; then
  echo "Admin user already exists."
else
  echo "Creating admin user via Gogs signup..."
  # Use Gogs' user registration endpoint (works without admin auth)
  # The first user in a fresh Gogs instance needs to be promoted to admin
  # after creation.
  SIGNUP_RESULT=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${GOGS_URL}/user/sign_up" \
    -d "user_name=${GOGS_ADMIN_USER}" \
    -d "email=${GOGS_ADMIN_EMAIL}" \
    -d "password=${GOGS_ADMIN_PASSWORD}" \
    -d "retype=${GOGS_ADMIN_PASSWORD}")

  if [ "$SIGNUP_RESULT" = "302" ] || [ "$SIGNUP_RESULT" = "200" ]; then
    echo "User registered via signup form."
  else
    echo "Signup returned HTTP ${SIGNUP_RESULT}, trying API registration..."
    curl -s -X POST "${GOGS_URL}/api/v1/users" \
      -H "Content-Type: application/json" \
      -d "{
        \"username\": \"${GOGS_ADMIN_USER}\",
        \"email\": \"${GOGS_ADMIN_EMAIL}\",
        \"password\": \"${GOGS_ADMIN_PASSWORD}\",
        \"send_notify\": false
      }" || true
  fi

  # Promote to admin via postgres
  echo "Promoting user to admin via database..."
  POSTGRES_POD=$(kubectl get pods -n gogs -l app.kubernetes.io/name=gogs \
    -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
    | grep postgres | head -1)

  if [ -n "$POSTGRES_POD" ]; then
    kubectl exec -n gogs "$POSTGRES_POD" -- \
      psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" -c \
      "UPDATE \"user\" SET is_admin = true WHERE lower_name = lower('${GOGS_ADMIN_USER}');"
    echo "User promoted to admin."
  else
    echo "WARNING: Could not find postgres pod to promote user to admin."
    echo "The user may need to be manually promoted."
  fi
fi

AUTH_HEADER="Authorization: Basic $(echo -n "${GOGS_ADMIN_USER}:${GOGS_ADMIN_PASSWORD}" | base64)"

# --- Create repo (if not exists) ---
echo "Checking if repo '${REPO_NAME}' exists..."
REPO_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  -H "${AUTH_HEADER}" \
  "${GOGS_URL}/api/v1/repos/${GOGS_ADMIN_USER}/${REPO_NAME}")

if [ "$REPO_STATUS" = "200" ]; then
  echo "Repo already exists, skipping creation."
else
  echo "Creating repo '${REPO_NAME}'..."
  curl -s -X POST "${GOGS_URL}/api/v1/user/repos" \
    -H "Content-Type: application/json" \
    -H "${AUTH_HEADER}" \
    -d "{
      \"name\": \"${REPO_NAME}\",
      \"description\": \"Cluster configuration managed by LibrePod Marketplace\",
      \"private\": true,
      \"auto_init\": true
    }"
  echo "Repo created."

  # Push seed commit with repo-metadata.yaml and kustomization.yaml
  echo "Pushing seed commit..."
  WORKDIR=$(mktemp -d)
  cd "$WORKDIR"
  git init -b main
  git config user.email "marketplace@librepod.local"
  git config user.name "LibrePod Marketplace"

  cat > repo-metadata.yaml <<SEED
apiVersion: marketplace/v1
kind: RepoMetadata
metadata:
  name: cluster-config
spec:
  layoutVersion: 1
  managedBy: marketplace-installer
SEED

  cat > kustomization.yaml <<SEED
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources: []
SEED

  git add .
  git commit -m "Initial cluster-config seed"
  GOGS_HOST=$(echo "${GOGS_URL}" | sed 's|http://||')
  git push -f "http://${GOGS_ADMIN_USER}:${GOGS_ADMIN_PASSWORD}@${GOGS_HOST}/${GOGS_ADMIN_USER}/${REPO_NAME}.git" HEAD:main
  cd /
  rm -rf "$WORKDIR"
  echo "Seed commit pushed."
fi

# --- Create/update Flux auth Secret ---
# Always run this — handles cluster rebuild where Gogs PVC was restored
# but the Secret in flux-system was lost.
echo "Creating Flux auth Secret '${FLUX_SECRET_NAME}' in '${FLUX_SECRET_NAMESPACE}'..."

kubectl apply -f - <<SECRETEOF
apiVersion: v1
kind: Secret
metadata:
  name: ${FLUX_SECRET_NAME}
  namespace: ${FLUX_SECRET_NAMESPACE}
type: Opaque
stringData:
  username: "${GOGS_ADMIN_USER}"
  password: "${GOGS_ADMIN_PASSWORD}"
SECRETEOF

echo "=== Gogs Repo Init Complete ==="
echo "  Repo: ${GOGS_URL}/${GOGS_ADMIN_USER}/${REPO_NAME}"
echo "  Flux Secret: ${FLUX_SECRET_NAMESPACE}/${FLUX_SECRET_NAME}"
```

- [ ] **Step 3: Create Job manifest**

Follow the pattern from `step-certificates/components/bootstrap-step-resources/job.yaml`.
Uses `alpine:3.21` as a lightweight base. The init script installs `curl` and
`git` via `apk add`, and downloads `kubectl` from the Kubernetes release URL.
The initContainer uses `alpine:3.21` with `curl` installed to wait for Gogs.
No `ttlSecondsAfterFinished` — the Job stays completed so FluxCD doesn't
recreate it on every reconciliation cycle.

```yaml
# apps/gogs/components/repo-init/job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: job-gogs-repo-init
spec:
  backoffLimit: 5
  parallelism: 1
  completions: 1
  template:
    metadata:
      name: job-gogs-repo-init
    spec:
      restartPolicy: Never
      serviceAccountName: gogs-repo-init
      securityContext:
        fsGroup: 1000
        runAsGroup: 1000
        runAsNonRoot: true
        runAsUser: 1000
      initContainers:
        - name: wait-for-gogs
          image: alpine:3.21
          command:
            - sh
            - -c
            - |
              apk add --no-cache curl > /dev/null 2>&1
              echo "Waiting for Gogs at ${GOGS_URL}..."
              for i in $(seq 1 60); do
                if curl -sf -o /dev/null "${GOGS_URL}/"; then
                  echo "Gogs is ready."
                  exit 0
                fi
                echo "Waiting... ($i/60)"
                sleep 5
              done
              echo "Timeout waiting for Gogs"
              exit 1
          envFrom:
            - configMapRef:
                name: cm-gogs-repo-init
          securityContext:
            runAsNonRoot: true
            runAsUser: 1000
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
      containers:
        - name: repo-init
          image: alpine:3.21
          command: ["/bin/sh", "/scripts/gogs-repo-init.sh"]
          envFrom:
            - configMapRef:
                name: cm-gogs-repo-init
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
            runAsNonRoot: true
            runAsUser: 1000
          volumeMounts:
            - mountPath: /scripts
              name: init-script
              readOnly: true
            - mountPath: /tmp
              name: tmp
      volumes:
        - name: init-script
          configMap:
            name: cm-gogs-repo-init-script
            items:
              - key: gogs-repo-init.sh
                path: gogs-repo-init.sh
        - name: tmp
          emptyDir: {}
```

- [ ] **Step 4: Commit Job and init script**

```bash
git add apps/gogs/components/repo-init/job.env \
        apps/gogs/components/repo-init/init.sh \
        apps/gogs/components/repo-init/job.yaml
git commit -m "feat(gogs): add repo-init Job and init script"
```

### Task 3: Create the repo-init Component kustomization and wire it up

**Files:**
- Create: `apps/gogs/components/repo-init/kustomization.yaml`
- Modify: `apps/gogs/base/kustomization.yaml` (line 24: add to `components:` list)

- [ ] **Step 1: Create Component kustomization**

Follow the pattern from `step-certificates/components/bootstrap-step-resources/kustomization.yaml`:

```yaml
# apps/gogs/components/repo-init/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1alpha1
kind: Component

namespace: gogs

resources:
  - serviceaccount.yaml
  - role.yaml
  - rolebinding.yaml
  - job.yaml

generatorOptions:
  disableNameSuffixHash: true

configMapGenerator:
  - envs:
      - job.env
    name: cm-gogs-repo-init
  - files:
      - gogs-repo-init.sh=init.sh
    name: cm-gogs-repo-init-script
    options:
      annotations:
        kustomize.toolkit.fluxcd.io/substitute: disabled
```

- [ ] **Step 2: Add repo-init to Gogs base kustomization**

In `apps/gogs/base/kustomization.yaml`, add `../components/repo-init` to the existing `components:` list (line 24):

```yaml
# Before:
components:
- ../components/postgres

# After:
components:
- ../components/postgres
- ../components/repo-init
```

- [ ] **Step 3: Validate the kustomize build**

```bash
kustomize build apps/gogs/overlays/librepod
```

Expected: YAML output containing the Job, ServiceAccount, ClusterRole, ClusterRoleBinding, and ConfigMaps alongside the existing Gogs deployment, service, and postgres resources. No errors.

**Important:** Verify that Kustomize does NOT apply `namespace: gogs` to the ClusterRole and ClusterRoleBinding in the output. Kustomize should skip cluster-scoped resources when applying namespace transformations. If it does incorrectly set the namespace, the ClusterRole/ClusterRoleBinding files need a `metadata.namespace` override or the component's `namespace:` field needs to be removed (and namespace set per-resource instead).

- [ ] **Step 4: Commit**

```bash
git add apps/gogs/components/repo-init/kustomization.yaml \
        apps/gogs/base/kustomization.yaml
git commit -m "feat(gogs): wire repo-init component into gogs base"
```

---

## Chunk 2: Cluster Config Source (Flux wiring for private Gogs repo)

### Task 4: Create the cluster-config infrastructure manifests

These are the Flux resources that watch the private Gogs repo once the init Job has created it.

**Files:**
- Create: `infrastructure/cluster-config/kustomization.yaml`
- Create: `infrastructure/cluster-config/gitrepository.yaml`
- Create: `infrastructure/cluster-config/kustomization-cr.yaml`
- Create: `infrastructure/apps/cluster-config-source.yaml`

- [ ] **Step 1: Create the kustomize resource list**

```yaml
# infrastructure/cluster-config/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - gitrepository.yaml
  - kustomization-cr.yaml
```

- [ ] **Step 2: Create the GitRepository**

```yaml
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
```

- [ ] **Step 3: Create the Kustomization CR**

```yaml
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

- [ ] **Step 4: Create the Flux Kustomization that deploys cluster-config (with dependsOn)**

```yaml
# infrastructure/apps/cluster-config-source.yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: cluster-config-source
  namespace: flux-system
spec:
  dependsOn:
    - name: gogs
  interval: 1h
  retryInterval: 2m
  timeout: 5m
  sourceRef:
    kind: GitRepository
    name: librepod-apps
  path: ./infrastructure/cluster-config
  prune: true
  wait: true
```

- [ ] **Step 5: Commit**

```bash
git add infrastructure/cluster-config/kustomization.yaml \
        infrastructure/cluster-config/gitrepository.yaml \
        infrastructure/cluster-config/kustomization-cr.yaml \
        infrastructure/apps/cluster-config-source.yaml
git commit -m "feat: add cluster-config Flux source (watches private Gogs repo)"
```

### Task 5: Update infrastructure/apps/kustomization.yaml

Add the new resource, add external-secrets, remove open-webui.

**Files:**
- Modify: `infrastructure/apps/kustomization.yaml`

- [ ] **Step 1: Edit kustomization.yaml**

Current content:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - casdoor.yaml
  - cert-manager.yaml
  - flux-operator-mcp.yaml
  - gogs.yaml
  - nfs-provisioner.yaml
  - oauth2-proxy.yaml
  - reflector.yaml
  - step-certificates.yaml
  - step-issuer.yaml
  - traefik.yaml
  - wg-easy.yaml
  - whoami.yaml

  # USERS APPS FOR TESTING
  - open-webui.yaml
```

Replace with:
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - casdoor.yaml
  - cert-manager.yaml
  - cluster-config-source.yaml
  - external-secrets.yaml
  - flux-operator-mcp.yaml
  - gogs.yaml
  - nfs-provisioner.yaml
  - oauth2-proxy.yaml
  - reflector.yaml
  - step-certificates.yaml
  - step-issuer.yaml
  - traefik.yaml
  - wg-easy.yaml
  - whoami.yaml
```

Note: `open-webui.yaml` is removed (it becomes a user-installable app). `cluster-config-source.yaml` and `external-secrets.yaml` are added. Resources are sorted alphabetically.

- [ ] **Step 2: Validate the build**

```bash
nix-shell shell.nix --run "flux build kustomization infra-apps \
  --kubeconfig ./192.168.2.180.config \
  --path ./infrastructure/apps \
  --kustomization-file ./clusters/librepod-dev/infra-apps.yaml \
  --local-sources GitRepository/flux-system/librepod-apps=./"
```

Expected: Rendered YAML containing all infrastructure resources including the new cluster-config-source Kustomization. No errors.

- [ ] **Step 3: Commit**

```bash
git add infrastructure/apps/kustomization.yaml
git commit -m "feat: add cluster-config-source and external-secrets to infra; remove open-webui"
```

---

## Chunk 3: App Metadata Files

### Task 6: Create metadata.yaml for vaultwarden

This is the template that other metadata files will follow. Get this one right first.

**Files:**
- Create: `apps/vaultwarden/metadata.yaml`

- [ ] **Step 1: Check vaultwarden's current structure for version and config details**

Read these files to determine the correct values:
- `apps/vaultwarden/base/kustomization.yaml`
- `apps/vaultwarden/overlays/librepod/kustomization.yaml`
- `apps/vaultwarden/base/vaultwarden.env` (for params/secrets)

- [ ] **Step 2: Create metadata.yaml**

```yaml
# apps/vaultwarden/metadata.yaml
apiVersion: marketplace/v1
kind: AppDefinition
metadata:
  name: vaultwarden
spec:
  displayName: "Vaultwarden"
  description: "Lightweight Bitwarden-compatible password manager server"
  icon: "https://raw.githubusercontent.com/dani-garcia/vaultwarden/main/resources/vaultwarden-icon.svg"
  category: "Security"
  website: "https://github.com/dani-garcia/vaultwarden"

  version: "1.35.2"
  appVersion: "1.35.2-alpine"

  source:
    type: oci-kustomize
    url: "oci://ghcr.io/librepod/marketplace/apps/vaultwarden"
    path: ./overlays/librepod

  params:
    required:
      - name: BASE_DOMAIN
        description: "Base domain (app will be at vault.BASE_DOMAIN)"
        type: string
        example: "example.com"

  secrets:
    - name: ADMIN_TOKEN
      description: "Admin panel access token (leave empty to disable admin panel)"
      required: false
      generate:
        type: random
        length: 64

  dependencies:
    required:
      - kind: IngressController
        description: "Traefik (provided by bootstrap)"
      - kind: StorageClass
        description: "nfs-client (provided by bootstrap)"

  templates:
    source: |
      apiVersion: source.toolkit.fluxcd.io/v1beta2
      kind: OCIRepository
      metadata:
        name: marketplace-vaultwarden
        namespace: flux-system
        labels:
          marketplace.io/managed: "true"
          marketplace.io/app: "vaultwarden"
          marketplace.io/version: "1.35.2"
      spec:
        interval: 10m
        url: oci://ghcr.io/librepod/marketplace/apps/vaultwarden
        ref:
          tag: "1.35.2"
    release: |
      apiVersion: kustomize.toolkit.fluxcd.io/v1
      kind: Kustomization
      metadata:
        name: marketplace-vaultwarden
        namespace: flux-system
        labels:
          marketplace.io/managed: "true"
          marketplace.io/app: "vaultwarden"
          marketplace.io/version: "1.35.2"
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
            BASE_DOMAIN: "${BASE_DOMAIN}"
          substituteFrom:
            - kind: Secret
              name: vaultwarden-config
    secret: |
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
        ADMIN_TOKEN: "${ADMIN_TOKEN}"
    kustomization: |
      apiVersion: kustomize.config.k8s.io/v1beta1
      kind: Kustomization
      resources:
        - source.yaml
        - release.yaml
        - secret.yaml
```

- [ ] **Step 3: Commit**

```bash
git add apps/vaultwarden/metadata.yaml
git commit -m "feat(vaultwarden): add marketplace metadata and install templates"
```

### Task 7: Create metadata.yaml for remaining 7 user apps

Create `metadata.yaml` for each app, following the vaultwarden pattern. For each app, check the overlay kustomization for the image tag (version), and the base for env files (params/secrets).

**Files:**
- Create: `apps/open-webui/metadata.yaml`
- Create: `apps/seafile/metadata.yaml`
- Create: `apps/obsidian-livesync/metadata.yaml`
- Create: `apps/litellm/metadata.yaml`
- Create: `apps/baikal/metadata.yaml`
- Create: `apps/happy-server/metadata.yaml`
- Create: `apps/defguard/metadata.yaml`

- [ ] **Step 1: Read each app's overlay kustomization and base env files**

For each app, check:
- `apps/<app>/overlays/librepod/kustomization.yaml` — for image tag / version
- `apps/<app>/base/*.env` — for configurable params
- `apps/<app>/overlays/librepod/ingressroute.yaml` — for domain pattern

- [ ] **Step 2: Create metadata.yaml for each app**

Each metadata.yaml must include:
- `spec.version` and `spec.appVersion` matching the image tag in the overlay
- `spec.params.required` with at least `BASE_DOMAIN`
- `spec.templates` with the four template manifests (source, release, secret, kustomization)
- `spec.templates.secret` with `namespace: flux-system` (not the app namespace)
- Appropriate `spec.category`, `spec.description`, `spec.icon`, `spec.website`

Note for `defguard`: The current `apps/defguard/` directory contains a Node.js project, not Kubernetes manifests. If it has no `base/` or `overlays/librepod/` structure, skip it and note that it needs to be created as a proper Kustomize app first.

- [ ] **Step 3: Audit user app overlays for ${VARIABLE} substitution**

For each user app, check that domain references use `${BASE_DOMAIN}` substitution:

```bash
# Find any hardcoded domain references in user app overlays
grep -r "libre\.pod\|librepod\.dev" \
  apps/vaultwarden/ apps/open-webui/ apps/seafile/ \
  apps/obsidian-livesync/ apps/litellm/ apps/baikal/ \
  apps/happy-server/ 2>/dev/null || echo "No hardcoded domains found"
```

Expected: No matches, or only matches in env files that are already using
`${BASE_DOMAIN}` syntax. If hardcoded domains are found, convert them to
`${BASE_DOMAIN}` substitution patterns.

- [ ] **Step 4: Validate that each app's OCI artifact path would be correct**

For each app, verify `spec.source.url` matches the pattern `oci://ghcr.io/librepod/marketplace/apps/<app-name>`.

- [ ] **Step 5: Commit all metadata files**

```bash
git add apps/*/metadata.yaml
git commit -m "feat: add marketplace metadata for all user-installable apps"
```

---

## Chunk 4: Catalog Generation

### Task 8: Create the catalog generator script

**Files:**
- Create: `scripts/generate-catalog.sh`

- [ ] **Step 1: Create the script**

The script scans all `apps/*/metadata.yaml` files, filters to user-installable apps (those NOT in `infrastructure/apps/kustomization.yaml`), and produces `catalog.yaml`.

```bash
#!/bin/bash
# scripts/generate-catalog.sh
#
# Generates catalog.yaml from app metadata files.
# Excludes system apps (those listed in infrastructure/apps/kustomization.yaml).

set -e

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CATALOG_FILE="${REPO_ROOT}/catalog.yaml"
INFRA_KUSTOMIZATION="${REPO_ROOT}/infrastructure/apps/kustomization.yaml"

# Extract system app names from infrastructure kustomization
# Each line like "  - traefik.yaml" -> "traefik"
SYSTEM_APPS=$(grep '^\s*-.*\.yaml' "$INFRA_KUSTOMIZATION" \
  | sed 's/.*- //' | sed 's/\.yaml//' | sort)

echo "System apps (excluded from catalog):"
echo "$SYSTEM_APPS"
echo

# Start catalog
cat > "$CATALOG_FILE" <<'HEADER'
apiVersion: marketplace/v1
kind: Catalog
metadata:
  generatedAt: "TIMESTAMP"
apps:
HEADER

# Replace timestamp
sed -i "s/TIMESTAMP/$(date -u +%Y-%m-%dT%H:%M:%SZ)/" "$CATALOG_FILE"

# Find all metadata.yaml files
for metadata_file in "$REPO_ROOT"/apps/*/metadata.yaml; do
  app_dir=$(dirname "$metadata_file")
  app_name=$(basename "$app_dir")

  # Skip system apps
  if echo "$SYSTEM_APPS" | grep -qx "$app_name"; then
    echo "Skipping system app: $app_name"
    continue
  fi

  # Skip if no overlays/librepod exists (not a proper app)
  if [ ! -d "$app_dir/overlays/librepod" ]; then
    echo "Skipping $app_name (no overlays/librepod)"
    continue
  fi

  echo "Adding: $app_name"

  # Extract fields using grep/sed (no yq dependency)
  NAME=$(grep 'name:' "$metadata_file" | head -1 | sed 's/.*name: *//')
  VERSION=$(grep 'version:' "$metadata_file" | head -1 | sed 's/.*version: *//' | tr -d '"')
  DISPLAY_NAME=$(grep 'displayName:' "$metadata_file" | sed 's/.*displayName: *//' | tr -d '"')
  CATEGORY=$(grep 'category:' "$metadata_file" | sed 's/.*category: *//' | tr -d '"')
  ICON=$(grep 'icon:' "$metadata_file" | sed 's/.*icon: *//' | tr -d '"')
  DESCRIPTION=$(grep 'description:' "$metadata_file" | head -1 | sed 's/.*description: *//' | tr -d '"')
  SOURCE_TYPE=$(grep 'type:' "$metadata_file" | head -1 | sed 's/.*type: *//' | tr -d '"')
  SOURCE_URL=$(grep 'url:' "$metadata_file" | head -1 | sed 's/.*url: *//' | tr -d '"')

  cat >> "$CATALOG_FILE" <<ENTRY
  - name: ${NAME}
    version: "${VERSION}"
    displayName: "${DISPLAY_NAME}"
    description: "${DESCRIPTION}"
    category: "${CATEGORY}"
    icon: "${ICON}"
    sourceType: ${SOURCE_TYPE}
    sourceUrl: "${SOURCE_URL}"
ENTRY
done

echo
echo "Catalog written to: $CATALOG_FILE"
```

- [ ] **Step 2: Make it executable**

```bash
chmod +x scripts/generate-catalog.sh
```

- [ ] **Step 3: Run and verify output**

```bash
./scripts/generate-catalog.sh
cat catalog.yaml
```

Expected: Valid YAML with entries only for user-installable apps (vaultwarden, open-webui, seafile, etc.). No system apps (traefik, gogs, etc.).

- [ ] **Step 4: Commit**

```bash
git add scripts/generate-catalog.sh catalog.yaml
git commit -m "feat: add catalog generator script and initial catalog"
```

---

## Chunk 5: CI Pipelines

### Task 9: Create the bootstrap artifact publishing workflow

**Files:**
- Create: `.github/workflows/publish-bootstrap.yaml`

- [ ] **Step 1: Create the workflow**

```yaml
# .github/workflows/publish-bootstrap.yaml
name: Publish Bootstrap Artifact

on:
  push:
    branches: [master]
    paths:
      - 'clusters/**'
      - 'infrastructure/**'
      - 'apps/traefik/**'
      - 'apps/cert-manager/**'
      - 'apps/step-certificates/**'
      - 'apps/step-issuer/**'
      - 'apps/nfs-provisioner/**'
      - 'apps/gogs/**'
      - 'apps/casdoor/**'
      - 'apps/oauth2-proxy/**'
      - 'apps/reflector/**'
      - 'apps/flux-operator-mcp/**'
      - 'apps/external-secrets/**'
      - 'apps/wg-easy/**'
      - 'apps/whoami/**'

jobs:
  publish:
    runs-on: ubuntu-latest
    permissions:
      packages: write
      contents: read
    steps:
      - uses: actions/checkout@v4

      - uses: fluxcd/flux2/action@main

      - name: Login to GHCR
        run: |
          echo "${{ secrets.GITHUB_TOKEN }}" | docker login ghcr.io -u ${{ github.actor }} --password-stdin

      - name: Determine version
        id: version
        run: |
          # Use git tag if available, otherwise short SHA
          TAG=$(git describe --tags --exact-match 2>/dev/null || echo "")
          if [ -n "$TAG" ]; then
            echo "version=$TAG" >> "$GITHUB_OUTPUT"
          else
            echo "version=0.0.0-$(git rev-parse --short HEAD)" >> "$GITHUB_OUTPUT"
          fi

      - name: Build bootstrap artifact directory
        run: |
          mkdir -p /tmp/bootstrap
          # Copy infrastructure and cluster configs
          cp -r clusters /tmp/bootstrap/
          cp -r infrastructure /tmp/bootstrap/
          # Copy only system app directories
          mkdir -p /tmp/bootstrap/apps
          SYSTEM_APPS=$(grep '^\s*-.*\.yaml' infrastructure/apps/kustomization.yaml \
            | sed 's/.*- //' | sed 's/\.yaml//')
          for app in $SYSTEM_APPS; do
            if [ -d "apps/$app" ]; then
              cp -r "apps/$app" "/tmp/bootstrap/apps/"
            fi
          done

      - name: Push bootstrap artifact
        run: |
          flux push artifact \
            oci://ghcr.io/${{ github.repository_owner }}/marketplace/bootstrap:${{ steps.version.outputs.version }} \
            --path=/tmp/bootstrap \
            --source="$(git config --get remote.origin.url)" \
            --revision="$(git rev-parse HEAD)"

          flux push artifact \
            oci://ghcr.io/${{ github.repository_owner }}/marketplace/bootstrap:latest \
            --path=/tmp/bootstrap \
            --source="$(git config --get remote.origin.url)" \
            --revision="$(git rev-parse HEAD)"
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/publish-bootstrap.yaml
git commit -m "ci: add bootstrap OCI artifact publishing workflow"
```

### Task 10: Create the per-app artifact publishing workflow

**Files:**
- Create: `.github/workflows/publish-apps.yaml`

- [ ] **Step 1: Create the workflow**

```yaml
# .github/workflows/publish-apps.yaml
name: Publish App Artifacts

on:
  push:
    branches: [master]
    paths:
      - 'apps/*/metadata.yaml'
      - 'apps/*/base/**'
      - 'apps/*/overlays/**'
      - 'apps/*/components/**'

jobs:
  detect-changes:
    runs-on: ubuntu-latest
    outputs:
      apps: ${{ steps.changes.outputs.apps }}
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 2

      - id: changes
        run: |
          # Get changed app directories
          CHANGED=$(git diff --name-only HEAD~1 HEAD -- 'apps/' \
            | cut -d'/' -f2 | sort -u)

          # Filter to user-installable apps only (those with metadata.yaml)
          SYSTEM_APPS=$(grep '^\s*-.*\.yaml' infrastructure/apps/kustomization.yaml \
            | sed 's/.*- //' | sed 's/\.yaml//')

          APPS="[]"
          for app in $CHANGED; do
            # Skip system apps
            if echo "$SYSTEM_APPS" | grep -qx "$app"; then
              continue
            fi
            # Must have metadata.yaml
            if [ ! -f "apps/$app/metadata.yaml" ]; then
              continue
            fi
            APPS=$(echo "$APPS" | jq --arg a "$app" '. + [$a]')
          done

          echo "apps=$APPS" >> "$GITHUB_OUTPUT"
          echo "Changed user apps: $APPS"

  publish:
    needs: detect-changes
    if: needs.detect-changes.outputs.apps != '[]'
    runs-on: ubuntu-latest
    permissions:
      packages: write
      contents: read
    strategy:
      matrix:
        app: ${{ fromJSON(needs.detect-changes.outputs.apps) }}
    steps:
      - uses: actions/checkout@v4

      - uses: fluxcd/flux2/action@main

      - name: Login to GHCR
        run: |
          echo "${{ secrets.GITHUB_TOKEN }}" | docker login ghcr.io -u ${{ github.actor }} --password-stdin

      - name: Get app version
        id: version
        run: |
          VERSION=$(grep 'version:' apps/${{ matrix.app }}/metadata.yaml \
            | head -1 | sed 's/.*version: *//' | tr -d '"')
          echo "version=$VERSION" >> "$GITHUB_OUTPUT"

      - name: Push app artifact
        run: |
          flux push artifact \
            oci://ghcr.io/${{ github.repository_owner }}/marketplace/apps/${{ matrix.app }}:${{ steps.version.outputs.version }} \
            --path=./apps/${{ matrix.app }} \
            --source="$(git config --get remote.origin.url)" \
            --revision="$(git rev-parse HEAD)"

          flux push artifact \
            oci://ghcr.io/${{ github.repository_owner }}/marketplace/apps/${{ matrix.app }}:latest \
            --path=./apps/${{ matrix.app }} \
            --source="$(git config --get remote.origin.url)" \
            --revision="$(git rev-parse HEAD)"
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/publish-apps.yaml
git commit -m "ci: add per-app OCI artifact publishing workflow"
```

### Task 11: Create the catalog publishing workflow

**Files:**
- Create: `.github/workflows/publish-catalog.yaml`

- [ ] **Step 1: Create the workflow**

```yaml
# .github/workflows/publish-catalog.yaml
name: Publish Catalog

on:
  workflow_run:
    workflows: ["Publish App Artifacts"]
    types: [completed]
  push:
    branches: [master]
    paths:
      - 'apps/*/metadata.yaml'
      - 'scripts/generate-catalog.sh'

jobs:
  publish:
    runs-on: ubuntu-latest
    if: github.event_name == 'push' || github.event.workflow_run.conclusion == 'success'
    permissions:
      packages: write
      contents: write
    steps:
      - uses: actions/checkout@v4

      - name: Generate catalog
        run: ./scripts/generate-catalog.sh

      - name: Commit catalog if changed
        run: |
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          if git diff --quiet catalog.yaml; then
            echo "No catalog changes"
          else
            git add catalog.yaml
            git commit -m "chore: regenerate catalog.yaml"
            git push
          fi

      - uses: fluxcd/flux2/action@main

      - name: Login to GHCR
        run: |
          echo "${{ secrets.GITHUB_TOKEN }}" | docker login ghcr.io -u ${{ github.actor }} --password-stdin

      - name: Push catalog artifact
        run: |
          DATE=$(date -u +%Y%m%d)
          flux push artifact \
            oci://ghcr.io/${{ github.repository_owner }}/marketplace/catalog:${DATE} \
            --path=./catalog.yaml \
            --source="$(git config --get remote.origin.url)" \
            --revision="$(git rev-parse HEAD)"

          flux push artifact \
            oci://ghcr.io/${{ github.repository_owner }}/marketplace/catalog:latest \
            --path=./catalog.yaml \
            --source="$(git config --get remote.origin.url)" \
            --revision="$(git rev-parse HEAD)"
```

- [ ] **Step 2: Commit**

```bash
git add .github/workflows/publish-catalog.yaml
git commit -m "ci: add catalog publishing workflow"
```

---

## Chunk 6: User Documentation

### Task 12: Create the user guide

**Files:**
- Create: `docs/user-guide.md`

- [ ] **Step 1: Create the guide**

The user guide should cover:

1. **Prerequisites**: Clean k3s cluster, FluxCD installed
2. **Bootstrap**: The exact YAML manifest to apply (from spec Section 4.1), with `BASE_DOMAIN` as the only required parameter
3. **Verify bootstrap**: Commands to check kustomization status, wait for Gogs to be ready
4. **Access Gogs**: How to find and log into the Gogs UI
5. **Install an app**: Step-by-step guide to copy template manifests from the catalog, fill in values, commit to Gogs
6. **Update an app**: How to change version or config
7. **Remove an app**: How to delete app manifests
8. **Recovery**: How to rebuild after cluster loss

Each section should include exact commands with expected output.

- [ ] **Step 2: Commit**

```bash
git add docs/user-guide.md
git commit -m "docs: add user guide for marketplace bootstrap and app installation"
```

---

## Chunk 7: Validation and Testing

### Task 13: End-to-end validation on dev cluster

Test the full bootstrap flow on the existing librepod-dev cluster.

- [ ] **Step 1: Validate all kustomize builds**

Run `kustomize build` for each modified/new path:

```bash
# Gogs with repo-init component
kustomize build apps/gogs/overlays/librepod

# Full infrastructure apps
nix-shell shell.nix --run "flux build kustomization infra-apps \
  --kubeconfig ./192.168.2.180.config \
  --path ./infrastructure/apps \
  --kustomization-file ./clusters/librepod-dev/infra-apps.yaml \
  --local-sources GitRepository/flux-system/librepod-apps=./"

# Cluster-config source
kustomize build infrastructure/cluster-config
```

Expected: All builds succeed with valid YAML output. No errors.

- [ ] **Step 2: Diff against live cluster**

```bash
nix-shell shell.nix --run "flux diff kustomization infra-apps \
  --kubeconfig ./192.168.2.180.config \
  --path ./infrastructure/apps \
  --kustomization-file ./clusters/librepod-dev/infra-apps.yaml \
  --local-sources GitRepository/flux-system/librepod-apps=./"
```

Expected: Shows the new cluster-config-source Kustomization, the removal of open-webui Kustomization, and the addition of external-secrets. The gogs Kustomization should show the new repo-init Job and RBAC resources.

- [ ] **Step 3: Test on dev cluster from a feature branch**

Follow the Flux workflow from `docs/FLUX_WORKFLOW.md`:

```bash
# Push to feature branch
git checkout -b feature/portable-marketplace
git push origin feature/portable-marketplace

# Point GitRepository at feature branch
kubectl --kubeconfig ./192.168.2.180.config \
  patch gitrepository librepod-apps -n flux-system \
  --type json \
  -p '[{"op": "replace", "path": "/spec/ref", "value": {"branch": "feature/portable-marketplace"}}]'

# Reconcile
nix-shell shell.nix --run "flux reconcile kustomization infra-apps \
  --kubeconfig ./192.168.2.180.config \
  --with-source"
```

- [ ] **Step 4: Verify repo-init Job completes**

```bash
kubectl --kubeconfig ./192.168.2.180.config \
  get jobs -n gogs

kubectl --kubeconfig ./192.168.2.180.config \
  logs job/job-gogs-repo-init -n gogs --all-containers
```

Expected: Job completes successfully. Logs show repo creation and Secret creation.

- [ ] **Step 5: Verify Flux connects to private Gogs repo**

```bash
nix-shell shell.nix --run "flux get kustomizations \
  --kubeconfig ./192.168.2.180.config \
  -n flux-system"
```

Expected: `cluster-config` and `cluster-config-source` kustomizations show `READY=True`.

- [ ] **Step 6: Restore GitRepository to master**

```bash
kubectl --kubeconfig ./192.168.2.180.config \
  patch gitrepository librepod-apps -n flux-system \
  --type json \
  -p '[{"op": "replace", "path": "/spec/ref", "value": {"branch": "master"}}]'

nix-shell shell.nix --run "flux reconcile kustomization infra-apps \
  --kubeconfig ./192.168.2.180.config \
  --with-source"
```

- [ ] **Step 7: Commit any fixes discovered during testing**

If testing reveals issues (wrong service port, RBAC permissions, script bugs), fix them and commit each fix separately.

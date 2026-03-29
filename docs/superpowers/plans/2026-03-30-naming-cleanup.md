# Naming Cleanup — Consistent Renaming Across Repository and Flux Entities

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename all ambiguous directory names, Flux entity names, and file names to a consistent convention that clearly distinguishes system apps, system configs, and user app wiring.

**Architecture:** A mechanical find-and-rename across 4 layers: (1) infrastructure directory names, (2) Flux Kustomization/GitRepository entity names, (3) cluster environment files that reference them, (4) auth secret names. Also rename the `librepod-marketplace` OCIRepository to `librepod-bootstrap` so it matches its artifact name.

**Tech Stack:** YAML, FluxCD, Kustomize, Git

---

## Renaming Map (Quick Reference)

| Layer | Current | Proposed |
|-------|---------|----------|
| OCIRepository (bootstrap) | `librepod-marketplace` | `librepod-bootstrap` |
| Dir: `infrastructure/apps/` | `apps` | `system-apps` |
| Dir: `infrastructure/configs/` | `configs` | `system-configs` |
| Dir: `infrastructure/cluster-config/` | `cluster-config` | `user-apps-source` |
| File: `clusters/<env>/infra-apps.yaml` | `infra-apps` | `system-apps` |
| Flux KS name inside ^ | `infra-apps` | `system-apps` |
| File: `clusters/<env>/infra-configs.yaml` | `infra-configs` | `system-configs` |
| Flux KS name inside ^ | `infra-configs` | `system-configs` |
| File: `clusters/librepod-dev/cluster-config.yaml` | `cluster-config` | `user-apps-source` |
| Flux KS name inside ^ | `cluster-config` | `user-apps-source` |
| GitRepository name | `cluster-config` | `user-apps-source` |
| Auth secret name | `cluster-config-auth` | `user-apps-source-auth` |
| Inner Flux KS name | `cluster-config-apps` | `user-apps` |
| File: `infrastructure/cluster-config/kustomization-cr.yaml` | `kustomization-cr.yaml` | `user-apps.yaml` |
| Gogs repo in URL | `flux/cluster-config.git` | `flux/user-apps.git` |

---

## Task 1: Rename `infrastructure/apps/` → `infrastructure/system-apps/`

**Files:**
- Move: `infrastructure/apps/` → `infrastructure/system-apps/`

- [ ] **Step 1: Move the directory**

```bash
git mv infrastructure/apps infrastructure/system-apps
```

- [ ] **Step 2: Update `clusters/librepod/system-apps.yaml` (will be renamed in Task 3)**

In the file currently at `clusters/librepod/infra-apps.yaml`, change:

```yaml
  path: ./infrastructure/apps
```
→
```yaml
  path: ./infrastructure/system-apps
```

This change is documented here for awareness but will be performed as part of Task 3 which rewrites the whole file.

- [ ] **Step 3: Update `clusters/librepod-dev/system-apps.yaml` (will be renamed in Task 3)**

Same path change in `clusters/librepod-dev/infra-apps.yaml` — also handled in Task 3.

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "refactor: rename infrastructure/apps/ to infrastructure/system-apps/"
```

---

## Task 2: Rename `infrastructure/configs/` → `infrastructure/system-configs/`

**Files:**
- Move: `infrastructure/configs/` → `infrastructure/system-configs/`

- [ ] **Step 1: Move the directory**

```bash
git mv infrastructure/configs infrastructure/system-configs
```

- [ ] **Step 2: Update path references (handled in Task 3)**

The files `clusters/librepod/infra-configs.yaml` and `clusters/librepod-dev/infra-configs.yaml` reference `./infrastructure/configs` — these are rewritten in Task 3.

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "refactor: rename infrastructure/configs/ to infrastructure/system-configs/"
```

---

## Task 3: Rename cluster environment files and Flux entity names (`infra-*` → `system-*`, OCIRepository → `librepod-bootstrap`)

This task rewrites all four top-level Flux Kustomization files in both cluster environments. All changes in one commit since they're interdependent.

**Files:**
- Move + rewrite: `clusters/librepod/infra-apps.yaml` → `clusters/librepod/system-apps.yaml`
- Move + rewrite: `clusters/librepod/infra-configs.yaml` → `clusters/librepod/system-configs.yaml`
- Move + rewrite: `clusters/librepod-dev/infra-apps.yaml` → `clusters/librepod-dev/system-apps.yaml`
- Move + rewrite: `clusters/librepod-dev/infra-configs.yaml` → `clusters/librepod-dev/system-configs.yaml`

- [ ] **Step 1: Rename files in clusters/librepod/**

```bash
git mv clusters/librepod/infra-apps.yaml clusters/librepod/system-apps.yaml
git mv clusters/librepod/infra-configs.yaml clusters/librepod/system-configs.yaml
```

- [ ] **Step 2: Rewrite `clusters/librepod/system-apps.yaml`**

Replace the entire file content with:

```yaml
# System Apps - Core infrastructure required for cluster to function
# These apps are deployed first and must be healthy before user apps
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: system-apps
  namespace: flux-system
spec:
  interval: 1h
  retryInterval: 2m
  timeout: 5m
  sourceRef:
    kind: OCIRepository
    name: librepod-bootstrap
  path: ./infrastructure/system-apps
  prune: true
  patches: []
  postBuild:
    substitute:
      BASE_DOMAIN: "libre.pod"
```

- [ ] **Step 3: Rewrite `clusters/librepod/system-configs.yaml`**

Replace the entire file content with:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: system-configs
  namespace: flux-system
spec:
  dependsOn:
    - name: system-apps
  interval: 1h
  retryInterval: 2m
  timeout: 5m
  sourceRef:
    kind: OCIRepository
    name: librepod-bootstrap
  path: ./infrastructure/system-configs
  prune: true
  patches: []
  postBuild:
    substitute:
      BASE_DOMAIN: "libre.pod"
```

- [ ] **Step 4: Rename files in clusters/librepod-dev/**

```bash
git mv clusters/librepod-dev/infra-apps.yaml clusters/librepod-dev/system-apps.yaml
git mv clusters/librepod-dev/infra-configs.yaml clusters/librepod-dev/system-configs.yaml
```

- [ ] **Step 5: Rewrite `clusters/librepod-dev/system-apps.yaml`**

Replace the entire file content with:

```yaml
# System Apps - Core infrastructure required for cluster to function
# These apps are deployed first and must be healthy before user apps
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: system-apps
  namespace: flux-system
spec:
  interval: 1h
  retryInterval: 2m
  timeout: 5m
  sourceRef:
    kind: OCIRepository
    name: librepod-bootstrap
  path: ./infrastructure/system-apps
  prune: true
  patches: []
  postBuild:
    substitute:
      BASE_DOMAIN: "librepod.dev"
```

- [ ] **Step 6: Rewrite `clusters/librepod-dev/system-configs.yaml`**

Replace the entire file content with:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: system-configs
  namespace: flux-system
spec:
  dependsOn:
    - name: system-apps
  interval: 1h
  retryInterval: 2m
  timeout: 5m
  sourceRef:
    kind: OCIRepository
    name: librepod-bootstrap
  path: ./infrastructure/system-configs
  prune: true
  patches: []
  postBuild:
    substitute:
      BASE_DOMAIN: "librepod.dev"
```

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "refactor: rename infra-* to system-*, OCIRepository to librepod-bootstrap"
```

---

## Task 4: Rename `infrastructure/cluster-config/` → `infrastructure/user-apps-source/` and all its Flux entities

This is the biggest rename — directory, GitRepository, Kustomization, auth secret, Gogs URL, and file names.

**Files:**
- Move: `infrastructure/cluster-config/` → `infrastructure/user-apps-source/`
- Rewrite: `infrastructure/user-apps-source/gitrepository.yaml`
- Move + rewrite: `infrastructure/cluster-config/kustomization-cr.yaml` → `infrastructure/user-apps-source/user-apps.yaml`
- Rewrite: `infrastructure/user-apps-source/kustomization.yaml`

- [ ] **Step 1: Move the directory**

```bash
git mv infrastructure/cluster-config infrastructure/user-apps-source
```

- [ ] **Step 2: Rewrite `infrastructure/user-apps-source/gitrepository.yaml`**

Replace the entire file content with:

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata:
  name: user-apps-source
  namespace: flux-system
spec:
  interval: 1m
  url: http://gogs.gogs.svc.cluster.local:80/flux/user-apps.git
  ref:
    branch: master
  secretRef:
    name: user-apps-source-auth
```

- [ ] **Step 3: Rename and rewrite the inner Kustomization file**

```bash
git mv infrastructure/user-apps-source/kustomization-cr.yaml infrastructure/user-apps-source/user-apps.yaml
```

Replace the entire file content with:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: user-apps
  namespace: flux-system
spec:
  interval: 1m
  sourceRef:
    kind: GitRepository
    name: user-apps-source
  path: ./
  prune: true
  wait: true
```

Note: The 7-line collision-avoidance comment is removed because the outer Kustomization is now `user-apps-source` (different from inner `user-apps`), eliminating the name collision.

- [ ] **Step 4: Verify `infrastructure/user-apps-source/kustomization.yaml` still references correct files**

The file should contain:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization

resources:
  - gitrepository.yaml
  - user-apps.yaml
```

Update the `resources` list if it still references `kustomization-cr.yaml`.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor: rename cluster-config/ to user-apps-source/, eliminate naming collision"
```

---

## Task 5: Update `clusters/librepod-dev/cluster-config.yaml` → `user-apps-source.yaml`

**Files:**
- Move + rewrite: `clusters/librepod-dev/cluster-config.yaml` → `clusters/librepod-dev/user-apps-source.yaml`

- [ ] **Step 1: Rename file**

```bash
git mv clusters/librepod-dev/cluster-config.yaml clusters/librepod-dev/user-apps-source.yaml
```

- [ ] **Step 2: Rewrite the file**

Replace the entire file content with:

```yaml
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: user-apps-source
  namespace: flux-system
spec:
  dependsOn:
    - name: system-configs
  interval: 1h
  retryInterval: 2m
  timeout: 5m
  sourceRef:
    kind: OCIRepository
    name: librepod-bootstrap
  path: ./infrastructure/user-apps-source
  prune: true
  patches: []
  postBuild:
    substitute:
      BASE_DOMAIN: "librepod.dev"
```

- [ ] **Step 3: Commit**

```bash
git add -A
git commit -m "refactor: rename cluster-config.yaml to user-apps-source.yaml in librepod-dev"
```

---

## Task 6: Update auth secret name in Gogs repo-init component

The `cluster-config-auth` secret is generated by the Gogs repo-init component and consumed by the GitRepository in `infrastructure/user-apps-source/gitrepository.yaml`.

**Files:**
- Modify: `apps/gogs/components/repo-init/kustomization.yaml`

- [ ] **Step 1: Update secretGenerator name**

In `apps/gogs/components/repo-init/kustomization.yaml`, change:

```yaml
secretGenerator:
  - name: cluster-config-auth
```
→
```yaml
secretGenerator:
  - name: user-apps-source-auth
```

The rest of the file (envs, annotations) stays the same.

- [ ] **Step 2: Commit**

```bash
git add apps/gogs/components/repo-init/kustomization.yaml
git commit -m "refactor: rename cluster-config-auth secret to user-apps-source-auth"
```

---

## Task 7: Update documentation

**Files:**
- Modify: `README.md`
- Modify: `docs/user-guide.md`
- Modify: `docs/FLUX_WORKFLOW.md`
- Modify: `apps/step-issuer/components/bootstrap-cluster-issuer/README.md`

This is a documentation sweep to replace all old names with new names. Note: design spec docs under `docs/superpowers/specs/` are historical records and should NOT be modified.

- [ ] **Step 1: Update `README.md`**

Replace all occurrences:
- `infrastructure/apps` → `infrastructure/system-apps`
- `infrastructure/configs` → `infrastructure/system-configs`
- `infrastructure/cluster-config` → `infrastructure/user-apps-source`
- `infra-apps` → `system-apps`
- `infra-configs` → `system-configs`
- `librepod-marketplace` (OCIRepository name, not the project name) → `librepod-bootstrap`
- `cluster-config` (in context of Flux entities) → `user-apps-source` or `user-apps` as appropriate
- `cluster-config-auth` → `user-apps-source-auth`
- `cluster-config-apps` → `user-apps`

Update the repository structure tree, the bootstrap YAML examples, the app install section, the CI section, and the recovery section.

Also update the "Bootstrap Publishing" section to reflect new directory names:
```
- `infrastructure/system-apps/` — One `OCIRepository` + `Kustomization` per system app
- `infrastructure/user-apps-source/` — GitRepository + Kustomization CR wiring Flux to the private Gogs repo
- `infrastructure/system-configs/` — Cluster-wide configuration
```

- [ ] **Step 2: Update `docs/user-guide.md`**

Replace:
- All `cluster-config` references (repo name, Flux entity names) → `user-apps` or `user-apps-source` as contextually appropriate
- `marketplace-bootstrap` → `librepod-bootstrap`
- `infrastructure/apps` → `infrastructure/system-apps`
- `infrastructure/configs` → `infrastructure/system-configs`
- `librepod/cluster-config.git` → `flux/user-apps.git`
- `infra-apps` → `system-apps`
- `infra-configs` → `system-configs`

- [ ] **Step 3: Update `docs/FLUX_WORKFLOW.md`**

Replace:
- `infra-apps` → `system-apps`
- `infrastructure/apps` → `infrastructure/system-apps`

- [ ] **Step 4: Update `apps/step-issuer/components/bootstrap-cluster-issuer/README.md`**

Replace the single reference:
- `infrastructure/apps/step-issuer.yaml` → `infrastructure/system-apps/step-issuer.yaml`

- [ ] **Step 5: Commit**

```bash
git add README.md docs/user-guide.md docs/FLUX_WORKFLOW.md apps/step-issuer/components/bootstrap-cluster-issuer/README.md
git commit -m "docs: update all documentation for new naming convention"
```

---

## Task 8: Validate with kustomize build

- [ ] **Step 1: Build system-apps kustomization**

```bash
kustomize build ./infrastructure/system-apps
```

Expected: Outputs YAML with OCIRepository and Kustomization resources for each system app. No errors.

- [ ] **Step 2: Build user-apps-source kustomization**

```bash
kustomize build ./infrastructure/user-apps-source
```

Expected: Outputs GitRepository (name: `user-apps-source`) and Kustomization (name: `user-apps`). No errors.

- [ ] **Step 3: Build the Gogs overlay (includes repo-init component)**

```bash
kustomize build ./apps/gogs/overlays/librepod
```

Expected: Includes a Secret named `user-apps-source-auth`. No errors.

- [ ] **Step 4: Fix any issues found, commit**

```bash
git add -A
git commit -m "fix: resolve kustomize build issues from renaming"
```

---

## Task 9: Update CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update CLAUDE.md references**

The CLAUDE.md contains instructions for developers. Update:
- Any references to `infrastructure/apps` → `infrastructure/system-apps`
- Any references to `infrastructure/configs` → `infrastructure/system-configs`
- Any references to `infra-apps` → `system-apps`

Read the current file and update all occurrences.

- [ ] **Step 2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for new naming convention"
```

---

## Files NOT Modified (by design)

| File | Reason |
|------|--------|
| `docs/superpowers/specs/*.md` | Historical design documents — record of decisions, not living docs |
| `docs/marketplace-for-self-hosted-apps-design.md` | Original design doc — historical reference |
| `infrastructure/system-apps/*.yaml` (individual app files) | App OCIRepository/Kustomization names stay as-is (traefik, gogs, etc.) — they match the app name which is correct |
| `apps/*/metadata.yaml` | Templates use `marketplace-<app>` prefix for user-installed resources — different from system app naming, this is intentional |
| `.github/workflows/publish-bootstrap.yaml` | Copies `infrastructure/` as a whole — no path-specific references to rename |
| `.github/workflows/publish-apps.yaml` | No references to old names |

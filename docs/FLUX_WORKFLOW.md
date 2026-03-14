# FluxCD Developer Workflow

This document describes the workflow for an AI agent (or developer) to modify
apps in `./apps`, validate changes, test on the `librepod-dev` cluster, and
verify reconciliation — **without requiring a merge to `master`**.

All commands are run from the **repository root**.

---

## Prerequisites

Check if the `flux` CLI is provided.
If not provided, use it via nix-shell. Enter the dev shell before running any flux commands, or prefix each command with `nix-shell shell.nix --run`:

```bash
# Option A: enter nix shell once
nix-shell shell.nix

# Option B: prefix individual commands
nix-shell shell.nix --run "flux version"
```

**Cluster access**: the dev cluster kubeconfig lives at `./192.168.2.180.config`
(gitignored). Pass it explicitly to every `flux` and `kubectl` call:

```bash
--kubeconfig ./192.168.2.180.config
```

**Key names** (already provisioned on the dev cluster):
- GitRepository: `librepod-apps` in namespace `flux-system`
- Default branch tracked by cluster: `master`

---

## Step 1 — Validate manifests locally (no cluster contact needed)

Build the rendered YAML for any kustomization using `--local-sources` to
substitute the live GitRepository with the current working tree. This applies
all patches and variable substitutions exactly as FluxCD would.

```bash
# Top-level infrastructure apps kustomization
flux build kustomization infra-apps \
  --kubeconfig ./192.168.2.180.config \
  --path ./infrastructure/apps \
  --kustomization-file ./clusters/librepod-dev/infra-apps.yaml \
  --local-sources GitRepository/flux-system/librepod-apps=./

# Individual app (substitute <app-name> and <kustomization-name>)
flux build kustomization <kustomization-name> \
  --kubeconfig ./192.168.2.180.config \
  --path ./apps/<app-name>/overlays/librepod \
  --local-sources GitRepository/flux-system/librepod-apps=./
```

Validate the rendered output with `kubeconform` to catch schema errors early:

```bash
flux build kustomization <kustomization-name> \
  --kubeconfig ./192.168.2.180.config \
  --path ./apps/<app-name>/overlays/librepod \
  --local-sources GitRepository/flux-system/librepod-apps=./ \
  | kubeconform \
      -schema-location default \
      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
      -strict -summary
```

---

## Step 2 — Diff local changes against the live cluster

`flux diff` shows exactly what would change on the cluster if the current local
state were applied. A clean diff (no output) means the cluster already matches
local changes.

```bash
# Diff infra-apps kustomization
flux diff kustomization infra-apps \
  --kubeconfig ./192.168.2.180.config \
  --path ./infrastructure/apps \
  --kustomization-file ./clusters/librepod-dev/infra-apps.yaml \
  --local-sources GitRepository/flux-system/librepod-apps=./

# Diff a specific app kustomization
flux diff kustomization <kustomization-name> \
  --kubeconfig ./192.168.2.180.config \
  --path ./apps/<app-name>/overlays/librepod \
  --local-sources GitRepository/flux-system/librepod-apps=./
```

Exit code `1` with diff output means there are pending changes. Exit code `0`
means no drift.

---

## Step 3 — Test on the dev cluster from a feature branch

This is the recommended path to actually apply and test changes end-to-end
through the FluxCD reconciliation loop, without merging to `master`.

### 3a. Push changes to a feature branch

```bash
git checkout -b feature/<description>
git add .
git commit -m "feat: <description>"
git push origin feature/<description>
```

### 3b. Temporarily point the GitRepository at your branch

```bash
kubectl --kubeconfig ./192.168.2.180.config \
  patch gitrepository librepod-apps \
  -n flux-system \
  --type merge \
  -p '{"spec":{"ref":{"branch":"feature/<description>"}}}'
```

### 3c. Force reconciliation

Trigger an immediate re-fetch of the source and reconcile the target
kustomization:

```bash
# Reconcile source + a top-level kustomization together
flux reconcile kustomization infra-apps \
  --kubeconfig ./192.168.2.180.config \
  --with-source

# Or reconcile source first, then kustomization separately
flux reconcile source git librepod-apps \
  --kubeconfig ./192.168.2.180.config

flux reconcile kustomization <kustomization-name> \
  --kubeconfig ./192.168.2.180.config
```

### 3d. Restore the GitRepository to master when done

```bash
kubectl --kubeconfig ./192.168.2.180.config \
  patch gitrepository librepod-apps \
  -n flux-system \
  --type merge \
  -p '{"spec":{"ref":{"branch":"master"}}}'

flux reconcile kustomization infra-apps \
  --kubeconfig ./192.168.2.180.config \
  --with-source
```

---

## Step 4 — Verify reconciliation

Run these commands after any reconcile to confirm the cluster reached the
desired state.

### Check kustomization status

```bash
flux get kustomizations \
  --kubeconfig ./192.168.2.180.config \
  -n flux-system
```

Expected output: all relevant kustomizations show `READY=True` and the revision
matches the expected branch/commit.

### Inspect the resource tree

```bash
flux tree kustomization <kustomization-name> \
  --kubeconfig ./192.168.2.180.config
```

### Tail reconciliation logs

```bash
flux logs \
  --kubeconfig ./192.168.2.180.config \
  --kind=Kustomization \
  --name=<kustomization-name> \
  --namespace=flux-system \
  --tail=30
```

### Check deployed pods (optional deep verification)

```bash
kubectl --kubeconfig ./192.168.2.180.config \
  get pods -n <app-namespace>
```

---

## Quick-reference cheatsheet

| Goal | Command |
|------|---------|
| Preview rendered manifests locally | `flux build kustomization <name> ... --local-sources GitRepository/flux-system/librepod-apps=./` |
| Show drift vs cluster | `flux diff kustomization <name> ... --local-sources GitRepository/flux-system/librepod-apps=./` |
| Force reconcile (source + kustomization) | `flux reconcile kustomization <name> --kubeconfig ... --with-source` |
| Check all kustomization statuses | `flux get kustomizations --kubeconfig ... -n flux-system` |
| View resource tree | `flux tree kustomization <name> --kubeconfig ...` |
| View reconciliation logs | `flux logs --kubeconfig ... --kind=Kustomization --name=<name> -n flux-system --tail=30` |
| Switch GitRepository branch | `kubectl patch gitrepository librepod-apps -n flux-system --type merge -p '{"spec":{"ref":{"branch":"<branch>"}}}'` |

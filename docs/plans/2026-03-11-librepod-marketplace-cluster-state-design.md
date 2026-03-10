# LibrePod Marketplace + Per-Cluster GitOps State (Design)

Date: 2026-03-11

## Summary

LibrePod needs a GitOps-friendly way to let non-technical users install applications from a shared Marketplace repository, while tracking each cluster’s installed apps in a cluster-owned source of truth.

This design keeps `librepod/apps` as a shared, read-only Marketplace (curated app manifests and defaults), and introduces an in-cluster Git service (Gitea/Forgejo) that hosts a per-cluster **cluster-state** repository. FluxCD syncs the cluster-state repo; LibrePod Server modifies it (commits) to represent user actions like “install” and “uninstall”.

Key constraints (from discussion):
- Cluster desired state must be fully reproducible **from Git alone**.
- LibrePod targets trusted/LAN environments and non-technical users.
- “One-click install” UX: minimal/no user-provided overrides.
- Secrets are stored in Git **unencrypted** (explicit trade-off).

## Goals

- Separate concerns:
  - Marketplace repo: shared catalog of apps and defaults.
  - Cluster-state repo: which apps are installed on a given cluster.
- One-click install/uninstall driven by LibrePod Server.
- FluxCD continuously reconciles desired state defined in Git.
- Keep user customization surface minimal (defaults should work).

## Non-Goals (for now)

- Rich per-app configuration UI (env var overrides, domain tweaks, resource tuning).
- Encrypted secrets in Git (SOPS/ExternalSecrets).
- Supporting arbitrary user patches/overlays.

## High-level Architecture

### Components

1. **Marketplace repository (this repo: `librepod/apps`)**
   - Owns app definitions and sane defaults.
   - Each app provides a stable deployment target, e.g. `apps/<app>/overlays/librepod`.
   - Read-only from user clusters’ perspective.

2. **In-cluster Git service (Gitea/Forgejo)**
   - Runs as a LibrePod “system package” (prerequisite like Traefik).
   - Exposed to users via a friendly URL (e.g. `https://git.libre.pod`).
   - Also accessible internally via Kubernetes networking for Flux sync.

3. **Cluster-state repository (hosted in Gitea)**
   - The authoritative Git repository describing the cluster’s desired state.
   - Minimal content: sources + one Flux Kustomization per installed app + plaintext Secret manifests.

4. **FluxCD**
   - Bootstrapped against the cluster-state repo.
   - Reconciles resources declared in that repo.
   - Pulls the Marketplace repo as a separate source (GitRepository), referenced by per-app Kustomizations.

5. **LibrePod Server**
   - Provides user UX (“Install”, “Uninstall”).
   - Implements actions by committing changes into cluster-state repo.
   - May generate secrets and commit plaintext Secret manifests.

### Responsibility boundaries

- **Marketplace maintainers**: update app manifests and defaults.
- **LibrePod Server**: writes cluster-state (installed apps) and secrets.
- **FluxCD**: ensures cluster matches cluster-state.

## GitOps Data Model

### “Install app” = Git commit

When a user clicks Install for app `X`, LibrePod Server commits:
- A Flux `Kustomization` resource for `app-X` that points at the Marketplace’s `apps/X/overlays/librepod`.
- Any required Kubernetes `Secret` resources (plaintext) needed by the app.

When a user clicks Uninstall:
- LibrePod Server deletes the `Kustomization` and the associated Secret(s) from Git.
- Flux prunes resources (via `prune: true`).

## Proposed cluster-state repo layout

Opinionated but simple:

```
cluster-state/
  flux-system/
    gotk-sync.yaml              # Flux bootstrap sync (points at this repo)
    gotk-components.yaml        # Flux components (optional if already installed)

  sources/
    marketplace-gitrepo.yaml    # Flux GitRepository for librepod/apps (read-only)

  apps/
    kustomization.yaml          # Kustomize file aggregating installed app Kustomizations
    installed/
      vaultwarden.yaml          # Flux Kustomization for vaultwarden (installed)
      seafile.yaml
      ...

  secrets/
    vaultwarden.yaml            # plaintext Secret(s) for vaultwarden
    ...
```

Notes:
- The `apps/installed/*.yaml` and `secrets/*.yaml` files are the only things that change frequently.
- If we later need “system packages” tracked in Git too, they can live under `system/` and be applied similarly.

## Flux resource patterns

### Marketplace source

Cluster-state defines a Flux `GitRepository` pointing at the Marketplace repo (this repo).

### Per-app Kustomization

Each installed app is represented by a Flux `Kustomization`:
- `sourceRef` points to the Marketplace `GitRepository`.
- `path` points to `./apps/<app>/overlays/librepod`.
- `prune: true` ensures uninstall via git deletion.
- Optionally `dependsOn` on infrastructure/system prereqs.

## Secrets strategy (explicit trade-off)

Decision: **Secrets are stored unencrypted in the cluster-state Git repository.**

Implications:
- Backups of the device / repo include secrets.
- Anyone with access to Gitea repo content can read secrets.
- Safe usage assumes trusted LAN environment and proper access control.

Mitigations (recommended baseline hygiene, not user-facing configuration):
- Keep Gitea LAN-only; no direct internet exposure.
- Enforce strong initial admin credential setup.
- Ensure TLS for `git.libre.pod`.
- Consider restricting who can read the cluster-state repo.

## Operational flows

### Bootstrap

1. Install “system packages” (Traefik, Gitea/Forgejo, Flux).
2. Create/initialize the cluster-state repo in Gitea.
3. Bootstrap Flux to sync from cluster-state.
4. Cluster is now managed via Git; LibrePod Server commits changes to drive installs.

### Install

1. LibrePod Server generates/collects any required secrets.
2. LibrePod Server commits:
   - `apps/installed/<app>.yaml` (Flux Kustomization)
   - `secrets/<app>.yaml` (Secret manifests)
3. Flux reconciles and the app becomes ready.

### Uninstall

1. LibrePod Server commits deletion of:
   - `apps/installed/<app>.yaml`
   - `secrets/<app>.yaml`
2. Flux prunes removed resources.

### Upgrade

Two modes (future decision; default can be auto-upgrade):
- **Track Marketplace main**: apps update when Marketplace updates.
- **Pin versions**: Marketplace source uses tags/commits; LibrePod Server updates the pinned ref.

## Open questions / future extensions

- Do we want a small set of “safe toggles” (domain, enable ingress, storage size), still one-click but perhaps advanced tab?
- Should “system packages” also be represented in the cluster-state repo for completeness?
- How do we represent app readiness back to LibrePod UI (watch Flux Kustomization status)?

---

## Decision log

- Use in-cluster Gitea/Forgejo as system component.
- Flux syncs cluster-state repo; cluster-state references Marketplace.
- Kustomize as primary packaging/deploy mechanism.
- One-click installs; minimal user overrides.
- Plaintext secrets in Git (trusted environment assumption).

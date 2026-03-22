# Phase 1 MVP — Implementation Plan

**Goal:** A working marketplace where a user can install the controller on their Flux-enabled cluster, browse available apps, install/configure/remove them through a web UI, and have everything reconciled by Flux.

**Assumptions:**
- Single developer working full-time
- Familiar with Go, Kubernetes, Flux, and frontend development
- 5–10 apps in the initial catalog
- Public OCI registry (ghcr.io)

---

## Workstream Overview

```
Week 1          Week 2          Week 3          Week 4          Week 5
┌───────────┐  ┌────────────┐  ┌───────────┐  ┌────────────┐  ┌─────────────┐
│ WS1: App  │  │ WS2: CI +  │  │ WS3: Controller Backend   │  │ WS4: UI +   │
│ Packaging │  │ OCI Publish│  │ (API + Flux integration)  │  │ Integration │
│           │  │            │  │                           │  │ + Testing   │
└───────────┘  └────────────┘  └───────────────────────────┘  └─────────────┘
```

**Estimated total: 5 weeks (~200 hours)**

---

## Workstream 1: App Packaging

**Goal:** Establish the app repo structure, finalize metadata schema, and package 5–10 apps.

### Task 1.1 — Finalize metadata schema
```
Define the metadata.yaml spec with all field types,
validation rules, and defaults. Write a JSON Schema
for programmatic validation.

Deliverable: metadata-schema.json + documented spec
Estimate:    4 hours
```

### Task 1.2 — Create app packaging template
```
A reference/template directory showing the exact
structure a new app must follow. Include a README
with packaging guidelines.

Deliverable: apps/_template/ directory
Estimate:    2 hours
```

### Task 1.3 — Package first app (Vaultwarden)
```
Build the kustomize base with variable placeholders.
Test manually with Flux + postBuild.substitute to
confirm variables resolve correctly. This is the
reference implementation — get it right.

Deliverable: apps/bitwarden/ (base + metadata.yaml)
Estimate:    6 hours
```

### Task 1.4 — Package 4 more apps
```
Select 4 apps across different categories to validate
the schema handles diverse requirements:
  - A media app (e.g., Sonarr or Jellyfin)
  - A productivity app (e.g., Mattermost or Outline)
  - A monitoring app (e.g., Uptime Kuma)
  - A simple stateless app (e.g., Homepage dashboard)

Each app: kustomize base + metadata.yaml, tested
manually with Flux.

Deliverable: 4 app directories
Estimate:    16 hours (4h per app)
```

### Task 1.5 — Write catalog generation script
```
A script that walks apps/*/metadata.yaml and produces
catalog.yaml. Run as part of CI and locally for testing.

Deliverable: scripts/generate-catalog.sh
Estimate:    2 hours
```

**Workstream 1 Total: ~30 hours**

---

## Workstream 2: CI Pipeline & OCI Publishing

**Goal:** Automated pipeline that publishes changed apps as OCI artifacts and updates the catalog.

### Task 2.1 — Set up OCI registry
```
Configure ghcr.io (or alternative) with appropriate
permissions. Create the repository namespace structure:
  ghcr.io/<org>/marketplace/apps/<name>
  ghcr.io/<org>/marketplace/catalog

Test manual flux push artifact to confirm access.

Deliverable: Working registry with push access
Estimate:    2 hours
```

### Task 2.2 — Build CI workflow — app publishing
```
GitHub Actions workflow that:
  1. Detects which apps/ directories changed
  2. Validates metadata.yaml against JSON schema
  3. Runs flux push artifact for each changed app
  4. Tags with version from metadata.yaml

Include a manual dispatch option to republish all apps.

Deliverable: .github/workflows/publish-apps.yaml
Estimate:    6 hours
```

### Task 2.3 — Build CI workflow — catalog publishing
```
Runs after app publishing. Generates catalog.yaml
and pushes as OCI artifact.

Deliverable: .github/workflows/publish-catalog.yaml
             (or job within publish-apps.yaml)
Estimate:    3 hours
```

### Task 2.4 — Validate end-to-end OCI flow
```
From a test cluster:
  1. Create OCIRepository pointing to published app
  2. Create Kustomization with postBuild.substitute
  3. Confirm Flux pulls the artifact and deploys the app
  4. Update the app in git, confirm CI publishes,
     confirm Flux picks up the new version

Deliverable: Documented test run, any fixes applied
Estimate:    4 hours
```

**Workstream 2 Total: ~15 hours**

---

## Workstream 3: Controller Backend

**Goal:** Go service that provides the REST API for app lifecycle management, reading state from the cluster.

### Task 3.1 — Project scaffolding
```
Initialize Go module. Set up:
  - Project structure (cmd/, internal/, api/)
  - Kubernetes client (controller-runtime or client-go)
  - HTTP router (chi, gin, or stdlib)
  - Configuration (OCI registry URL, namespace, etc.)
  - Dockerfile
  - Basic health endpoint

Deliverable: Compiling, containerized Go service with /healthz
Estimate:    4 hours
```

### Task 3.2 — Catalog syncer
```
Component that:
  1. Pulls catalog.yaml from OCI registry on startup
     and at a configurable interval
  2. For each app in the catalog, fetches metadata.yaml
     from the app's OCI artifact
  3. Caches in memory
  4. Exposes via GET /api/catalog

Use flux's OCI pull libraries or shell out to
flux pull artifact (simpler for MVP).

Deliverable: Working /api/catalog endpoint
Estimate:    8 hours
```

### Task 3.3 — Install endpoint
```
POST /api/apps/install

  1. Parse and validate request body against
     the app's metadata schema (required params,
     types, secrets)
  2. Generate Flux resource manifests:
     - Namespace
     - Secret (user secrets)
     - OCIRepository
     - Kustomization (with postBuild + labels)
  3. Apply to cluster via k8s client
  4. Return 202 with app name

Build a manifest generator module that templates
the Flux resources from app config — this is the
core of the controller.

Deliverable: Working install endpoint, tested with curl
Estimate:    12 hours
```

### Task 3.4 — List installed apps endpoint
```
GET /api/installed

  1. List Kustomizations with label
     marketplace.io/managed=true
  2. For each, extract:
     - App name, version (from labels)
     - Status (from .status.conditions)
     - Params (from .spec.postBuild.substitute)
  3. Return as JSON array

Deliverable: Working endpoint
Estimate:    4 hours
```

### Task 3.5 — App detail/status endpoint
```
GET /api/apps/:name

  1. Get the specific Kustomization
  2. Get the associated OCIRepository
  3. Return detailed status:
     - Reconciliation state
     - Last applied revision
     - Any error messages
     - Current params

Deliverable: Working endpoint
Estimate:    3 hours
```

### Task 3.6 — Update configuration endpoint
```
PUT /api/apps/:name

  1. Validate updated params
  2. Patch the Kustomization postBuild.substitute
  3. If secrets changed, patch the Secret
  4. Flux detects change and reconciles

Deliverable: Working endpoint
Estimate:    4 hours
```

### Task 3.7 — Uninstall endpoint
```
DELETE /api/apps/:name

  1. Delete the Kustomization (Flux prunes children)
  2. Delete the OCIRepository
  3. Delete the Secret
  4. Optionally delete the Namespace
     (configurable: retain if PVCs exist)
  5. Return 200

Deliverable: Working endpoint
Estimate:    4 hours
```

### Task 3.8 — Error handling and input validation
```
Harden all endpoints:
  - Validate app exists in catalog before install
  - Prevent duplicate installs
  - Handle Flux resource conflicts
  - Return meaningful error messages
  - Handle timeouts on k8s API calls

Deliverable: Robust error handling across all endpoints
Estimate:    6 hours
```

### Task 3.9 — Controller deployment manifests
```
Create the kustomize base for the controller itself:
  - Deployment
  - Service
  - ServiceAccount + RBAC (ClusterRole, ClusterRoleBinding)
  - Ingress (with variable placeholders)
  - ConfigMap for controller config
    (registry URL, poll interval, etc.)

Deliverable: deploy/ directory with kustomize manifests
Estimate:    4 hours
```

**Workstream 3 Total: ~49 hours**

---

## Workstream 4: Frontend & Integration

**Goal:** Web UI for browsing, installing, and managing apps. End-to-end integration testing.

### Task 4.1 — UI scaffolding
```
Set up frontend project:
  - Framework (Svelte/React/Vue — recommend Svelte
    for bundle size in a self-hosted context)
  - Router
  - HTTP client for API calls
  - Basic layout (nav, content area)
  - Build pipeline (output static files served
    by the Go backend)

Deliverable: Empty shell app served by the controller
Estimate:    4 hours
```

### Task 4.2 — Catalog browsing page
```
Main page showing all available apps:
  - Grid/list of app cards
  - Each card: icon, name, category, description,
    version, Install button
  - Category filter
  - Search by name

Data source: GET /api/catalog

Deliverable: Working catalog page
Estimate:    8 hours
```

### Task 4.3 — App install page
```
Triggered when user clicks Install on a catalog app:
  - Dynamic form generated from metadata.yaml
  - Required fields marked with asterisk
  - Optional fields show defaults (pre-filled)
  - Secret fields with show/hide toggle
  - Auto-generate button for generatable secrets
  - Validation before submit
  - Submit calls POST /api/apps/install
  - Show progress/result

Deliverable: Working install form
Estimate:    10 hours
```

### Task 4.4 — Installed apps dashboard
```
Page showing all installed apps:
  - List with status indicators
    (Ready ●, Progressing ◐, Failed ●)
  - Each row: name, version, status, domain link,
    Configure button, Remove button
  - Auto-refresh status every 10s

Data source: GET /api/installed

Deliverable: Working dashboard
Estimate:    6 hours
```

### Task 4.5 — App detail/configure page
```
When user clicks Configure on an installed app:
  - Show current configuration (params)
  - Editable form (same as install but pre-filled)
  - Save calls PUT /api/apps/:name
  - Show current Flux reconciliation status
  - Remove button with confirmation modal

Deliverable: Working detail page
Estimate:    6 hours
```

### Task 4.6 — Notification/feedback system
```
Simple toast/notification system for:
  - "App installed successfully"
  - "Installation in progress..."
  - "Failed to install: <error>"
  - "App removed"
  - Confirmation dialogs for destructive actions

Deliverable: Integrated notification component
Estimate:    3 hours
```

### Task 4.7 — End-to-end integration testing
```
Deploy everything to a test cluster (kind or real):
  1. Install Flux
  2. Deploy controller
  3. Browse catalog in UI
  4. Install 3 different apps through UI
  5. Verify all apps are running
  6. Update configuration on one app
  7. Remove one app
  8. Verify Flux prunes correctly

Document any bugs found and fix them.

Deliverable: Passing E2E test, bug fixes
Estimate:    12 hours
```

### Task 4.8 — Controller Dockerfile and OCI packaging
```
  - Multi-stage Dockerfile (build Go + build frontend
    + minimal runtime image)
  - Publish controller as OCI artifact via CI
  - Test installing the controller itself via Flux

Deliverable: Published controller OCI artifact
Estimate:    4 hours
```

### Task 4.9 — Documentation
```
  - README: what this is, quick start guide
  - User guide: install controller, install first app
  - App packaging guide: how to add a new app
  - Architecture overview (condensed design doc)

Deliverable: docs/ directory
Estimate:    8 hours
```

**Workstream 4 Total: ~61 hours**

---

## Summary

```
┌────────────────────────────────────────────────────────┐
│  Workstream                        │ Hours  │ Weeks    │
├────────────────────────────────────────────────────────┤
│  WS1: App Packaging                │  30h   │ ~1       │
│  WS2: CI & OCI Publishing         │  15h   │ ~0.5     │
│  WS3: Controller Backend          │  49h   │ ~1.5     │
│  WS4: Frontend & Integration      │  61h   │ ~2       │
├────────────────────────────────────────────────────────┤
│  Total                             │ 155h   │ ~5 weeks │
└────────────────────────────────────────────────────────┘
```

---

## Suggested Execution Order

```
Week 1:
  ├── Task 1.1  Finalize metadata schema
  ├── Task 1.2  App packaging template
  ├── Task 1.3  Package first app (Vaultwarden)
  ├── Task 1.4  Package 4 more apps (start)
  └── Task 2.1  Set up OCI registry

Week 2:
  ├── Task 1.4  Package 4 more apps (finish)
  ├── Task 1.5  Catalog generation script
  ├── Task 2.2  CI workflow — app publishing
  ├── Task 2.3  CI workflow — catalog publishing
  ├── Task 2.4  Validate OCI end-to-end
  └── Task 3.1  Controller scaffolding

Week 3:
  ├── Task 3.2  Catalog syncer
  ├── Task 3.3  Install endpoint
  ├── Task 3.4  List installed endpoint
  ├── Task 3.5  Status endpoint
  └── Task 3.6  Update endpoint

Week 4:
  ├── Task 3.7  Uninstall endpoint
  ├── Task 3.8  Error handling
  ├── Task 3.9  Controller deployment manifests
  ├── Task 4.1  UI scaffolding
  ├── Task 4.2  Catalog page
  └── Task 4.3  Install form (start)

Week 5:
  ├── Task 4.3  Install form (finish)
  ├── Task 4.4  Installed apps dashboard
  ├── Task 4.5  App detail/configure page
  ├── Task 4.6  Notifications
  ├── Task 4.7  End-to-end testing
  ├── Task 4.8  Controller OCI packaging
  └── Task 4.9  Documentation
```

---

## MVP Exit Criteria

Before moving to Phase 2, all of the following must work:

```
☐ 5+ apps published as OCI artifacts with valid metadata
☐ CI pipeline auto-publishes on merge to main
☐ Controller deploys to a cluster via Flux
☐ User can browse the catalog in the web UI
☐ User can install an app through the UI with custom params
☐ Flux reconciles and the app is running
☐ User can see installed apps and their status
☐ User can update app configuration through the UI
☐ User can remove an app and Flux cleans up all resources
☐ All generated Flux resources are clean and standard
☐ Documentation covers setup and first app install
```

---

## Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| OCI pull from controller is complex | Medium | Delays WS3 | Shell out to `flux pull artifact` for MVP; refine later |
| Dynamic form generation from schema is fiddly | Medium | Delays WS4 | Start with simple types (string, int, bool); add complexity later |
| Flux variable substitution edge cases | Low | Breaks apps | Test each app thoroughly in WS1; document placeholder conventions |
| RBAC scoping too narrow | Medium | Runtime errors | Start permissive in dev, tighten for release |
| Frontend scope creep (polish) | High | Delays launch | Ship ugly but functional; polish in Phase 2 |

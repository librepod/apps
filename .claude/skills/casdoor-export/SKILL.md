---
name: casdoor-export
description: Use when exporting Casdoor SSO configuration from the librepod Kubernetes cluster. Triggers on "casdoor export", "export casdoor config", "backup casdoor", "save casdoor init data".
---

# Casdoor Export

Exports Casdoor SSO configuration from the running cluster to the repository's init_data.json file.

## Context

- **Namespace**: `casdoor`
- **Kubeconfig**: `./192.168.2.180.config` (in repository root)
- **Server binary**: `/server` inside the container
- **Init data file**: `apps/casdoor/overlays/librepod/init_data.json` (repository path)

## When to Use

Use after making changes via the Casdoor web UI when you want to persist configuration for cluster bootstrapping.

## Steps

1. Find the casdoor pod:
   ```bash
   kubectl --kubeconfig ./192.168.2.180.config get pods -n casdoor -o name
   ```

2. Run the export command inside the pod:
   ```bash
   kubectl --kubeconfig ./192.168.2.180.config exec -n casdoor <pod-name> -- /server -export -exportPath /tmp/casdoor_export.json
   ```

3. Copy the exported file from the pod:
   ```bash
   kubectl --kubeconfig ./192.168.2.180.config cp casdoor/<pod-name>:/tmp/casdoor_export.json ./apps/casdoor/overlays/librepod/init_data.json
   ```

4. Clean up the temp file in the pod:
   ```bash
   kubectl --kubeconfig ./192.168.2.180.config exec -n casdoor <pod-name> -- rm /tmp/casdoor_export.json
   ```

**Output:** The `apps/casdoor/overlays/librepod/init_data.json` file is updated with the current Casdoor configuration.

## Common Patterns

### Pod name retrieval

Since pod names include random suffixes, always retrieve the current pod name dynamically:
```bash
POD=$(kubectl --kubeconfig ./192.168.2.180.config get pods -n casdoor -o jsonpath='{.items[0].metadata.name}')
```

Then use `$POD` in subsequent commands.

## Notes

- The init_data.json file is version controlled in git, so no separate backup is needed
- The export operation is non-destructive - it reads from the database and outputs JSON
- Multiple replicas: if there are multiple casdoor pods, any one can be used for export (they share the same database)

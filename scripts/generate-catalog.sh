#!/bin/bash
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
  NAME=$(grep '^  name:' "$metadata_file" | head -1 | sed 's/.*name: *//')
  VERSION=$(grep '^  version:' "$metadata_file" | head -1 | sed 's/.*version: *//' | tr -d '"')
  DISPLAY_NAME=$(grep '^  displayName:' "$metadata_file" | sed 's/.*displayName: *//' | tr -d '"')
  CATEGORY=$(grep '^  category:' "$metadata_file" | sed 's/.*category: *//' | tr -d '"')
  ICON=$(grep '^  icon:' "$metadata_file" | sed 's/.*icon: *//' | tr -d '"')
  DESCRIPTION=$(grep '^  description:' "$metadata_file" | head -1 | sed 's/.*description: *//' | tr -d '"')
  SOURCE_TYPE=$(grep '^    type:' "$metadata_file" | head -1 | sed 's/.*type: *//' | tr -d '"')
  SOURCE_URL=$(grep '^    url:' "$metadata_file" | head -1 | sed 's/.*url: *//' | tr -d '"')

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

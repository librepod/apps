#!/bin/bash
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

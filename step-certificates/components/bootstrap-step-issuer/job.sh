#!/bin/bash

set -e

echo "========================================="
echo "StepIssuer Bootstrap Script"
echo "========================================="

# Validate required environment variables
required_vars=(
  "CA_URL"
  "CA_PROVISIONER_NAME"
  "STEPISSUER_NAME"
  "STEPISSUER_NAMESPACE"
  "ROOT_CA_CERT_PATH"
  "CA_CONFIG_PATH"
  "PROVISIONER_PASSWORD_PATH"
  "SECRET_NAME"
)

for var in "${required_vars[@]}"; do
  if [ -z "${!var}" ]; then
    echo "Error: Required variable $var is not set"
    exit 1
  fi
done

echo "CA URL: ${CA_URL}"
echo "Provisioner Name: ${CA_PROVISIONER_NAME}"
echo "StepIssuer Name: ${STEPISSUER_NAME}"
echo "StepIssuer Namespace: ${STEPISSUER_NAMESPACE}"

# Function to wait for file to exist with timeout
wait_for_file() {
  local file=$1
  local timeout=${2:-300}
  local elapsed=0

  echo "Waiting for file: ${file}"

  while [ ! -f "${file}" ]; do
    if [ $elapsed -ge $timeout ]; then
      echo "Timeout waiting for file: ${file}"
      exit 1
    fi
    sleep 2
    elapsed=$((elapsed + 2))
    echo "Waiting... (${elapsed}s)"
  done

  echo "File found: ${file}"
}

# Wait for step-ca to be initialized
echo ""
echo "Checking if step-certificates has been initialized..."

wait_for_file "${ROOT_CA_CERT_PATH}"
wait_for_file "${CA_CONFIG_PATH}"
wait_for_file "${PROVISIONER_PASSWORD_PATH}"

echo "✓ All required files found"

# Extract and base64-encode the root CA certificate
echo ""
echo "Extracting root CA certificate..."
CA_BUNDLE=$(base64 -w 0 "${ROOT_CA_CERT_PATH}")
echo "✓ Root CA certificate extracted and base64-encoded"

# Parse ca.json to get the provisioner kid
echo ""
echo "Parsing CA configuration for provisioner kid..."
PROVISIONER_KID=$(jq -r '.authority.provisioners[] | select(.name == "'"${CA_PROVISIONER_NAME}"'") | .key.kid' "${CA_CONFIG_PATH}")

if [ -z "${PROVISIONER_KID}" ] || [ "${PROVISIONER_KID}" == "null" ]; then
  echo "Error: Could not find provisioner '${CA_PROVISIONER_NAME}' in CA config"
  echo "Available provisioners:"
  jq -r '.authority.provisioners[] | .name' "${CA_CONFIG_PATH}" | sed 's/^/  - /'
  exit 1
fi

echo "✓ Provisioner KID: ${PROVISIONER_KID}"

# Read the provisioner password
echo ""
echo "Reading provisioner password..."
PROVISIONER_PASSWORD=$(cat "${PROVISIONER_PASSWORD_PATH}")

if [ -z "${PROVISIONER_PASSWORD}" ]; then
  echo "Error: Provisioner password file is empty"
  exit 1
fi

echo "✓ Provisioner password read"

# Create the provisioner password secret
echo ""
echo "Creating provisioner password secret..."

cat > /tmp/provisioner-secret.yaml <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${STEPISSUER_NAMESPACE}
type: Opaque
data:
  ${SECRET_KEY}: $(echo -n "${PROVISIONER_PASSWORD}" | base64 -w 0)
EOF

# Apply or update the secret
if kubectl get secret "${SECRET_NAME}" -n "${STEPISSUER_NAMESPACE}" &>/dev/null; then
  echo "Secret already exists, updating..."
  kubectl apply -f /tmp/provisioner-secret.yaml
else
  echo "Creating new secret..."
  kubectl apply -f /tmp/provisioner-secret.yaml
fi

echo "✓ Provisioner password secret created/updated"

# Create the StepIssuer resource
echo ""
echo "Creating StepIssuer resource..."

cat > /tmp/step-issuer.yaml <<EOF
apiVersion: certmanager.step.sm/v1beta1
kind: StepIssuer
metadata:
  name: ${STEPISSUER_NAME}
  namespace: ${STEPISSUER_NAMESPACE}
spec:
  url: ${CA_URL}
  caBundle: ${CA_BUNDLE}
  provisioner:
    name: ${CA_PROVISIONER_NAME}
    kid: ${PROVISIONER_KID}
    passwordRef:
      name: ${SECRET_NAME}
      key: ${SECRET_KEY}
EOF

# Apply or update the StepIssuer
if kubectl get stepissuer "${STEPISSUER_NAME}" -n "${STEPISSUER_NAMESPACE}" &>/dev/null; then
  echo "StepIssuer already exists, updating..."
  kubectl apply -f /tmp/step-issuer.yaml
else
  echo "Creating new StepIssuer..."
  kubectl apply -f /tmp/step-issuer.yaml
fi

echo "✓ StepIssuer resource created/updated"

# Wait for StepIssuer to be ready
echo ""
echo "Waiting for StepIssuer to be ready..."
TIMEOUT=120
ELAPSED=0

while [ $ELAPSED -lt $TIMEOUT ]; do
  READY=$(kubectl get stepissuer "${STEPISSUER_NAME}" -n "${STEPISSUER_NAMESPACE}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')

  if [ "${READY}" == "True" ]; then
    echo "✓ StepIssuer is ready!"
    echo ""
    echo "========================================="
    echo "StepIssuer Bootstrap Complete!"
    echo "========================================="
    echo ""
    echo "StepIssuer Details:"
    kubectl get stepissuer "${STEPISSUER_NAME}" -n "${STEPISSUER_NAMESPACE}" -o yaml
    exit 0
  fi

  sleep 3
  ELAPSED=$((ELAPSED + 3))
  echo "Waiting for StepIssuer to be ready... (${ELAPSED}s)"
done

echo "Error: Timeout waiting for StepIssuer to be ready"
echo "Current status:"
kubectl get stepissuer "${STEPISSUER_NAME}" -n "${STEPISSUER_NAMESPACE}" -o yaml
exit 1

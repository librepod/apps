#!/bin/bash

# This script bootstraps the Step CA resources for cert-manager integration.
# It creates ConfigMaps and Secrets from the Step CA PVC data.

set -e

echo "Welcome to Step CA resource bootstrapper."

# Download kubectl if not already available
if ! command -v kubectl &> /dev/null; then
  echo -e "\e[1mDownloading kubectl...\e[0m"
  cd /tmp
  KUBECTL_VERSION=$(curl -L -s https://dl.k8s.io/release/stable.txt)
  curl -LO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl"
  chmod +x kubectl
  export PATH=/tmp:$PATH
  cd -
  echo "kubectl downloaded successfully."
fi

# assert_variable exists if the given variable is not set.
function assert_variable () {
  if [ -z "$1" ];
  then
    echo "Error: variable $2 has not been set."
    exit 1
  fi
}

# check required variables
assert_variable "$STEPISSUER_NAMESPACE" "STEPISSUER_NAMESPACE"
assert_variable "$STEPPATH" "STEPPATH"

# Define paths
CA_CONFIG_DIR="${STEPPATH}/config"
CA_CERTS_DIR="${STEPPATH}/certs"
CA_SECRETS_DIR="${STEPPATH}/secrets"
CA_PASSWORD_FILE="${CA_SECRETS_DIR}/passwords/password"
CA_PROVISIONER_PASSWORD_FILE="${CA_SECRETS_DIR}/certificate-issuer/password"

echo -e "\e[1mChecking CA initialization...\e[0m"

# Verify the CA is initialized by checking for required files
REQUIRED_FILES=(
  "${CA_CONFIG_DIR}/ca.json"
  "${CA_CONFIG_DIR}/defaults.json"
  "${CA_CERTS_DIR}/root_ca.crt"
  "${CA_CERTS_DIR}/intermediate_ca.crt"
  "${CA_PASSWORD_FILE}"
)

for file in "${REQUIRED_FILES[@]}"; do
  if [ ! -f "$file" ]; then
    echo "Error: Required file not found at $file"
    echo "The Step CA must be initialized before bootstrapping resources."
    exit 1
  fi
done

# Check for private keys
if [ ! -f "${CA_SECRETS_DIR}/root_ca_key" ] && [ ! -f "${CA_SECRETS_DIR}/intermediate_ca_key" ]; then
  echo "Warning: No CA private keys found in ${CA_SECRETS_DIR}"
fi

echo -e "\e[1mCreating ConfigMap: step-certificates-config...\e[0m"

# Create ConfigMap for config files (ca.json and defaults.json)
kubectl create configmap step-certificates-config \
  --from-file=ca.json="${CA_CONFIG_DIR}/ca.json" \
  --from-file=defaults.json="${CA_CONFIG_DIR}/defaults.json" \
  --namespace="$STEPISSUER_NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "ConfigMap step-certificates-config created/updated."

echo -e "\e[1mCreating ConfigMap: step-certificates-certs...\e[0m"

# Create ConfigMap for certificates (root_ca.crt and intermediate_ca.crt)
kubectl create configmap step-certificates-certs \
  --from-file=root_ca.crt="${CA_CERTS_DIR}/root_ca.crt" \
  --from-file=intermediate_ca.crt="${CA_CERTS_DIR}/intermediate_ca.crt" \
  --namespace="$STEPISSUER_NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "ConfigMap step-certificates-certs created/updated."

echo -e "\e[1mReading CA password...\e[0m"

# Read the CA password
CA_PASSWORD=$(cat "$CA_PASSWORD_FILE")

echo -e "\e[1mCreating Secret: step-certificates-ca-password...\e[0m"

# Create Secret for CA password
kubectl create secret generic step-certificates-ca-password \
  --from-literal=password="$CA_PASSWORD" \
  --namespace="$STEPISSUER_NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Secret step-certificates-ca-password created/updated."

echo -e "\e[1mCreating Secret: step-certificates-secrets...\e[0m"

# Create Secret for private keys (if they exist)
SECRET_ARGS=()
if [ -f "${CA_SECRETS_DIR}/root_ca_key" ]; then
  SECRET_ARGS+=("--from-file=root_ca_key=${CA_SECRETS_DIR}/root_ca_key")
fi
if [ -f "${CA_SECRETS_DIR}/intermediate_ca_key" ]; then
  SECRET_ARGS+=("--from-file=intermediate_ca_key=${CA_SECRETS_DIR}/intermediate_ca_key")
fi

if [ ${#SECRET_ARGS[@]} -gt 0 ]; then
  kubectl create secret generic step-certificates-secrets \
    "${SECRET_ARGS[@]}" \
    --namespace="$STEPISSUER_NAMESPACE" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "Secret step-certificates-secrets created/updated."
else
  echo "Warning: No private keys found, skipping step-certificates-secrets creation."
fi

echo -e "\e[1mCreating Secret: step-certificates-certificate-issuer-password...\e[0m"

# Create Secret for certificate-issuer password (same as CA password)
kubectl create secret generic step-certificates-certificate-issuer-password \
  --from-literal=password="$CA_PASSWORD" \
  --namespace="$STEPISSUER_NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Secret step-certificates-certificate-issuer-password created/updated."

echo -e "\e[1mReading provisioner password...\e[0m"

# Read the provisioner password (JWK provisioner key is encrypted with this)
CA_PROVISIONER_PASSWORD=$(cat "$CA_PROVISIONER_PASSWORD_FILE")

echo -e "\e[1mCreating Secret: step-certificates-provisioner-password...\e[0m"

# Create Secret for provisioner password
kubectl create secret generic step-certificates-provisioner-password \
  --from-literal=password="$CA_PROVISIONER_PASSWORD" \
  --namespace="$STEPISSUER_NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Secret step-certificates-provisioner-password created/updated."

echo
echo -e "\e[1mStep CA resource bootstrap complete!\e[0m"
echo
echo "Created resources in namespace: $STEPISSUER_NAMESPACE"
echo "  - ConfigMap: step-certificates-config"
echo "  - ConfigMap: step-certificates-certs"
echo "  - Secret: step-certificates-ca-password"
echo "  - Secret: step-certificates-secrets"
echo "  - Secret: step-certificates-certificate-issuer-password"
echo "  - Secret: step-certificates-provisioner-password"
echo

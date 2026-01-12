#!/bin/bash

# This script bootstraps the StepIssuer resource for cert-manager.
# It runs after the Step CA is initialized and creates a StepIssuer custom
# resource that enables cert-manager to issue certificates using Step CA.

set -e

echo "Welcome to StepIssuer bootstrapper."

# assert_variable exists if the given variable is not set.
function assert_variable () {
  if [ -z "$1" ];
  then
    echo "Error: variable $2 has not been set."
    exit 1
  fi
}

# check required variables
assert_variable "$CA_URL" "CA_URL"
assert_variable "$CA_PROVISIONER_NAME" "CA_PROVISIONER_NAME"
assert_variable "$STEPISSUER_NAME" "STEPISSUER_NAME"
assert_variable "$STEPISSUER_NAMESPACE" "STEPISSUER_NAMESPACE"
assert_variable "$STEPPATH" "STEPPATH"
assert_variable "$ROOT_CA_CERT_PATH" "ROOT_CA_CERT_PATH"
assert_variable "$CA_CONFIG_PATH" "CA_CONFIG_PATH"
assert_variable "$PROVISIONER_PASSWORD_PATH" "PROVISIONER_PASSWORD_PATH"
assert_variable "$SECRET_NAME" "SECRET_NAME"
assert_variable "$SECRET_KEY" "SECRET_KEY"

echo -e "\e[1mChecking CA initialization...\e[0m"

# Verify the CA is initialized
if [ ! -f "$CA_CONFIG_PATH" ]; then
  echo "Error: CA config not found at $CA_CONFIG_PATH"
  echo "The Step CA must be initialized before creating the StepIssuer."
  exit 1
fi

if [ ! -f "$ROOT_CA_CERT_PATH" ]; then
  echo "Error: Root CA certificate not found at $ROOT_CA_CERT_PATH"
  exit 1
fi

if [ ! -f "$PROVISIONER_PASSWORD_PATH" ]; then
  echo "Error: Provisioner password not found at $PROVISIONER_PASSWORD_PATH"
  exit 1
fi

echo -e "\e[1mReading CA material...\e[0m"

# Read the provisioner password
PROVISIONER_PASSWORD=$(cat "$PROVISIONER_PASSWORD_PATH")

# Read the root CA certificate
ROOT_CA_CERT=$(cat "$ROOT_CA_CERT_PATH")

# Get the CA fingerprint
FINGERPRINT=$(step certificate fingerprint "$ROOT_CA_CERT_PATH")

echo "CA Fingerprint: ${FINGERPRINT}"

echo -e "\e[1mCreating Kubernetes Secret...\e[0m"

# Create the secret with provisioner password
kubectl create secret generic "$SECRET_NAME" \
  --from-literal="$SECRET_KEY=$PROVISIONER_PASSWORD" \
  --namespace="$STEPISSUER_NAMESPACE" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Secret $SECRET_NAME created/updated in namespace $STEPISSUER_NAMESPACE"

echo -e "\e[1mCreating StepIssuer resource...\e[0m"

# Create the StepIssuer manifest
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.step.sm/v1beta1
kind: StepIssuer
metadata:
  name: $STEPISSUER_NAME
  namespace: $STEPISSUER_NAMESPACE
spec:
  url: $CA_URL
  provisioner:
    name: $CA_PROVISIONER_NAME
    keyRef:
      name: $SECRET_NAME
      key: $SECRET_KEY
    passwordRef:
      name: $SECRET_NAME
      key: $SECRET_KEY
  caBundle: |
$(echo "$ROOT_CA_CERT" | sed 's/^/    /')
EOF

echo
echo -e "\e[1mStepIssuer bootstrap complete!\e[0m"
echo
echo "StepIssuer: $STEPISSUER_NAME"
echo "Namespace: $STEPISSUER_NAMESPACE"
echo "CA URL: $CA_URL"
echo "Provisioner: $CA_PROVISIONER_NAME"
echo

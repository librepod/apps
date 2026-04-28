#!/bin/bash

# Step CA PVC-based init container script
# Initializes the CA on the PVC before the main container starts

echo "Welcome to Step Certificates initialization (initContainer mode)."

STEPPATH=/home/step

# assert_variable exists if the given variable is not set.
function assert_variable () {
  if [ -z "$1" ];
  then
    echo "Error: variable $1 has not been set."
    exit 1
  fi
}

# check required variables
assert_variable "$CA_URL"
assert_variable "$CA_NAME"
assert_variable "$CA_DNS_1"
assert_variable "$CA_ADDRESS"
assert_variable "$CA_DEFAULT_PROVISIONER"

# check required tools
if ! command -v jq &>/dev/null; then
  echo "Error: jq is required but not found in the container image."
  echo "This is unexpected — jq should be present in the step-ca image."
  echo "Please report this issue or update the init container image."
  exit 1
fi

# set certificate duration defaults (90 days)
CA_DEFAULT_TLS_DURATION="${CA_DEFAULT_TLS_DURATION:-2160h}"
CA_MAX_TLS_DURATION="${CA_MAX_TLS_DURATION:-${CA_DEFAULT_TLS_DURATION}}"

# generate password if necessary
CA_PASSWORD=${CA_PASSWORD:-$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 32 ; echo '')}
CA_PROVISIONER_PASSWORD=${CA_PROVISIONER_PASSWORD:-$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 32 ; echo '')}

echo -e "\e[1mChecking PVC mount point...\e[0m"

# Verify the PVC is mounted
if [ ! -d "$STEPPATH" ]; then
  echo "Error: $STEPPATH directory does not exist. PVC may not be mounted."
  exit 1
fi

# Check if already initialized (don't overwrite existing CA)
if [ -f "$STEPPATH/config/ca.json" ]; then
  echo -e "\e[1mCA already initialized at $STEPPATH/config/ca.json\e[0m"
  echo "Skipping initialization. Existing CA will be used."
  exit 0
fi

echo -e "\e[1mInitializing new Step CA...\e[0m"

# Setting this here on purpose, after the above section which explicitly checks
# for and handles exit errors.
set -e

TMP_CA_PASSWORD=$(mktemp /tmp/stepca.XXXXXX)
TMP_CA_PROVISIONER_PASSWORD=$(mktemp /tmp/stepca.XXXXXX)

echo $CA_PASSWORD > $TMP_CA_PASSWORD
echo $CA_PROVISIONER_PASSWORD > $TMP_CA_PROVISIONER_PASSWORD

step ca init \
  --name "$CA_NAME" \
  --dns "$CA_DNS_1" \
  --dns "$CA_DNS_2" \
  --dns "$CA_DNS_3" \
  --dns "$CA_DNS_4" \
  --deployment-type standalone \
  --address "$CA_ADDRESS" \
  --password-file "$TMP_CA_PASSWORD" \
  --provisioner "$CA_DEFAULT_PROVISIONER" \
  --provisioner-password-file "$TMP_CA_PROVISIONER_PASSWORD" \
  --with-ca-url "$CA_URL" \
  --no-db

rm -f $TMP_CA_PASSWORD $TMP_CA_PROVISIONER_PASSWORD

# Patch ca.json with extended certificate durations
echo -e "\e[1mPatching ca.json certificate durations...\e[0m"
TMP_CA_JSON=$(mktemp /tmp/ca.json.XXXXXX)
jq --arg default "$CA_DEFAULT_TLS_DURATION" --arg max "$CA_MAX_TLS_DURATION" \
  '.authority.claims.defaultTLSCertDuration = $default |
   .authority.claims.maxTLSCertDuration = $max' \
  "$STEPPATH/config/ca.json" > "$TMP_CA_JSON"
mv "$TMP_CA_JSON" "$STEPPATH/config/ca.json"
echo "Certificate duration set: default=${CA_DEFAULT_TLS_DURATION}, max=${CA_MAX_TLS_DURATION}"

# Write passwords to files for the main container to use
mkdir -p "$STEPPATH/secrets/passwords"
mkdir -p "$STEPPATH/secrets/certificate-issuer"
echo -n "$CA_PASSWORD" > "$STEPPATH/secrets/passwords/password"
echo -n "$CA_PROVISIONER_PASSWORD" > "$STEPPATH/secrets/certificate-issuer/password"

echo
echo -e "\e[1mStep Certificates initialized on PVC!\e[0m"
echo
echo "CA URL: ${CA_URL}"
echo "Data written to: ${STEPPATH}"
echo "CA password file: ${STEPPATH}/secrets/passwords/password"
echo "Issuer password file: ${STEPPATH}/secrets/certificate-issuer/password"
echo

FINGERPRINT=$(step certificate fingerprint $STEPPATH/certs/root_ca.crt)
echo "CA Fingerprint: ${FINGERPRINT}"

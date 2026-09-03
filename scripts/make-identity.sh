#!/bin/bash
# Creates a self-signed code-signing identity named "LocalLoom Dev" in your login
# keychain. Run once. No GUI, no sudo, no Apple Developer account.
#
# Why: an ad-hoc signature's designated requirement is the binary's cdhash, so every
# rebuild looks like a brand-new app and macOS resets the Screen Recording grant. A
# self-signed certificate leaf gives a stable designated requirement, so the grant
# survives rebuilds.
set -euo pipefail

NAME="${1:-LocalLoom Dev}"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
WORK="$(mktemp -d)"
PASSWORD="localloom"   # must be non-empty: an empty password makes `security import` fail
trap 'rm -rf "$WORK"' EXIT

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "Identity \"$NAME\" already exists. Nothing to do."
  exit 0
fi

cat > "$WORK/cert.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
CNF

echo "==> generating self-signed certificate"
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/cert.key" -out "$WORK/cert.crt" -config "$WORK/cert.cnf" 2>/dev/null

# OpenSSL 3 defaults produce a PKCS#12 that `security import` rejects with
# "MAC verification failed during PKCS12 import (wrong password?)". The legacy
# SHA1/3DES algorithms below are required, as is a non-empty password.
echo "==> exporting PKCS#12"
openssl pkcs12 -export -legacy \
  -macalg sha1 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES \
  -inkey "$WORK/cert.key" -in "$WORK/cert.crt" \
  -name "$NAME" -out "$WORK/cert.p12" -passout "pass:$PASSWORD"

echo "==> importing into login keychain"
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "$PASSWORD" -A -T /usr/bin/codesign

# Load-bearing: without this the certificate is untrusted and
# `security find-identity -v -p codesigning` reports 0 valid identities.
echo "==> marking the certificate as a trusted code-signing root"
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.crt"

echo
security find-identity -v -p codesigning | grep "$NAME" \
  && echo "Done. scripts/build.sh will now pick this identity up automatically." \
  || { echo "FAILED: identity not valid after import."; exit 1; }

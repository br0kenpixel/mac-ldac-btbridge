#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Creates a self-signed code-signing certificate, "BTBridge Local Signing", in the
# login keychain. The Makefile signs the app with it when present, so macOS keeps the
# "System Audio Recording" permission across rebuilds (ad-hoc signatures change on
# every build and would ask again each time).
#
# The private key is only usable by /usr/bin/codesign and is trusted by nothing but
# this machine's TCC. Remove it with:
#   security delete-identity -c "BTBridge Local Signing"
set -eu

NAME="BTBridge Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning | grep -q "\"$NAME\""; then
    echo "\"$NAME\" already exists."
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/cert.cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

PASS=$(/usr/bin/openssl rand -hex 16)
/usr/bin/openssl req -new -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$TMP/cert.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -out "$TMP/cert.p12" -passout "pass:$PASS"
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$PASS" -T /usr/bin/codesign >/dev/null

echo "Created \"$NAME\". Rebuild with: make clean && make"

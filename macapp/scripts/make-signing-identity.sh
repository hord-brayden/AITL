#!/bin/bash
# Creates a local, self-signed code-signing identity "AITL Bridge Developer" in the login keychain (once).
# Signing with a stable identity keeps macOS privacy grants (Accessibility, Full Disk Access, Bluetooth) across rebuilds;
# ad-hoc signatures change with every build and lose them.
set -euo pipefail
NAME="AITL Bridge Developer"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then echo "identity exists: $NAME"; exit 0; fi
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cat > "$T/ext.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $NAME
O = Caeruli Obscuri Laboratorium
[v3]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
subjectKeyIdentifier = hash
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$T/key.pem" -out "$T/cert.pem" -days 3650 -config "$T/ext.cnf" 2>/dev/null
openssl pkcs12 -export -out "$T/id.p12" -inkey "$T/key.pem" -in "$T/cert.pem" -passout pass:aitl -legacy 2>/dev/null || openssl pkcs12 -export -out "$T/id.p12" -inkey "$T/key.pem" -in "$T/cert.pem" -passout pass:aitl
KC="$HOME/Library/Keychains/login.keychain-db"
security import "$T/id.p12" -k "$KC" -P aitl -T /usr/bin/codesign -T /usr/bin/security >/dev/null
# trust it for code signing at user level (may show a macOS authentication dialog once)
security add-trusted-cert -p codeSign -k "$KC" "$T/cert.pem" 2>/dev/null || security add-trusted-cert -r trustRoot -p codeSign -k "$KC" "$T/cert.pem"
# let codesign use the key without a prompt
security set-key-partition-list -S apple-tool:,apple: -s -k "" "$KC" >/dev/null 2>&1 || true
security find-identity -v -p codesigning | grep "$NAME" && echo "created: $NAME"

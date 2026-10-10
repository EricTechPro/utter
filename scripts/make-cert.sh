#!/bin/zsh
# Creates a self-signed "Utter Local Signing" code-signing identity in the login keychain.
# A stable identity means macOS keeps the Accessibility permission across rebuilds.
set -euo pipefail
NAME="Utter Local Signing"
if security find-certificate -c "$NAME" ~/Library/Keychains/login.keychain-db >/dev/null 2>&1; then
  echo "Identity already exists"; exit 0
fi
TMP=$(mktemp -d)
cat > "$TMP/cfg" <<CFG
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CFG
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cfg" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" -passout pass:utter -name "$NAME"
security import "$TMP/id.p12" -k ~/Library/Keychains/login.keychain-db -P utter -T /usr/bin/codesign
rm -rf "$TMP"
echo "Created $NAME"

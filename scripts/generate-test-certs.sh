#!/usr/bin/env bash
# Generates the test PKI in Tests/SwiftySMTPClientTests/Fixtures (tests only, checked in).
set -euo pipefail
OUT="$(cd "$(dirname "$0")/.." && pwd)/Tests/SwiftySMTPClientTests/Fixtures"
mkdir -p "$OUT"
cd "$OUT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
  -keyout "$TMP/ca.key" -out ca.pem -subj "/CN=SwiftySMTPClient Test CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash"

issue() { # name CN SAN
  local name="$1" cn="$2" san="$3"
  openssl req -newkey rsa:2048 -nodes -sha256 -keyout "$name.key" -out "$TMP/$name.csr" -subj "/CN=$cn"
  cat > "$TMP/$name.ext" <<EXT
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=$san
authorityKeyIdentifier=keyid
subjectKeyIdentifier=hash
EXT
  openssl x509 -req -in "$TMP/$name.csr" -CA ca.pem -CAkey "$TMP/ca.key" -CAcreateserial -CAserial "$TMP/ca.srl" \
    -out "$name.pem" -days 3650 -sha256 -extfile "$TMP/$name.ext"
}

issue localhost localhost "DNS:localhost,IP:127.0.0.1"
issue wrong wrong.example "DNS:wrong.example"
openssl verify -CAfile ca.pem localhost.pem wrong.pem

#!/bin/sh
# Creates a long-lived private CA, then issues the first short-lived leaf from it.
set -eu

CERT_DIR=${1:-$(dirname "$0")/../certs}

if [ -e "$CERT_DIR/ca.key" ]; then
  echo "$CERT_DIR/ca.key already exists; refusing to replace the CA" >&2
  exit 1
fi

mkdir -p "$CERT_DIR"
EXT=$(mktemp)
trap 'rm -f "$EXT"' EXIT

cat > "$EXT" <<'CNF'
[req]
distinguished_name = dn
prompt = no
[dn]
CN = Majula Spike CA
[v3_ca]
basicConstraints = critical,CA:true
keyUsage = critical,keyCertSign,cRLSign
subjectKeyIdentifier = hash
CNF

openssl ecparam -name prime256v1 -genkey -noout -out "$CERT_DIR/ca.key"
chmod 600 "$CERT_DIR/ca.key"
openssl req -x509 -new -key "$CERT_DIR/ca.key" -days 3650 -sha256 \
  -config "$EXT" -extensions v3_ca -out "$CERT_DIR/ca.crt"

sh "$(dirname "$0")/rotate-leaf.sh" "$CERT_DIR"

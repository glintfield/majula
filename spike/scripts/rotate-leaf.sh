#!/bin/sh
# Issues a fresh one-day leaf from the existing CA; never touches ca.key or ca.crt.
set -eu

CERT_DIR=${1:-$(dirname "$0")/../certs}

if [ ! -e "$CERT_DIR/ca.key" ] || [ ! -e "$CERT_DIR/ca.crt" ]; then
  echo "no CA in $CERT_DIR; run init-ca.sh first" >&2
  exit 1
fi

EXT=$(mktemp)
CSR=$(mktemp)
trap 'rm -f "$EXT" "$CSR" "$CERT_DIR/leaf.key.new" "$CERT_DIR/leaf.crt.new"' EXIT

cat > "$EXT" <<'CNF'
subjectAltName = DNS:localhost,IP:127.0.0.1,IP:10.0.2.2
extendedKeyUsage = serverAuth
basicConstraints = CA:FALSE
keyUsage = critical,digitalSignature
CNF

openssl ecparam -name prime256v1 -genkey -noout -out "$CERT_DIR/leaf.key.new"
chmod 600 "$CERT_DIR/leaf.key.new"
openssl req -new -key "$CERT_DIR/leaf.key.new" -subj "/CN=localhost" -out "$CSR"
openssl x509 -req -in "$CSR" -CA "$CERT_DIR/ca.crt" -CAkey "$CERT_DIR/ca.key" \
  -set_serial "0x$(openssl rand -hex 16)" -days 1 -sha256 -extfile "$EXT" \
  -out "$CERT_DIR/leaf.crt.new"

mv "$CERT_DIR/leaf.key.new" "$CERT_DIR/leaf.key"
mv "$CERT_DIR/leaf.crt.new" "$CERT_DIR/leaf.crt"

openssl x509 -noout -fingerprint -sha256 -in "$CERT_DIR/leaf.crt"

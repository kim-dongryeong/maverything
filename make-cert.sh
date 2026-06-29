#!/bin/bash
# Create a stable self-signed code-signing certificate in the login keychain so
# that Full Disk Access (TCC) grants STICK across rebuilds. With ad-hoc signing
# the cdhash changes every build and the FDA grant is lost; a stable signing
# identity keeps the TCC designated requirement constant.
set -euo pipefail
CN="Maverything Dev Cert"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CN"; then
    echo "✓ '$CN' already exists in the keychain."
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cfg" <<EOF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$CN
[ext]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF

echo "▸ generating self-signed code-signing cert…"
openssl req -x509 -newkey rsa:2048 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -days 3650 -config "$WORK/cfg" 2>/dev/null
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/id.p12" -passout pass:mav -name "$CN" 2>/dev/null

echo "▸ importing into login keychain (-A lets codesign use the key without prompting)…"
security import "$WORK/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P mav -A

echo "▸ verifying…"
security find-identity -v -p codesigning | grep "$CN" || { echo "✗ not found after import"; exit 1; }
echo "✓ created '$CN'. Build with:  MAVERYTHING_SIGN_ID=\"$CN\" ./build.sh"

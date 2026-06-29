#!/bin/bash
# Create a stable self-signed code-signing identity in a DEDICATED keychain (known
# password) so codesign can use it headlessly and TCC grants (Full Disk Access,
# Accessibility) stick across rebuilds. Uses a separate keychain so your login
# password is never needed and the login keychain stays clean.
set -uo pipefail
CN="Maverything Dev Cert"
KC="$HOME/Library/Keychains/maverything-signing.keychain-db"
PW="mav"

echo "▸ cleaning up previous attempts…"
# remove dupes accidentally added to the login keychain by earlier runs (best-effort)
for _ in 1 2 3 4 5; do security delete-certificate -c "$CN" >/dev/null 2>&1 || break; done
security delete-keychain "$KC" >/dev/null 2>&1 || true

echo "▸ creating dedicated signing keychain…"
security create-keychain -p "$PW" "$KC" || { echo "✗ create-keychain failed"; exit 1; }
security set-keychain-settings "$KC"            # no auto-lock timeout
security unlock-keychain -p "$PW" "$KC"

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
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
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -days 3650 -config "$WORK/cfg" || { echo "✗ openssl req failed"; exit 1; }
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -out "$WORK/id.p12" \
    -passout "pass:$PW" -name "$CN" || { echo "✗ openssl pkcs12 failed"; exit 1; }

echo "▸ importing + authorizing codesign to use the key (partition list)…"
security import "$WORK/id.p12" -k "$KC" -P "$PW" -A -T /usr/bin/codesign || { echo "✗ import failed"; exit 1; }
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null 2>&1

echo "▸ adding the signing keychain to the search list…"
EXISTING=$(security list-keychains -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')
# shellcheck disable=SC2086
security list-keychains -d user -s "$KC" $EXISTING

echo "▸ self-test: signing a throwaway binary…"
cp /bin/echo "$WORK/echobin"
if codesign --force -s "$CN" --keychain "$KC" "$WORK/echobin" 2>"$WORK/err"; then
    echo ""
    echo "✓ SUCCESS — '$CN' can sign. Tell Claude; builds will use it and your"
    echo "  Full Disk Access / Accessibility grants will persist across rebuilds."
else
    echo "✗ codesign self-test failed:"; cat "$WORK/err"; exit 1
fi

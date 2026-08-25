#!/bin/bash
# One-time setup: creates a self-signed code-signing certificate in your login
# keychain so SonosController.app has a STABLE signing identity across rebuilds.
# Without this, every rebuild gets an ad-hoc identity and macOS silently drops
# the Accessibility grant each time - this is why F7/F8/F9 kept "un-granting."
# Safe/reversible: only adds one cert+key to your own login keychain. To undo,
# open Keychain Access and delete the "SonosController Local Dev" certificate.
set -euo pipefail

# Override any stale OPENSSL_CONF from other tools (e.g. DBngin) pointing at a
# config file that doesn't exist on this machine - we don't need a custom config.
export OPENSSL_CONF=/dev/null

CERT_NAME="SonosController Local Dev"
TMPDIR=$(mktemp -d)

openssl req -x509 -newkey rsa:2048 -keyout "$TMPDIR/key.pem" -out "$TMPDIR/cert.pem" \
  -days 3650 -nodes -subj "/CN=$CERT_NAME" \
  -addext "extendedKeyUsage=codeSigning" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature"

rm -f "$TMPDIR/dev-signing.p12"
if ! openssl pkcs12 -export -out "$TMPDIR/dev-signing.p12" -legacy \
  -inkey "$TMPDIR/key.pem" -in "$TMPDIR/cert.pem" -passout pass:temp123 2>/dev/null; then
    # This openssl build doesn't support -legacy (older versions don't need it).
    openssl pkcs12 -export -out "$TMPDIR/dev-signing.p12" \
      -inkey "$TMPDIR/key.pem" -in "$TMPDIR/cert.pem" -passout pass:temp123
fi

security import "$TMPDIR/dev-signing.p12" -k ~/Library/Keychains/login.keychain-db \
  -P temp123 -T /usr/bin/codesign -A

rm -rf "$TMPDIR"

echo ""
echo "Installed signing identity: $CERT_NAME"
security find-identity -v -p codesigning | grep "$CERT_NAME" || true
echo ""
echo "Now run ./Scripts/build-app.sh again - it will auto-detect this identity."
echo "You'll need to grant Accessibility access ONE more time after this rebuild,"
echo "but it will then persist across all future rebuilds."

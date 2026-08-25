#!/bin/bash
# Run once, after setup-dev-cert.sh. Marks the self-signed dev certificate as
# trusted specifically for code signing (only affects this one cert, only for
# the "is this code signature valid" check - not a system-wide trust change).
# This is likely required for AXIsProcessTrusted() to ever return true for an
# app signed with a self-signed (otherwise-untrusted) certificate.
set -euo pipefail
export OPENSSL_CONF=/dev/null

CERT_NAME="SonosController Local Dev"
TMPDIR=$(mktemp -d)

security find-certificate -c "$CERT_NAME" -p ~/Library/Keychains/login.keychain-db > "$TMPDIR/cert.pem"

security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db "$TMPDIR/cert.pem"

rm -rf "$TMPDIR"

echo ""
echo "Trust added. Verifying:"
security find-identity -v -p codesigning | grep "$CERT_NAME" || echo "(still not showing as valid - see output above for errors)"

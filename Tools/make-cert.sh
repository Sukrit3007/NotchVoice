#!/usr/bin/env bash
#
# Creates the code-signing certificate this app is signed with, once, forever.
#
# READ THIS BEFORE RUNNING IT.
#
# macOS stores the Microphone, Accessibility and Input Monitoring grants against
# the app's *designated requirement*, which for a self-signed build is
#
#     identifier "com.sukrit.notchvoice" and certificate root = H"<this cert>"
#
# — keyed on the certificate, not on the build. That is what lets an update keep
# the permissions the user already granted, and it is also what makes this
# certificate irreplaceable: generate a second one and every existing user's
# permissions reset to nothing, silently, on the update that ships it. They get
# a dictation key that has stopped working and no explanation.
#
# So: run this once, then immediately run Tools/backup-secrets.sh. Do not run
# this again.
#
set -euo pipefail

IDENTITY="Notch Voice Developer"
BUNDLE_ID="com.sukrit.notchvoice"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Refuses rather than adds a second one. Two certificates with the same name is
# the state where `codesign -s "$IDENTITY"` picks whichever it finds first, and
# a release signed with the wrong one resets everybody's permissions.
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "A '$IDENTITY' identity already exists:"
    security find-identity -v -p codesigning | grep "$IDENTITY"
    echo
    echo "Nothing to do. If you genuinely need to replace it, understand first"
    echo "that doing so resets Microphone, Accessibility and Input Monitoring"
    echo "for every existing user, and read the note at the top of this file."
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "Generating a 20-year self-signed code-signing certificate…"

# `extendedKeyUsage=codeSigning` is the load-bearing extension: without it the
# identity does not appear in `security find-identity -p codesigning` and
# codesign refuses it. `CA:false` keeps it a leaf, which is what makes it its
# own root in the designated requirement above.
openssl req -x509 -newkey rsa:2048 -sha256 -days 7300 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj "/CN=$IDENTITY/O=Notch Voice/C=IN" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# The legacy algorithms are not optional. OpenSSL 3 defaults to AES-256 with a
# SHA-256 MAC, and macOS `security import` cannot verify that MAC — it fails
# with "wrong password?" on a file whose password is correct. A throwaway
# password because an empty one fails the same way; the real backup is written
# by Tools/backup-secrets.sh, which asks you for one.
openssl pkcs12 -export -legacy -macalg sha1 \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES \
    -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/identity.p12" -passout pass:import

# `-T /usr/bin/codesign` pre-authorises codesign to use the private key, so
# release builds do not stop halfway waiting on a keychain dialog nobody is
# there to click.
#
# Deliberately NOT touching `security list-keychains`. Setting the search list
# is the obvious-looking way to do this and it replaces the list rather than
# appending to it — which hides every other keychain, including the one holding
# your Apple Development identity.
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P import \
    -T /usr/bin/codesign -T /usr/bin/productsign

# Trusted for code signing only, in the user's own trust domain. No sudo, and
# no statement about anything except this one use.
#
# Non-fatal: signing needs the private key and the codeSigning extension, not a
# trust setting, and this step can prompt. If it fails the release still signs
# correctly — the verification below is what actually decides that.
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem" \
    2>/dev/null || echo "(trust setting skipped — not required for signing)"

# Proves it works now, while the certificate can still be regenerated freely.
# Discovering at the first release that this identity cannot sign is a much
# worse moment to find out.
echo "Checking the identity can actually sign…"
PROBE="$WORK/probe"
mkdir -p "$PROBE/Contents/MacOS"
printf '#!/bin/sh\ntrue\n' > "$PROBE/Contents/MacOS/probe"
chmod +x "$PROBE/Contents/MacOS/probe"
codesign --sign "$IDENTITY" --timestamp=none --force "$PROBE" 2>&1 | sed 's/^/    /'
codesign --verify --strict "$PROBE" || {
    echo "The certificate was created but cannot sign. Nothing has been" >&2
    echo "committed to; delete it in Keychain Access and try again." >&2
    exit 1
}

echo
echo "Done. The identity:"
security find-identity -v -p codesigning | grep "$IDENTITY"
echo
echo "  BACK IT UP NOW, before you ship anything signed with it:"
echo
echo "      Tools/backup-secrets.sh"
echo
echo "  It exists in exactly one place — this Mac's login keychain. Every"
echo "  permission every future user grants is keyed to it, and there is no"
echo "  way to reissue the same one."

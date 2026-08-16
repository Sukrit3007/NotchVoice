#!/usr/bin/env bash
#
# Exports the two secrets this project cannot regenerate.
#
#   1. The code-signing identity. Lose it and a replacement certificate changes
#      the app's designated requirement, which resets Microphone, Accessibility
#      and Input Monitoring for every existing user on the update that ships it.
#
#   2. Sparkle's EdDSA private key. Lose it and no future update can be signed
#      in a way already-installed copies will accept — they check every update
#      against the public key baked into the build they are running. The only
#      recovery is telling everyone to download the app again by hand.
#
# Neither is in the repository and neither can be recovered from it. Run this,
# put the output somewhere that survives this Mac, and verify you can read it.
#
set -euo pipefail

OUT="${1:-$HOME/Desktop/notchvoice-secrets}"
IDENTITY="Notch Voice Developer"

mkdir -p "$OUT"
chmod 700 "$OUT"

echo "Exporting to $OUT"
echo

if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    # Prompts for a password. Chosen by you, not stored anywhere — a passwordless
    # .p12 of a signing identity is a file that signs software as you.
    echo "1/2  Signing identity — you will be asked to set a password."
    security export -k "$HOME/Library/Keychains/login.keychain-db" \
        -t identities -f pkcs12 -o "$OUT/signing-identity.p12"
    echo "     → signing-identity.p12"
else
    echo "1/2  No '$IDENTITY' identity found. Run Tools/make-cert.sh first." >&2
fi

echo
SPARKLE_BIN="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
    -path "*artifacts/sparkle/Sparkle/bin/generate_keys" -print -quit 2>/dev/null || true)"

if [[ -n "$SPARKLE_BIN" ]]; then
    echo "2/2  Sparkle update-signing key."
    "$SPARKLE_BIN" -x "$OUT/sparkle-private-key.txt"
    chmod 600 "$OUT/sparkle-private-key.txt"
    echo "     → sparkle-private-key.txt"
else
    echo "2/2  Sparkle tools not found. Build the app once, then re-run." >&2
fi

echo
echo "Both files are in $OUT."
echo "Copy them somewhere off this Mac, then delete the originals."

#!/usr/bin/env bash
#
# Prints the CHANGELOG section for one version, for `gh release create --notes`.
#
# Reads the changelog rather than asking for notes at release time, so the file
# in the repository and the text on the release page cannot drift — and so that
# writing the changelog entry is what makes the release possible, rather than
# something to catch up on afterwards.
#
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: release-notes.sh <version>}"

# Everything between this version's heading and the next one. Works for both
# `## [0.1.0]` and `## [0.1.0] - 2026-08-16`.
NOTES="$(awk -v v="$VERSION" '
    $0 ~ "^## \\[" v "\\]" { found = 1; next }
    found && /^## / { exit }
    found { print }
' CHANGELOG.md)"

if [[ -z "$(echo "$NOTES" | tr -d '[:space:]')" ]]; then
    echo "error: CHANGELOG.md has no section for $VERSION" >&2
    echo "       add '## [$VERSION]' with what changed, then release again." >&2
    exit 1
fi

echo "$NOTES"
echo "---"
echo
echo "**Installing:** macOS will say it can't verify this app, because it isn't"
echo "notarized. Open **System Settings → Privacy & Security**, scroll down, and"
echo "click **Open Anyway**. Once only."

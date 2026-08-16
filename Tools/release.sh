#!/usr/bin/env bash
#
# Cuts a release: build, sign, package, publish, and tell existing copies.
#
#     Tools/release.sh 0.1.1
#
# Everything after the build is ordered so that nothing points at something
# that does not exist yet: the GitHub release carrying the .dmg is created
# before the appcast that names its URL is pushed. Running apps read the
# appcast, so publishing it early would send everyone at a 404.
#
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:-}"
IDENTITY="Notch Voice Developer"
REPO="Sukrit3007/NotchVoice"
APP_NAME="Notch Voice"
DMG="build/NotchVoice-$VERSION.dmg"

die() { echo "error: $*" >&2; exit 1; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "usage: Tools/release.sh <major.minor.patch>"

# --- Refuse to start if anything the later steps need is missing ------------
# All checked up front. A release that dies after signing but before publishing
# leaves a tag pointing at a version nobody can download.

[[ -z "$(git status --porcelain)" ]] || die "working tree is dirty; commit first"
git rev-parse "v$VERSION" >/dev/null 2>&1 && die "tag v$VERSION already exists"

security find-identity -v -p codesigning | grep -q "$IDENTITY" \
    || die "no '$IDENTITY' signing identity — see Tools/make-cert.sh"

gh auth status >/dev/null 2>&1 || die "gh is not logged in"

SPARKLE_BIN="$(find "$HOME/Library/Developer/Xcode/DerivedData" \
    -path "*artifacts/sparkle/Sparkle/bin" -print -quit 2>/dev/null || true)"
[[ -n "$SPARKLE_BIN" ]] || die "Sparkle tools not found — build the app once first"

xcrun --find metal >/dev/null 2>&1 \
    || die "Metal toolchain missing — run: xcodebuild -downloadComponent MetalToolchain"

# --- Version -----------------------------------------------------------------
# CFBundleVersion has to increase monotonically or Sparkle will not offer the
# update. Derived from the marketing version rather than hand-incremented, so
# the two can never disagree about which build is newer.
IFS=. read -r MAJOR MINOR PATCH <<< "$VERSION"
BUILD=$(( MAJOR * 10000 + MINOR * 100 + PATCH ))

echo "==> $APP_NAME $VERSION (build $BUILD)"

/usr/bin/sed -i '' \
    -e "s/MARKETING_VERSION: \".*\"/MARKETING_VERSION: \"$VERSION\"/" \
    -e "s/CURRENT_PROJECT_VERSION: \".*\"/CURRENT_PROJECT_VERSION: \"$BUILD\"/" \
    project.yml
xcodegen generate >/dev/null

# --- Build -------------------------------------------------------------------
# Signed with the self-signed identity rather than the Apple Development one
# used for local builds. This is the certificate the TCC grants are keyed to —
# see Tools/make-cert.sh — and it is the only one a downloaded copy will ever
# have been signed with.
#
# `-skipPackagePluginValidation` is required by mlx-swift, which ships a build
# tool plugin Xcode will not run unattended.
rm -rf build
xcodebuild build \
    -project NotchVoice.xcodeproj -scheme NotchVoice \
    -configuration Release -destination 'platform=macOS' \
    -derivedDataPath build/dd \
    -skipPackagePluginValidation -skipMacroValidation \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    DEVELOPMENT_TEAM="" \
    OTHER_CODE_SIGN_FLAGS="--timestamp=none" \
    | grep -E "error:|warning:|BUILD" || true

APP="build/dd/Build/Products/Release/$APP_NAME.app"
[[ -d "$APP" ]] || die "build produced no app"

# --- Re-sign Sparkle's nested tools -----------------------------------------
# Xcode signs the app and the framework, but not the bundles *inside* the
# framework — Autoupdate, Updater.app and the two XPC services all come out
# ad-hoc signed. `codesign --verify --deep` still passes, because an ad-hoc
# signature is internally valid; it just is not this app's identity. Sparkle
# launches those tools to install an update, and under a hardened runtime an
# identity mismatch is where that fails.
#
# Inside-out, because a container's seal covers its contents: re-signing a
# parent first would be invalidated by re-signing a child after it.
echo "==> re-signing Sparkle's updater tools"
FW="$APP/Contents/Frameworks/Sparkle.framework"

# Carries each bundle's own entitlements across. Read off the bundle rather than
# hardcoded: Autoupdate ships with `com.apple.application-identifier`, and
# `codesign --force` without `--entitlements` silently drops whatever was there.
resign_nested() {
    local target="$1" ents
    [[ -e "$target" ]] || die "expected Sparkle component missing: $target"
    ents="$(mktemp)"
    codesign -d --entitlements "$ents" --xml "$target" 2>/dev/null || true
    if [[ -s "$ents" ]] && grep -q "<key>" "$ents"; then
        codesign --force --sign "$IDENTITY" --timestamp=none --options runtime \
            --entitlements "$ents" "$target"
    else
        codesign --force --sign "$IDENTITY" --timestamp=none --options runtime "$target"
    fi
    rm -f "$ents"
}

for nested in \
    "$FW/Versions/B/XPCServices/Downloader.xpc" \
    "$FW/Versions/B/XPCServices/Installer.xpc" \
    "$FW/Versions/B/Updater.app" \
    "$FW/Versions/B/Autoupdate" \
    "$FW/Versions/B"
do
    resign_nested "$nested" 2>&1 | sed 's/^/    /'
done

# The app is signed against the checked-in entitlements file rather than what it
# currently carries. Xcode injects `com.apple.security.get-task-allow`, which
# lets any process attach a debugger to the shipped app; signing against the
# file is what takes it back out.
codesign --force --sign "$IDENTITY" --timestamp=none --options runtime \
    --entitlements App/NotchVoice.entitlements "$APP" 2>&1 | sed 's/^/    /'

# Both failures are silent until a user is already affected, so they are checked
# rather than assumed: an ad-hoc updater fails at install time, and a shipped
# get-task-allow is only ever noticed by whoever exploits it.
codesign -dvvv "$FW/Versions/B/Autoupdate" 2>&1 | grep -q "Signature=adhoc" \
    && die "Sparkle's Autoupdate is still ad-hoc signed — updates would fail to install"
codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -q "get-task-allow" \
    && die "get-task-allow is still present — this must not ship"

# --- Verify what was actually signed ----------------------------------------
# Printed, not just checked. The designated requirement is what macOS stores
# the permission grants against, and it must be byte-identical to the previous
# release or every user's Microphone, Accessibility and Input Monitoring reset
# without warning.
echo "==> signature"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/    /'
echo "==> designated requirement (must match the last release exactly)"
codesign -d -r- "$APP" 2>&1 | grep "designated" | sed 's/^/    /'

# --- Package -----------------------------------------------------------------
# hdiutil rather than create-dmg: a dictation app does not need a background
# image, and this is one fewer thing to install before anyone can cut a release.
echo "==> packaging"
STAGE="build/stage"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create -quiet -volname "$APP_NAME" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG"
codesign --sign "$IDENTITY" --timestamp=none "$DMG"

# --- Sign the update ---------------------------------------------------------
# Separate from the code signature and doing a different job: this proves to an
# already-installed copy that the download came from whoever shipped the copy it
# is running. Key read from the login keychain — see Tools/backup-secrets.sh.
echo "==> signing update"
SIG_LINE="$("$SPARKLE_BIN/sign_update" "$DMG")"
echo "    $SIG_LINE"

# --- Publish -----------------------------------------------------------------
# The release goes up first so the URL in the appcast resolves the moment the
# appcast does.
echo "==> publishing"
git add project.yml
git commit -qm "chore: release $VERSION" || true
git tag -a "v$VERSION" -m "$APP_NAME $VERSION"
git push -q origin HEAD --tags

gh release create "v$VERSION" "$DMG" \
    --repo "$REPO" \
    --title "$APP_NAME $VERSION" \
    --notes-file <(Tools/release-notes.sh "$VERSION")

# --- Tell everyone already running it ---------------------------------------
DOWNLOAD_URL="https://github.com/$REPO/releases/download/v$VERSION/$(basename "$DMG")"
python3 Tools/appcast.py \
    --version "$VERSION" \
    --build "$BUILD" \
    --url "$DOWNLOAD_URL" \
    --signature "$SIG_LINE" \
    --appcast appcast.xml

git add appcast.xml
git commit -qm "chore: appcast for $VERSION"
git push -q origin HEAD

echo
echo "==> done — $VERSION is live"
echo "    https://github.com/$REPO/releases/tag/v$VERSION"
echo
echo "    Installed copies will offer it within a day, or immediately from"
echo "    the menu bar via Check for Updates."

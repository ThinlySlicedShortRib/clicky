#!/bin/bash
#
# Builds Clicky from the command line with a stable signature and launches it.
#
#   scripts/build-and-run.sh               build, then relaunch the app
#   scripts/build-and-run.sh --build-only  build, leave any running app alone
#
# macOS permissions are tied to the bundle id plus the signing certificate, so
# they survive rebuilds as long as this identity signs the app.
#
# To try a different model without rebuilding:
#   CLICKY_BRAIN_MODEL=codex scripts/build-and-run.sh

set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SIGNING_IDENTITY="Apple Development: Yi Hsiang Chen (KNT3H5Z889)"
DERIVED_DATA_PATH="$REPOSITORY_ROOT/build/DerivedData"
APP_PATH="$DERIVED_DATA_PATH/Build/Products/Debug/Clicky.app"

# Shared across checkouts so each worktree doesn't clone Sparkle again.
SOURCE_PACKAGES_PATH="$HOME/Library/Caches/clicky-foundation/SourcePackages"

BUILD_ONLY=false
if [[ "${1:-}" == "--build-only" ]]; then
    BUILD_ONLY=true
fi

if ! security find-identity -v -p codesigning | grep -qF "$SIGNING_IDENTITY"; then
    echo "error: signing identity not found in the keychain: $SIGNING_IDENTITY" >&2
    exit 1
fi

echo "Building Clicky (Debug)..."
BUILD_LOG="$(mktemp -t clicky-build)"
if ! xcodebuild \
    -project "$REPOSITORY_ROOT/leanring-buddy.xcodeproj" \
    -scheme leanring-buddy \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_PATH" \
    build >"$BUILD_LOG" 2>&1; then
    grep -E "error:|BUILD FAILED" "$BUILD_LOG" | sort -u | head -40 >&2 || true
    echo "error: build failed, full log at $BUILD_LOG" >&2
    exit 1
fi
rm -f "$BUILD_LOG"

# Refuse to continue with a signature that would reset permissions.
if ! codesign -dr - "$APP_PATH" 2>&1 | grep -qF "$SIGNING_IDENTITY"; then
    echo "error: $APP_PATH is not signed by $SIGNING_IDENTITY" >&2
    exit 1
fi

echo "Built and signed: $APP_PATH"

if [[ "$BUILD_ONLY" == true ]]; then
    exit 0
fi

# Matches on the full path so other copies of Clicky are left alone.
pkill -f "$APP_PATH/Contents/MacOS/Clicky" 2>/dev/null || true
sleep 0.5

OPEN_ARGUMENTS=()
if [[ -n "${CLICKY_BRAIN_MODEL:-}" ]]; then
    OPEN_ARGUMENTS+=(--env "CLICKY_BRAIN_MODEL=$CLICKY_BRAIN_MODEL")
fi

open ${OPEN_ARGUMENTS[@]+"${OPEN_ARGUMENTS[@]}"} "$APP_PATH"
echo "Launched. Logs: log stream --process Clicky, or run the binary directly for stdout."

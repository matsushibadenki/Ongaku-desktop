#!/bin/bash
set -euo pipefail

usage() {
    echo "Usage: $0 [--archive-only|--upload-existing] <version> <build-number>"
}

ARCHIVE_ONLY=0
UPLOAD_EXISTING=0
if [[ "${1:-}" == "--archive-only" ]]; then
    ARCHIVE_ONLY=1
    shift
elif [[ "${1:-}" == "--upload-existing" ]]; then
    UPLOAD_EXISTING=1
    shift
fi

if [[ $# -ne 2 ]]; then
    usage
    exit 64
fi

VERSION="$1"
BUILD_NUMBER="$2"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Version must use semantic version form, for example 1.2.3." >&2
    exit 64
fi
if [[ ! "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
    echo "Build number must be a positive integer." >&2
    exit 64
fi

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/Releases/build"
ARCHIVE_PATH="$BUILD_DIR/OngakuDesktop-AppStore-${VERSION}-${BUILD_NUMBER}.xcarchive"
EXPORT_PATH="$BUILD_DIR/app-store-upload-${VERSION}-${BUILD_NUMBER}"
APP_PATH="$ARCHIVE_PATH/Products/Applications/OngakuDesktop.app"
EXECUTABLE="$APP_PATH/Contents/MacOS/OngakuDesktop"
INFO_PLIST="$APP_PATH/Contents/Info.plist"
ENTITLEMENTS_FILE="$(mktemp "${TMPDIR:-/tmp}/ongaku-app-store-entitlements.XXXXXX")"

cleanup() {
    rm -f -- "$ENTITLEMENTS_FILE"
}
trap cleanup EXIT

mkdir -p "$BUILD_DIR"

if [[ $UPLOAD_EXISTING -eq 0 ]]; then
    xcodebuild archive \
        -project "$ROOT_DIR/OngakuDesktop.xcodeproj" \
        -scheme OngakuDesktopAppStore \
        -configuration Release \
        -destination "generic/platform=macOS" \
        -archivePath "$ARCHIVE_PATH" \
        ARCHS="arm64 x86_64" \
        ONLY_ACTIVE_ARCH=NO \
        MARKETING_VERSION="$VERSION" \
        CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
        CODE_SIGN_STYLE=Automatic \
        DEVELOPMENT_TEAM=3WH28SSRZC \
        -allowProvisioningUpdates
elif [[ ! -d "$ARCHIVE_PATH" ]]; then
    echo "Existing archive was not found: $ARCHIVE_PATH" >&2
    exit 1
fi

if [[ ! -x "$EXECUTABLE" ]]; then
    echo "Archived application executable was not found." >&2
    exit 1
fi

ARCHITECTURES="$(lipo -archs "$EXECUTABLE")"
if [[ " $ARCHITECTURES " != *" arm64 "* || " $ARCHITECTURES " != *" x86_64 "* ]]; then
    echo "Universal Binary verification failed: $ARCHITECTURES" >&2
    exit 1
fi

if find "$APP_PATH" -iname '*Sparkle*' -print -quit | grep -q .; then
    echo "Mac App Store archive unexpectedly contains Sparkle." >&2
    exit 1
fi
if otool -L "$EXECUTABLE" | grep -q Sparkle; then
    echo "Mac App Store executable unexpectedly links Sparkle." >&2
    exit 1
fi

for key in SUFeedURL SUPublicEDKey SUEnableAutomaticChecks; do
    if /usr/libexec/PlistBuddy -c "Print :$key" "$INFO_PLIST" >/dev/null 2>&1; then
        echo "Mac App Store Info.plist unexpectedly contains $key." >&2
        exit 1
    fi
done

codesign --verify --all-architectures --deep --strict --verbose=2 "$APP_PATH"
codesign --display \
    --architecture arm64 \
    --entitlements - \
    --xml \
    "$APP_PATH" > "$ENTITLEMENTS_FILE" 2>/dev/null
if [[ "$(plutil -extract 'com\.apple\.security\.app-sandbox' raw -o - "$ENTITLEMENTS_FILE")" != "true" ]]; then
    echo "Mac App Store archive is not sandboxed." >&2
    exit 1
fi
if /usr/libexec/PlistBuddy \
    -c "Print :com.apple.security.network.server" \
    "$ENTITLEMENTS_FILE" >/dev/null 2>&1; then
    echo "Mac App Store archive unexpectedly includes the network server entitlement." >&2
    exit 1
fi

echo "Mac App Store archive passed distribution checks: $ARCHIVE_PATH"
echo "Architectures: $ARCHITECTURES"

if [[ $ARCHIVE_ONLY -eq 1 ]]; then
    echo "Archive-only mode: upload was skipped."
    exit 0
fi

xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportOptionsPlist "$ROOT_DIR/Releases/AppStoreExportOptions.plist" \
    -exportPath "$EXPORT_PATH" \
    -allowProvisioningUpdates

echo "Upload request completed. Confirm processing in App Store Connect before submitting for review."

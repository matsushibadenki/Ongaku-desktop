#!/bin/bash
set -euo pipefail

usage() {
    echo "Usage: $0 [--local] <version> <build-number>"
}

LOCAL_BUILD=0
if [[ "${1:-}" == "--local" ]]; then
    LOCAL_BUILD=1
    shift
fi

if [[ $# -ne 2 ]]; then
    usage
    exit 64
fi

VERSION="$1"
BUILD_NUMBER="$2"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RELEASES_DIR="$ROOT_DIR/Releases"
BUILD_DIR="$RELEASES_DIR/build"
DIST_DIR="$RELEASES_DIR/dist"
ARCHIVE_PATH="$BUILD_DIR/OngakuDesktop.xcarchive"
APP_PATH="$ARCHIVE_PATH/Products/Applications/OngakuDesktop.app"
ARCHIVE_NAME="OngakuDesktop-${VERSION}-universal.zip"
ZIP_PATH="$DIST_DIR/$ARCHIVE_NAME"
NOTES_PATH="$DIST_DIR/OngakuDesktop-${VERSION}-universal.md"
SPARKLE_ACCOUNT="com.ongaku.desktop"

mkdir -p "$BUILD_DIR" "$DIST_DIR"

if [[ $LOCAL_BUILD -eq 0 ]]; then
    : "${DEVELOPER_ID_APPLICATION:?Set DEVELOPER_ID_APPLICATION to the full Developer ID Application identity}"
    : "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to the Apple Developer team ID}"
    : "${NOTARY_PROFILE:?Set NOTARY_PROFILE to an xcrun notarytool Keychain profile}"
fi

BUILD_ARGUMENTS=(
    -project "$ROOT_DIR/OngakuDesktop.xcodeproj"
    -scheme OngakuDesktop
    -configuration Release
    -destination "generic/platform=macOS"
    -archivePath "$ARCHIVE_PATH"
    -clonedSourcePackagesDirPath "$BUILD_DIR/SourcePackages"
    ARCHS="arm64 x86_64"
    ONLY_ACTIVE_ARCH=NO
    MARKETING_VERSION="$VERSION"
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER"
)

if [[ $LOCAL_BUILD -eq 1 ]]; then
    BUILD_ARGUMENTS+=(CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=)
else
    BUILD_ARGUMENTS+=(
        CODE_SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION"
        CODE_SIGN_STYLE=Manual
        DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"
    )
fi

xcodebuild archive "${BUILD_ARGUMENTS[@]}"

EXECUTABLE="$APP_PATH/Contents/MacOS/OngakuDesktop"
ARCHITECTURES="$(lipo -archs "$EXECUTABLE")"
if [[ " $ARCHITECTURES " != *" arm64 "* || " $ARCHITECTURES " != *" x86_64 "* ]]; then
    echo "Universal Binary verification failed: $ARCHITECTURES" >&2
    exit 1
fi

codesign --verify --deep --strict --verbose=2 "$APP_PATH"

if [[ $LOCAL_BUILD -eq 0 ]]; then
    SUBMISSION_ZIP="$BUILD_DIR/OngakuDesktop-notarization.zip"
    ditto -c -k --keepParent "$APP_PATH" "$SUBMISSION_ZIP"
    xcrun notarytool submit "$SUBMISSION_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
    spctl --assess --type execute --verbose=2 "$APP_PATH"
fi

ditto -c -k --sequesterRsrc --keepParent "$APP_PATH" "$ZIP_PATH"
shasum -a 256 "$ZIP_PATH" > "$ZIP_PATH.sha256"

if [[ ! -f "$NOTES_PATH" ]]; then
    printf '# Ongaku Desktop %s\n\n- Universal macOS build for arm64 and x86_64.\n' "$VERSION" > "$NOTES_PATH"
fi

if [[ $LOCAL_BUILD -eq 0 ]]; then
    SPARKLE_BIN="${SPARKLE_BIN:-$RELEASES_DIR/SparkleTools}"
    GENERATE_APPCAST="$SPARKLE_BIN/generate_appcast"
    if [[ ! -x "$GENERATE_APPCAST" ]]; then
        echo "Sparkle generate_appcast was not found at $GENERATE_APPCAST" >&2
        exit 1
    fi

    "$GENERATE_APPCAST" \
        --account "$SPARKLE_ACCOUNT" \
        --download-url-prefix "https://github.com/matsushibadenki/Ongaku-desktop/releases/download/v${VERSION}/" \
        --link "https://github.com/matsushibadenki/Ongaku-desktop/releases/tag/v${VERSION}" \
        --embed-release-notes \
        -o "$RELEASES_DIR/appcast.xml" \
        "$DIST_DIR"
fi

echo "Release artifact: $ZIP_PATH"
echo "Architectures: $ARCHITECTURES"
if [[ $LOCAL_BUILD -eq 1 ]]; then
    echo "Local ad-hoc build: not signed for distribution and not added to appcast."
fi

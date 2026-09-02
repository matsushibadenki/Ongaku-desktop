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
DMG_NAME="OngakuDesktop-${VERSION}-universal.dmg"
DMG_PATH="$DIST_DIR/$DMG_NAME"
LEGACY_ZIP_PATH="$DIST_DIR/OngakuDesktop-${VERSION}-universal.zip"
NOTES_PATH="$DIST_DIR/OngakuDesktop-${VERSION}-universal.md"
SPARKLE_ACCOUNT="com.ongaku.desktop"
DMG_STAGING_DIR=""

cleanup() {
    if [[ -n "$DMG_STAGING_DIR" && -d "$DMG_STAGING_DIR" ]]; then
        rm -rf -- "$DMG_STAGING_DIR"
    fi
}
trap cleanup EXIT

submit_for_notarization() {
    local artifact_path="$1"
    local result
    local status
    local submission_id

    result="$(xcrun notarytool submit \
        "$artifact_path" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait \
        --output-format json)"
    printf '%s\n' "$result"

    status="$(printf '%s' "$result" | plutil -extract status raw -o - -)"
    if [[ "$status" != "Accepted" ]]; then
        submission_id="$(printf '%s' "$result" | plutil -extract id raw -o - -)"
        echo "Notarization failed with status: $status" >&2
        echo "Inspect the log with: xcrun notarytool log $submission_id --keychain-profile $NOTARY_PROFILE" >&2
        return 1
    fi
}

resign_sparkle_helpers() {
    local sparkle_framework="$APP_PATH/Contents/Frameworks/Sparkle.framework/Versions/B"
    local nested_code
    local nested_code_paths=(
        "$sparkle_framework/Updater.app"
        "$sparkle_framework/Autoupdate"
        "$sparkle_framework/XPCServices/Downloader.xpc"
        "$sparkle_framework/XPCServices/Installer.xpc"
    )

    for nested_code in "${nested_code_paths[@]}"; do
        codesign \
            --force \
            --sign "$DEVELOPER_ID_APPLICATION" \
            --timestamp \
            --preserve-metadata=identifier,entitlements,requirements,flags \
            "$nested_code"
        codesign --verify --strict --verbose=2 "$nested_code"
    done

    codesign \
        --force \
        --sign "$DEVELOPER_ID_APPLICATION" \
        --timestamp \
        --preserve-metadata=identifier,entitlements,requirements,flags \
        "$sparkle_framework"
    codesign \
        --force \
        --sign "$DEVELOPER_ID_APPLICATION" \
        --timestamp \
        --preserve-metadata=identifier,entitlements,requirements,flags \
        "$APP_PATH"
}

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
        OTHER_CODE_SIGN_FLAGS=--timestamp
    )
fi

xcodebuild archive "${BUILD_ARGUMENTS[@]}"

if [[ $LOCAL_BUILD -eq 0 ]]; then
    resign_sparkle_helpers
fi

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
    submit_for_notarization "$SUBMISSION_ZIP"
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
    spctl --assess --type execute --verbose=2 "$APP_PATH"
fi

DMG_STAGING_DIR="$(mktemp -d "$BUILD_DIR/dmg-staging.XXXXXX")"
ditto "$APP_PATH" "$DMG_STAGING_DIR/OngakuDesktop.app"
ln -s /Applications "$DMG_STAGING_DIR/Applications"
hdiutil create \
    -volname "Ongaku Desktop" \
    -srcfolder "$DMG_STAGING_DIR" \
    -fs APFS \
    -format ULFO \
    -ov \
    "$DMG_PATH"

if [[ $LOCAL_BUILD -eq 0 ]]; then
    codesign --force --sign "$DEVELOPER_ID_APPLICATION" --timestamp "$DMG_PATH"
    codesign --verify --verbose=2 "$DMG_PATH"
    submit_for_notarization "$DMG_PATH"
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
fi

shasum -a 256 "$DMG_PATH" > "$DMG_PATH.sha256"

if [[ ! -f "$NOTES_PATH" ]]; then
    printf '# Ongaku Desktop %s\n\n- Universal macOS build for arm64 and x86_64.\n' "$VERSION" > "$NOTES_PATH"
fi

if [[ $LOCAL_BUILD -eq 0 ]]; then
    if [[ -f "$LEGACY_ZIP_PATH" ]]; then
        LEGACY_ARTIFACTS_DIR="$BUILD_DIR/legacy-artifacts"
        mkdir -p "$LEGACY_ARTIFACTS_DIR"
        mv "$LEGACY_ZIP_PATH" "$LEGACY_ARTIFACTS_DIR/"
        if [[ -f "$LEGACY_ZIP_PATH.sha256" ]]; then
            mv "$LEGACY_ZIP_PATH.sha256" "$LEGACY_ARTIFACTS_DIR/"
        fi
    fi

    SPARKLE_BIN="${SPARKLE_BIN:-$RELEASES_DIR/SparkleTools}"
    GENERATE_APPCAST="$SPARKLE_BIN/generate_appcast"
    if [[ ! -x "$GENERATE_APPCAST" ]]; then
        echo "Sparkle generate_appcast was not found at $GENERATE_APPCAST" >&2
        exit 1
    fi

    "$GENERATE_APPCAST" \
        --account "$SPARKLE_ACCOUNT" \
        --versions "$BUILD_NUMBER" \
        --maximum-versions 0 \
        --download-url-prefix "https://github.com/matsushibadenki/Ongaku-desktop/releases/download/v${VERSION}/" \
        --link "https://github.com/matsushibadenki/Ongaku-desktop/releases/tag/v${VERSION}" \
        --embed-release-notes \
        -o "$RELEASES_DIR/appcast.xml" \
        "$DIST_DIR"

    # generate_appcast applies the current download prefix to every full archive
    # present in DIST_DIR. Restore historical DMG URLs to their matching release
    # tags while keeping newly generated delta URLs on the current release.
    sed -i '' -E \
        's#releases/download/v[^/]+/(OngakuDesktop-([0-9]+\.[0-9]+\.[0-9]+)-universal\.dmg)#releases/download/v\2/\1#g' \
        "$RELEASES_DIR/appcast.xml"
fi

echo "Release artifact: $DMG_PATH"
echo "Architectures: $ARCHITECTURES"
if [[ $LOCAL_BUILD -eq 1 ]]; then
    echo "Local ad-hoc DMG: not signed for distribution and not added to appcast."
fi

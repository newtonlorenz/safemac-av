#!/bin/bash

# Build a local ClamAV-GUI DMG. Set SIGNING_IDENTITY to produce a signed DMG,
# and also set NOTARY_PROFILE to submit it with a notarytool Keychain profile.

set -Eeuo pipefail
IFS=$'\n\t'

APP_NAME="ClamAV-GUI"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
APP_PATH="$EXPORT_PATH/$APP_NAME.app"
DMG_PATH="$BUILD_DIR/$APP_NAME.dmg"
TEMP_DMG_DIR="$BUILD_DIR/dmg-contents"
BUILD_LOG="$BUILD_DIR/archive.log"
ENTITLEMENTS_PATH="$PROJECT_DIR/$APP_NAME/ClamAV_GUI.entitlements"

SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

print_step() {
    printf '%s==>%s %s\n' "$GREEN" "$NC" "$1"
}

print_warning() {
    printf '%sWarning:%s %s\n' "$YELLOW" "$NC" "$1" >&2
}

print_error() {
    printf '%sError:%s %s\n' "$RED" "$NC" "$1" >&2
}

fail() {
    print_error "$1"
    exit 1
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "$1 not found. $2"
}

assert_build_path() {
    local target="$1"

    case "$target" in
        "$BUILD_DIR"|"$BUILD_DIR"/*) ;;
        *) fail "Refusing to remove path outside the project build directory: $target" ;;
    esac

    [[ "$target" != "/" && "$target" != "$PROJECT_DIR" ]] \
        || fail "Refusing to remove unsafe path: $target"
}

remove_tree() {
    assert_build_path "$1"
    rm -rf -- "$1"
}

remove_file() {
    assert_build_path "$1"
    rm -f -- "$1"
}

check_requirements() {
    print_step "Checking requirements"
    require_command xcodebuild "Install Xcode from the Mac App Store."
    require_command hdiutil "This script must run on macOS."
    require_command ditto "This script must run on macOS."

    [[ -f "$PROJECT_DIR/$APP_NAME.xcodeproj/project.pbxproj" ]] \
        || fail "Xcode project not found at $PROJECT_DIR/$APP_NAME.xcodeproj"

    if [[ -n "$NOTARY_PROFILE" && -z "$SIGNING_IDENTITY" ]]; then
        fail "NOTARY_PROFILE requires SIGNING_IDENTITY; unsigned builds cannot be notarized."
    fi

    if [[ -n "$SIGNING_IDENTITY" ]]; then
        require_command codesign "Install the Xcode command-line tools."
        require_command security "This script must run on macOS."
        [[ -f "$ENTITLEMENTS_PATH" ]] || fail "Entitlements file not found: $ENTITLEMENTS_PATH"

        security find-identity -v -p codesigning \
            | grep -F -- "$SIGNING_IDENTITY" >/dev/null \
            || fail "Signing identity not found in the Keychain: $SIGNING_IDENTITY"
    fi

    if [[ -n "$NOTARY_PROFILE" ]]; then
        require_command xcrun "Install the Xcode command-line tools."
        xcrun --find notarytool >/dev/null \
            || fail "notarytool not found. Install a current version of Xcode."
        xcrun --find stapler >/dev/null \
            || fail "stapler not found. Install a current version of Xcode."
    fi
}

clean() {
    print_step "Cleaning previous local build output"
    remove_tree "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
}

build_app() {
    print_step "Building an unsigned Release archive"

    xcodebuild archive \
        -project "$PROJECT_DIR/$APP_NAME.xcodeproj" \
        -scheme "$APP_NAME" \
        -configuration Release \
        -archivePath "$ARCHIVE_PATH" \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        | tee "$BUILD_LOG"

    [[ -d "$ARCHIVE_PATH" ]] || fail "Archive was not created. See $BUILD_LOG"
}

export_app() {
    local archived_app="$ARCHIVE_PATH/Products/Applications/$APP_NAME.app"

    print_step "Exporting the app"
    [[ -d "$archived_app" ]] || fail "Archived app not found: $archived_app"
    mkdir -p "$EXPORT_PATH"
    ditto "$archived_app" "$APP_PATH"
    [[ -d "$APP_PATH" ]] || fail "App export failed: $APP_PATH"
}

sign_app() {
    local extension_path
    local -a extension_paths=()

    print_step "Signing the app with: $SIGNING_IDENTITY"

    if [[ -d "$APP_PATH/Contents/PlugIns" ]]; then
        shopt -s nullglob
        extension_paths=("$APP_PATH"/Contents/PlugIns/*.appex)
        shopt -u nullglob
    fi

    for extension_path in "${extension_paths[@]}"; do
        codesign --force \
            --sign "$SIGNING_IDENTITY" \
            --options runtime \
            --timestamp \
            "$extension_path"
    done

    codesign --force \
        --sign "$SIGNING_IDENTITY" \
        --options runtime \
        --timestamp \
        --entitlements "$ENTITLEMENTS_PATH" \
        "$APP_PATH"

    codesign --verify --deep --strict --verbose=2 "$APP_PATH"
}

create_dmg() {
    print_step "Creating the DMG"
    remove_tree "$TEMP_DMG_DIR"
    mkdir -p "$TEMP_DMG_DIR"
    ditto "$APP_PATH" "$TEMP_DMG_DIR/$APP_NAME.app"
    ln -s /Applications "$TEMP_DMG_DIR/Applications"

    remove_file "$DMG_PATH"
    hdiutil create \
        -volname "$APP_NAME" \
        -srcfolder "$TEMP_DMG_DIR" \
        -ov \
        -format UDZO \
        "$DMG_PATH"

    remove_tree "$TEMP_DMG_DIR"
    [[ -f "$DMG_PATH" ]] || fail "DMG creation failed: $DMG_PATH"
}

sign_dmg() {
    print_step "Signing the DMG"
    codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"
    codesign --verify --strict --verbose=2 "$DMG_PATH"
}

notarize_dmg() {
    print_step "Submitting the signed DMG for notarization"
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARY_PROFILE" \
        --wait

    print_step "Stapling and validating the notarization ticket"
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    codesign --verify --strict --verbose=2 "$DMG_PATH"
}

print_mode() {
    if [[ -n "$NOTARY_PROFILE" ]]; then
        print_step "Mode: signed and notarized distribution build"
    elif [[ -n "$SIGNING_IDENTITY" ]]; then
        print_step "Mode: signed local build (not notarized)"
    else
        print_warning "Mode: unsigned local build. Gatekeeper will not trust this DMG for distribution."
    fi
}

main() {
    printf '\n%s DMG Builder\n\n' "$APP_NAME"
    check_requirements
    print_mode
    clean
    build_app
    export_app

    if [[ -n "$SIGNING_IDENTITY" ]]; then
        sign_app
    fi

    create_dmg

    if [[ -n "$SIGNING_IDENTITY" ]]; then
        sign_dmg
    fi

    if [[ -n "$NOTARY_PROFILE" ]]; then
        notarize_dmg
    fi

    printf '\n%sBuild complete:%s %s\n' "$GREEN" "$NC" "$DMG_PATH"

    if [[ -z "$SIGNING_IDENTITY" ]]; then
        printf 'For a signed build, set SIGNING_IDENTITY to a Developer ID Application identity.\n'
    elif [[ -z "$NOTARY_PROFILE" ]]; then
        printf 'For notarization, store credentials with notarytool and set NOTARY_PROFILE to that Keychain profile.\n'
    fi
}

main "$@"

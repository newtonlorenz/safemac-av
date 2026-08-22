#!/bin/bash

# Build a local SafeMac AV DMG. Set SIGNING_IDENTITY to produce a signed DMG.
# Set NOTARY_PROFILE or the NOTARY_KEY_PATH/NOTARY_KEY_ID/NOTARY_ISSUER_ID
# triplet to submit it with notarytool.

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_NAME="ClamAV-GUI"
PRODUCT_NAME="SafeMac AV"
DMG_NAME="SafeMac-AV"
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
BUILD_DIR="$PROJECT_DIR/build"
ARCHIVE_PATH="$BUILD_DIR/$PROJECT_NAME.xcarchive"
EXPORT_PATH="$BUILD_DIR/export"
APP_PATH="$EXPORT_PATH/$PRODUCT_NAME.app"
DMG_PATH="$BUILD_DIR/$DMG_NAME.dmg"
APP_ZIP_PATH="$BUILD_DIR/$PRODUCT_NAME.zip"
TEMP_DMG_DIR="$BUILD_DIR/dmg-contents"
BUILD_LOG="$BUILD_DIR/archive.log"
ENTITLEMENTS_PATH="$PROJECT_DIR/$PROJECT_NAME/ClamAV_GUI.entitlements"

SIGNING_IDENTITY="${SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
NOTARY_KEY_PATH="${NOTARY_KEY_PATH:-}"
NOTARY_KEY_ID="${NOTARY_KEY_ID:-}"
NOTARY_ISSUER_ID="${NOTARY_ISSUER_ID:-}"
NOTARY_TIMEOUT="${NOTARY_TIMEOUT:-30m}"
CHECKSUM_PATH="${CHECKSUM_PATH:-$BUILD_DIR/SHA256SUMS.txt}"
SPARKLE_FEED_URL="${SPARKLE_FEED_URL:-}"
SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY:-}"
RESOLVED_SIGNING_IDENTITY=""

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

contains_arch() {
    local archs="$1"
    local expected="$2"

    [[ " $archs " == *" $expected "* ]]
}

resolve_signing_identity() {
    local matches
    local match_count

    matches="$(security find-identity -v -p codesigning | grep -F -- "$SIGNING_IDENTITY" || true)"
    match_count="$(printf '%s\n' "$matches" | sed '/^$/d' | wc -l | tr -d ' ')"

    [[ "$match_count" != "0" ]] || fail "Signing identity not found in the Keychain: $SIGNING_IDENTITY"
    [[ "$match_count" == "1" ]] \
        || fail "Signing identity is ambiguous; set SIGNING_IDENTITY to the certificate SHA-1 hash from security find-identity."

    RESOLVED_SIGNING_IDENTITY="$(printf '%s\n' "$matches" | awk '{print $2}')"
    [[ -n "$RESOLVED_SIGNING_IDENTITY" ]] || fail "Could not resolve signing identity hash."
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

    [[ -f "$PROJECT_DIR/$PROJECT_NAME.xcodeproj/project.pbxproj" ]] \
        || fail "Xcode project not found at $PROJECT_DIR/$PROJECT_NAME.xcodeproj"

    if [[ -n "$NOTARY_PROFILE" && -z "$SIGNING_IDENTITY" ]]; then
        fail "NOTARY_PROFILE requires SIGNING_IDENTITY; unsigned builds cannot be notarized."
    fi

    if [[ -n "$NOTARY_KEY_PATH$NOTARY_KEY_ID$NOTARY_ISSUER_ID" && -z "$SIGNING_IDENTITY" ]]; then
        fail "Notary API key credentials require SIGNING_IDENTITY; unsigned builds cannot be notarized."
    fi

    if [[ -n "$NOTARY_PROFILE" && -n "$NOTARY_KEY_PATH$NOTARY_KEY_ID$NOTARY_ISSUER_ID" ]]; then
        fail "Set either NOTARY_PROFILE or NOTARY_KEY_PATH/NOTARY_KEY_ID/NOTARY_ISSUER_ID, not both."
    fi

    if [[ -z "$NOTARY_PROFILE" && -n "$NOTARY_KEY_PATH$NOTARY_KEY_ID$NOTARY_ISSUER_ID" ]]; then
        [[ -n "$NOTARY_KEY_PATH" && -n "$NOTARY_KEY_ID" && -n "$NOTARY_ISSUER_ID" ]] \
            || fail "Notary API key auth requires NOTARY_KEY_PATH, NOTARY_KEY_ID, and NOTARY_ISSUER_ID."
        [[ -f "$NOTARY_KEY_PATH" ]] || fail "Notary API key file not found: $NOTARY_KEY_PATH"
    fi

    if [[ -n "$SIGNING_IDENTITY" ]]; then
        require_command codesign "Install the Xcode command-line tools."
        require_command lipo "Install the Xcode command-line tools."
        require_command security "This script must run on macOS."
        [[ -f "$ENTITLEMENTS_PATH" ]] || fail "Entitlements file not found: $ENTITLEMENTS_PATH"

        resolve_signing_identity
    fi

    if notarization_enabled; then
        require_command xcrun "Install the Xcode command-line tools."
        xcrun --find notarytool >/dev/null \
            || fail "notarytool not found. Install a current version of Xcode."
        xcrun --find stapler >/dev/null \
            || fail "stapler not found. Install a current version of Xcode."
    fi
}

sign_distribution_code() {
    local target="$1"

    codesign --force \
        --sign "$RESOLVED_SIGNING_IDENTITY" \
        --options runtime \
        --timestamp \
        --preserve-metadata=identifier,entitlements,requirements \
        "$target"
}

resolve_sparkle_version_dir() {
    local framework_path="$1"
    local version_dir=""
    local candidate

    while IFS= read -r candidate; do
        [[ -z "$version_dir" ]] || fail "Multiple Sparkle framework versions found in $framework_path"
        version_dir="$candidate"
    done < <(find "$framework_path/Versions" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -print)

    [[ -n "$version_dir" ]] || fail "Sparkle framework version directory not found in $framework_path"
    printf '%s\n' "$version_dir"
}

sign_sparkle_framework() {
    local framework_path="$1"
    local version_dir
    local updater_path
    local downloader_path
    local installer_path
    local autoupdate_path

    version_dir="$(resolve_sparkle_version_dir "$framework_path")"
    updater_path="$version_dir/Updater.app"
    downloader_path="$version_dir/XPCServices/Downloader.xpc"
    installer_path="$version_dir/XPCServices/Installer.xpc"
    autoupdate_path="$version_dir/Autoupdate"

    [[ -d "$updater_path" ]] || fail "Sparkle Updater.app not found: $updater_path"
    [[ -d "$downloader_path" ]] || fail "Sparkle Downloader.xpc not found: $downloader_path"
    [[ -d "$installer_path" ]] || fail "Sparkle Installer.xpc not found: $installer_path"
    [[ -f "$autoupdate_path" ]] || fail "Sparkle Autoupdate not found: $autoupdate_path"

    # Sign from the deepest code outward so every enclosing signature seals the
    # final Developer ID signatures of its nested components.
    sign_distribution_code "$autoupdate_path"
    sign_distribution_code "$downloader_path"
    sign_distribution_code "$installer_path"
    sign_distribution_code "$updater_path"
    sign_distribution_code "$framework_path"
}

signature_details() {
    codesign -dv --verbose=4 "$1" 2>&1 \
        || fail "Unable to inspect code signature: $1"
}

verify_distribution_code() {
    local target="$1"
    local executable_path="$2"
    local expected_team_id="$3"
    local details
    local archs

    codesign --verify --strict --verbose=2 "$target" \
        || fail "Code signature verification failed: $target"
    details="$(signature_details "$target")"

    grep -Fq 'Authority=Developer ID Application:' <<< "$details" \
        || fail "Developer ID Application authority missing: $target"
    grep -Fq "TeamIdentifier=$expected_team_id" <<< "$details" \
        || fail "Developer ID Team mismatch: $target"
    grep -Eq '^Timestamp=.+$' <<< "$details" \
        || fail "Secure timestamp missing: $target"
    if grep -Fq 'Timestamp=none' <<< "$details"; then
        fail "Secure timestamp missing: $target"
    fi
    grep -Fq 'runtime' <<< "$details" \
        || fail "Hardened runtime flag missing: $target"
    if grep -Fq 'adhoc' <<< "$details"; then
        fail "Ad-hoc signature found in distribution code: $target"
    fi

    archs="$(lipo -archs "$executable_path")" \
        || fail "Unable to inspect executable architectures: $executable_path"
    contains_arch "$archs" arm64 \
        || fail "Executable is missing arm64 slice: $executable_path ($archs)"
    contains_arch "$archs" x86_64 \
        || fail "Executable is missing x86_64 slice: $executable_path ($archs)"
}

verify_sparkle_autoupdate_entitlement() {
    local autoupdate_path="$1"
    local entitlements

    entitlements="$(codesign -d --entitlements :- "$autoupdate_path" 2>/dev/null)" \
        || fail "Unable to inspect Sparkle Autoupdate entitlements."
    grep -Fq '<key>com.apple.application-identifier</key>' <<< "$entitlements" \
        || fail "Sparkle Autoupdate application identifier entitlement is missing."
    grep -Fq '<string>org.sparkle-project.Sparkle.Autoupdate</string>' <<< "$entitlements" \
        || fail "Sparkle Autoupdate application identifier entitlement changed unexpectedly."
}

verify_signed_app_components() {
    local app_executable="$APP_PATH/Contents/MacOS/$PROJECT_NAME"
    local app_details
    local expected_team_id
    local framework_path
    local version_dir
    local extension_path
    local extension_executable
    local -a framework_paths=()
    local -a extension_paths=()

    app_details="$(signature_details "$APP_PATH")"
    expected_team_id="$(sed -n 's/^TeamIdentifier=//p' <<< "$app_details" | head -1)"
    [[ -n "$expected_team_id" && "$expected_team_id" != "not set" ]] \
        || fail "Signed app has no Developer ID Team identifier."

    verify_distribution_code "$APP_PATH" "$app_executable" "$expected_team_id"

    if [[ -d "$APP_PATH/Contents/Frameworks" ]]; then
        shopt -s nullglob
        framework_paths=("$APP_PATH"/Contents/Frameworks/*.framework)
        shopt -u nullglob
    fi

    for framework_path in "${framework_paths[@]}"; do
        if [[ "$(basename "$framework_path")" == "Sparkle.framework" ]]; then
            version_dir="$(resolve_sparkle_version_dir "$framework_path")"
            verify_distribution_code \
                "$version_dir/Updater.app" \
                "$version_dir/Updater.app/Contents/MacOS/Updater" \
                "$expected_team_id"
            verify_distribution_code \
                "$version_dir/XPCServices/Downloader.xpc" \
                "$version_dir/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
                "$expected_team_id"
            verify_distribution_code \
                "$version_dir/XPCServices/Installer.xpc" \
                "$version_dir/XPCServices/Installer.xpc/Contents/MacOS/Installer" \
                "$expected_team_id"
            verify_distribution_code \
                "$version_dir/Autoupdate" \
                "$version_dir/Autoupdate" \
                "$expected_team_id"
            verify_sparkle_autoupdate_entitlement "$version_dir/Autoupdate"
            verify_distribution_code \
                "$framework_path" \
                "$version_dir/Sparkle" \
                "$expected_team_id"
        fi
    done

    if [[ -d "$APP_PATH/Contents/PlugIns" ]]; then
        shopt -s nullglob
        extension_paths=("$APP_PATH"/Contents/PlugIns/*.appex)
        shopt -u nullglob
    fi

    for extension_path in "${extension_paths[@]}"; do
        extension_executable="$extension_path/Contents/MacOS/$(basename "$extension_path" .appex)"
        verify_distribution_code "$extension_path" "$extension_executable" "$expected_team_id"
    done

    codesign --verify --deep --strict --verbose=2 "$APP_PATH"
}

notarization_enabled() {
    [[ -n "$NOTARY_PROFILE" || -n "$NOTARY_KEY_PATH$NOTARY_KEY_ID$NOTARY_ISSUER_ID" ]]
}

clean() {
    print_step "Cleaning previous local build output"
    remove_tree "$BUILD_DIR"
    mkdir -p "$BUILD_DIR"
}

build_app() {
    print_step "Building an unsigned Release archive"

    xcodebuild archive \
        -project "$PROJECT_DIR/$PROJECT_NAME.xcodeproj" \
        -scheme "$PROJECT_NAME" \
        -configuration Release \
        -archivePath "$ARCHIVE_PATH" \
        CODE_SIGN_IDENTITY="" \
        CODE_SIGNING_REQUIRED=NO \
        CODE_SIGNING_ALLOWED=NO \
        SPARKLE_FEED_URL="$SPARKLE_FEED_URL" \
        SPARKLE_PUBLIC_ED_KEY="$SPARKLE_PUBLIC_ED_KEY" \
        | tee "$BUILD_LOG"

    [[ -d "$ARCHIVE_PATH" ]] || fail "Archive was not created. See $BUILD_LOG"
}

export_app() {
    local archived_app="$ARCHIVE_PATH/Products/Applications/$PROJECT_NAME.app"

    print_step "Exporting the app"
    [[ -d "$archived_app" ]] || fail "Archived app not found: $archived_app"
    mkdir -p "$EXPORT_PATH"
    ditto "$archived_app" "$APP_PATH"
    [[ -d "$APP_PATH" ]] || fail "App export failed: $APP_PATH"
}

sign_app() {
    local extension_path
    local framework_path
    local -a extension_paths=()
    local -a framework_paths=()

    print_step "Signing the app with: $SIGNING_IDENTITY"

    if [[ -d "$APP_PATH/Contents/Frameworks" ]]; then
        shopt -s nullglob
        framework_paths=("$APP_PATH"/Contents/Frameworks/*.framework)
        shopt -u nullglob
    fi

    if [[ -d "$APP_PATH/Contents/PlugIns" ]]; then
        shopt -s nullglob
        extension_paths=("$APP_PATH"/Contents/PlugIns/*.appex)
        shopt -u nullglob
    fi

    for framework_path in "${framework_paths[@]}"; do
        if [[ "$(basename "$framework_path")" == "Sparkle.framework" ]]; then
            sign_sparkle_framework "$framework_path"
        else
            sign_distribution_code "$framework_path"
        fi
    done

    for extension_path in "${extension_paths[@]}"; do
        sign_distribution_code "$extension_path"
    done

    codesign --force \
        --sign "$RESOLVED_SIGNING_IDENTITY" \
        --options runtime \
        --timestamp \
        --entitlements "$ENTITLEMENTS_PATH" \
        "$APP_PATH"

    verify_signed_app_components
}

notarize_app() {
    print_step "Submitting the signed app for notarization"
    remove_file "$APP_ZIP_PATH"
    (cd "$EXPORT_PATH" && ditto -c -k --keepParent "$PRODUCT_NAME.app" "$APP_ZIP_PATH")

    if [[ -n "$NOTARY_PROFILE" ]]; then
        xcrun notarytool submit "$APP_ZIP_PATH" \
            --keychain-profile "$NOTARY_PROFILE" \
            --wait \
            --timeout "$NOTARY_TIMEOUT"
    else
        xcrun notarytool submit "$APP_ZIP_PATH" \
            --key "$NOTARY_KEY_PATH" \
            --key-id "$NOTARY_KEY_ID" \
            --issuer "$NOTARY_ISSUER_ID" \
            --wait \
            --timeout "$NOTARY_TIMEOUT"
    fi

    print_step "Stapling and validating the app notarization ticket"
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
    codesign --verify --deep --strict --verbose=2 "$APP_PATH"
    remove_file "$APP_ZIP_PATH"
}

create_dmg() {
    print_step "Creating the DMG"
    remove_tree "$TEMP_DMG_DIR"
    mkdir -p "$TEMP_DMG_DIR"
    ditto "$APP_PATH" "$TEMP_DMG_DIR/$PRODUCT_NAME.app"
    ln -s /Applications "$TEMP_DMG_DIR/Applications"

    remove_file "$DMG_PATH"
    hdiutil create \
        -volname "$PRODUCT_NAME" \
        -srcfolder "$TEMP_DMG_DIR" \
        -ov \
        -format UDZO \
        "$DMG_PATH"

    remove_tree "$TEMP_DMG_DIR"
    [[ -f "$DMG_PATH" ]] || fail "DMG creation failed: $DMG_PATH"
}

sign_dmg() {
    print_step "Signing the DMG"
    codesign --force --sign "$RESOLVED_SIGNING_IDENTITY" --timestamp "$DMG_PATH"
    codesign --verify --strict --verbose=2 "$DMG_PATH"
}

notarize_dmg() {
    print_step "Submitting the signed DMG for notarization"
    if [[ -n "$NOTARY_PROFILE" ]]; then
        xcrun notarytool submit "$DMG_PATH" \
            --keychain-profile "$NOTARY_PROFILE" \
            --wait \
            --timeout "$NOTARY_TIMEOUT"
    else
        xcrun notarytool submit "$DMG_PATH" \
            --key "$NOTARY_KEY_PATH" \
            --key-id "$NOTARY_KEY_ID" \
            --issuer "$NOTARY_ISSUER_ID" \
            --wait \
            --timeout "$NOTARY_TIMEOUT"
    fi

    print_step "Stapling and validating the notarization ticket"
    xcrun stapler staple "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    codesign --verify --strict --verbose=2 "$DMG_PATH"
}

write_checksums() {
    print_step "Writing checksums"
    (cd "$BUILD_DIR" && shasum -a 256 "$(basename "$DMG_PATH")") > "$CHECKSUM_PATH"
    [[ -f "$CHECKSUM_PATH" ]] || fail "Checksum file was not created: $CHECKSUM_PATH"
}

print_mode() {
    if notarization_enabled; then
        print_step "Mode: signed and notarized distribution build"
    elif [[ -n "$SIGNING_IDENTITY" ]]; then
        print_step "Mode: signed local build (not notarized)"
    else
        print_warning "Mode: unsigned local build. Gatekeeper will not trust this DMG for distribution."
    fi
}

main() {
    printf '\n%s DMG Builder\n\n' "$PRODUCT_NAME"
    check_requirements
    print_mode
    clean
    build_app
    export_app

    if [[ -n "$SIGNING_IDENTITY" ]]; then
        sign_app
    fi

    if notarization_enabled; then
        notarize_app
    fi

    create_dmg

    if [[ -n "$SIGNING_IDENTITY" ]]; then
        sign_dmg
    fi

    if notarization_enabled; then
        notarize_dmg
    fi

    write_checksums

    printf '\n%sBuild complete:%s %s\n' "$GREEN" "$NC" "$DMG_PATH"
    printf '%sChecksums:%s %s\n' "$GREEN" "$NC" "$CHECKSUM_PATH"

    if [[ -z "$SIGNING_IDENTITY" ]]; then
        printf 'For a signed build, set SIGNING_IDENTITY to a Developer ID Application identity.\n'
    elif ! notarization_enabled; then
        printf 'For notarization, set NOTARY_PROFILE or NOTARY_KEY_PATH/NOTARY_KEY_ID/NOTARY_ISSUER_ID.\n'
    fi
}

main "$@"

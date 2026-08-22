#!/bin/bash

# Verify a SafeMac AV release package before publication.
# This script expects a signed, notarized DMG plus SHA256SUMS.txt. If an appcast
# is present, it also checks that the appcast references the DMG and matches the
# bundled app version.

set -Eeuo pipefail
IFS=$'\n\t'

PACKAGE_DIR="${1:-build}"
DMG_NAME="${DMG_NAME:-SafeMac-AV.dmg}"
VOLUME_APP_NAME="${VOLUME_APP_NAME:-SafeMac AV.app}"
DMG_PATH="$PACKAGE_DIR/$DMG_NAME"
CHECKSUM_PATH="$PACKAGE_DIR/SHA256SUMS.txt"
APPCAST_PATH="${APPCAST_PATH:-$PACKAGE_DIR/appcast/appcast.xml}"
SAFEMAC_VERIFY_APP_PATH="${SAFEMAC_VERIFY_APP_PATH:-}"

fail() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

info() {
    printf 'Verified: %s\n' "$1"
}

require_file() {
    [[ -f "$1" ]] || fail "$2 not found: $1"
}

command_path() {
    command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

contains_arch() {
    local archs="$1"
    local expected="$2"

    [[ " $archs " == *" $expected "* ]]
}

signature_details() {
    codesign -dv --verbose=4 "$1" 2>&1 \
        || fail "unable to inspect code signature: $1"
}

resolve_sparkle_version_dir() {
    local framework_path="$1"
    local version_dir=""
    local candidate

    while IFS= read -r candidate; do
        [[ -z "$version_dir" ]] || fail "multiple Sparkle framework versions found: $framework_path"
        version_dir="$candidate"
    done < <(find "$framework_path/Versions" \
        -mindepth 1 \
        -maxdepth 1 \
        -type d \
        -print)

    [[ -n "$version_dir" ]] || fail "Sparkle framework version directory not found: $framework_path"
    printf '%s\n' "$version_dir"
}

verify_distribution_code() {
    local target="$1"
    local executable_path="$2"
    local expected_team_id="$3"
    local details
    local archs

    [[ -e "$target" ]] || fail "nested code not found: $target"
    require_file "$executable_path" "nested executable"

    codesign --verify --strict --verbose=2 "$target"
    details="$(signature_details "$target")"

    grep -Fq 'Authority=Developer ID Application:' <<< "$details" \
        || fail "Developer ID Application authority missing: $target"
    grep -Fq "TeamIdentifier=$expected_team_id" <<< "$details" \
        || fail "Developer ID Team mismatch: $target"
    grep -Eq '^Timestamp=.+$' <<< "$details" \
        || fail "secure timestamp missing: $target"
    if grep -Fq 'Timestamp=none' <<< "$details"; then
        fail "secure timestamp missing: $target"
    fi
    grep -Fq 'runtime' <<< "$details" \
        || fail "hardened runtime flag missing: $target"
    if grep -Fq 'adhoc' <<< "$details"; then
        fail "ad-hoc signature found in release code: $target"
    fi

    archs="$(lipo -archs "$executable_path")" \
        || fail "unable to inspect executable architectures: $executable_path"
    contains_arch "$archs" arm64 \
        || fail "nested executable is missing arm64 slice: $executable_path ($archs)"
    contains_arch "$archs" x86_64 \
        || fail "nested executable is missing x86_64 slice: $executable_path ($archs)"
}

verify_sparkle_autoupdate_entitlement() {
    local autoupdate_path="$1"
    local entitlements

    entitlements="$(codesign -d --entitlements :- "$autoupdate_path" 2>/dev/null)" \
        || fail "unable to inspect Sparkle Autoupdate entitlements"
    grep -Fq '<key>com.apple.application-identifier</key>' <<< "$entitlements" \
        || fail "Sparkle Autoupdate application identifier entitlement is missing"
    grep -Fq '<string>org.sparkle-project.Sparkle.Autoupdate</string>' <<< "$entitlements" \
        || fail "Sparkle Autoupdate application identifier entitlement changed unexpectedly"
}

mounted_app_path=""
mount_point=""

cleanup() {
    if [[ -n "$mount_point" && -d "$mount_point" ]]; then
        hdiutil detach "$mount_point" -quiet >/dev/null 2>&1 || true
        rmdir "$mount_point" >/dev/null 2>&1 || true
    fi
}

trap cleanup EXIT

verify_checksum() {
    require_file "$DMG_PATH" "DMG"
    require_file "$CHECKSUM_PATH" "checksum file"

    (cd "$PACKAGE_DIR" && shasum -a 256 -c "$(basename "$CHECKSUM_PATH")")
    info "SHA-256 checksums"
}

verify_dmg_trust() {
    command_path codesign
    command_path xcrun
    command_path spctl

    codesign --verify --strict --verbose=2 "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
    spctl --assess --type open --verbose "$DMG_PATH"
    info "DMG signature, stapled ticket, and Gatekeeper assessment"
}

resolve_app_path() {
    if [[ -n "$SAFEMAC_VERIFY_APP_PATH" ]]; then
        [[ -d "$SAFEMAC_VERIFY_APP_PATH" ]] || fail "override app path is not a directory: $SAFEMAC_VERIFY_APP_PATH"
        mounted_app_path="$SAFEMAC_VERIFY_APP_PATH"
        return
    fi

    command_path hdiutil

    mount_point="$(mktemp -d "${TMPDIR:-/tmp}/safemac-release.XXXXXX")"
    hdiutil attach "$DMG_PATH" -readonly -nobrowse -mountpoint "$mount_point" >/dev/null
    mounted_app_path="$mount_point/$VOLUME_APP_NAME"
    [[ -d "$mounted_app_path" ]] || fail "mounted app not found: $mounted_app_path"
}

bundle_value() {
    local key="$1"
    local info_plist="$mounted_app_path/Contents/Info.plist"

    /usr/libexec/PlistBuddy -c "Print :$key" "$info_plist" 2>/dev/null \
        || fail "unable to read $key from $info_plist"
}

verify_app_bundle() {
    local executable_path
    local executable_name
    local archs
    local app_details
    local expected_team_id
    local sparkle_framework
    local sparkle_version
    local finder_extension
    local finder_executable

    resolve_app_path
    executable_name="$(bundle_value CFBundleExecutable)"
    executable_path="$mounted_app_path/Contents/MacOS/$executable_name"
    require_file "$executable_path" "app executable"

    command_path lipo
    command_path codesign
    command_path spctl

    archs="$(lipo -archs "$executable_path")"
    contains_arch "$archs" arm64 || fail "app executable is missing arm64 slice: $archs"
    contains_arch "$archs" x86_64 || fail "app executable is missing x86_64 slice: $archs"

    codesign --verify --strict --verbose=2 "$mounted_app_path"
    xcrun stapler validate "$mounted_app_path"
    spctl --assess --type execute --verbose "$mounted_app_path"

    app_details="$(signature_details "$mounted_app_path")"
    grep -Fq 'Authority=Developer ID Application:' <<< "$app_details" \
        || fail "app is not signed by a Developer ID Application identity"
    expected_team_id="$(sed -n 's/^TeamIdentifier=//p' <<< "$app_details" | head -1)"
    [[ -n "$expected_team_id" && "$expected_team_id" != "not set" ]] \
        || fail "app signature has no Developer ID Team identifier"
    verify_distribution_code "$mounted_app_path" "$executable_path" "$expected_team_id"

    sparkle_framework="$mounted_app_path/Contents/Frameworks/Sparkle.framework"
    [[ -d "$sparkle_framework" ]] || fail "Sparkle framework not found: $sparkle_framework"
    sparkle_version="$(resolve_sparkle_version_dir "$sparkle_framework")"

    verify_distribution_code \
        "$sparkle_version/Updater.app" \
        "$sparkle_version/Updater.app/Contents/MacOS/Updater" \
        "$expected_team_id"
    verify_distribution_code \
        "$sparkle_version/XPCServices/Downloader.xpc" \
        "$sparkle_version/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
        "$expected_team_id"
    verify_distribution_code \
        "$sparkle_version/XPCServices/Installer.xpc" \
        "$sparkle_version/XPCServices/Installer.xpc/Contents/MacOS/Installer" \
        "$expected_team_id"
    verify_distribution_code \
        "$sparkle_version/Autoupdate" \
        "$sparkle_version/Autoupdate" \
        "$expected_team_id"
    verify_sparkle_autoupdate_entitlement "$sparkle_version/Autoupdate"
    verify_distribution_code \
        "$sparkle_framework" \
        "$sparkle_version/Sparkle" \
        "$expected_team_id"

    finder_extension="$mounted_app_path/Contents/PlugIns/ClamAV-GUI-Finder.appex"
    finder_executable="$finder_extension/Contents/MacOS/ClamAV-GUI-Finder"
    verify_distribution_code "$finder_extension" "$finder_executable" "$expected_team_id"

    codesign --verify --deep --strict --verbose=2 "$mounted_app_path"
    info "mounted app, Finder extension, and nested Sparkle code use Developer ID Team $expected_team_id, hardened runtime, secure timestamps, and universal architectures"
}

verify_appcast() {
    local bundle_version
    local short_version

    if [[ ! -f "$APPCAST_PATH" ]]; then
        printf 'Skipped: appcast not present at %s\n' "$APPCAST_PATH"
        return
    fi

    bundle_version="$(bundle_value CFBundleVersion)"
    short_version="$(bundle_value CFBundleShortVersionString)"

    grep -Fq "$DMG_NAME" "$APPCAST_PATH" \
        || fail "appcast does not reference $DMG_NAME"
    grep -Eq 'sparkle:edSignature="[^"]+"' "$APPCAST_PATH" \
        || fail "appcast is missing sparkle:edSignature"
    grep -Fq "sparkle:version=\"$bundle_version\"" "$APPCAST_PATH" \
        || fail "appcast sparkle:version does not match CFBundleVersion $bundle_version"
    grep -Fq "sparkle:shortVersionString=\"$short_version\"" "$APPCAST_PATH" \
        || fail "appcast short version does not match CFBundleShortVersionString $short_version"

    info "Sparkle appcast references the DMG and matches app version $short_version ($bundle_version)"
}

main() {
    verify_checksum
    verify_dmg_trust
    verify_app_bundle
    verify_appcast
}

main "$@"

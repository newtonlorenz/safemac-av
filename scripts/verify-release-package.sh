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
    local app_team_id

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
    app_team_id="$(code_signature_field "$mounted_app_path" TeamIdentifier)"
    [[ -n "$app_team_id" ]] || fail "mounted app is missing a TeamIdentifier"
    verify_nested_code_signatures "$app_team_id"
    info "mounted app signature, stapled ticket, Gatekeeper assessment, and universal architectures: $archs"
}

code_signature_field() {
    local path="$1"
    local key="$2"

    codesign -dv --verbose=4 "$path" 2>&1 \
        | awk -F= -v key="$key" '$1 == key { print $2; exit }'
}

verify_one_nested_code_signature() {
    local path="$1"
    local expected_team_id="$2"
    local signature
    local team_id

    codesign --verify --strict --verbose=2 "$path"
    signature="$(code_signature_field "$path" Signature)"
    team_id="$(code_signature_field "$path" TeamIdentifier)"

    [[ "$signature" != "adhoc" ]] || fail "nested code is ad-hoc signed: $path"
    [[ -n "$team_id" ]] || fail "nested code is missing a TeamIdentifier: $path"
    [[ "$team_id" == "$expected_team_id" ]] \
        || fail "nested code TeamIdentifier $team_id does not match app TeamIdentifier $expected_team_id: $path"
}

verify_nested_code_signatures() {
    local expected_team_id="$1"
    local nested_path

    if [[ ! -d "$mounted_app_path/Contents/Frameworks" && ! -d "$mounted_app_path/Contents/PlugIns" ]]; then
        return
    fi

    while IFS= read -r -d '' nested_path; do
        verify_one_nested_code_signature "$nested_path" "$expected_team_id"
    done < <(find "$mounted_app_path/Contents/Frameworks" "$mounted_app_path/Contents/PlugIns" \
        \( -type d \( -name '*.framework' -o -name '*.app' -o -name '*.appex' -o -name '*.xpc' \) \
        -o -type f \( -name Autoupdate -perm -111 \) \) -print0 2>/dev/null)
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

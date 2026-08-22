#!/bin/bash

# Run a Sparkle update canary against a temporary copy of an installed SafeMac AV
# app. By default this probes the signed appcast without installing. Set
# SAFEMAC_CANARY_INSTALL=1 to let sparkle-cli install into the temporary copy.

set -Eeuo pipefail
IFS=$'\n\t'

APP_PATH="${SAFEMAC_CANARY_APP_PATH:-/Applications/SafeMac AV.app}"
FEED_URL="${SAFEMAC_CANARY_FEED_URL:-}"
SPARKLE_CLI="${SPARKLE_CLI:-}"
INSTALL_UPDATE="${SAFEMAC_CANARY_INSTALL:-0}"
KEEP_WORKDIR="${SAFEMAC_CANARY_KEEP_WORKDIR:-0}"
EXPECT_UPDATE="${SAFEMAC_CANARY_EXPECT_UPDATE:-0}"
ALLOW_MAJOR_UPGRADES="${SAFEMAC_CANARY_ALLOW_MAJOR_UPGRADES:-0}"
EXPECTED_BUNDLE_ID="${SAFEMAC_CANARY_BUNDLE_ID:-com.newtonlorenz.ClamAV-GUI}"
EXPECTED_TEAM_ID="CQPH8YR62A"
ALLOW_UNSIGNED_TEST_FIXTURE="${SAFEMAC_CANARY_TEST_ONLY_ALLOW_UNSIGNED_FIXTURE:-0}"
USER_AGENT="${SAFEMAC_CANARY_USER_AGENT:-SafeMac AV Sparkle canary}"

WORK_DIR=""
CANARY_APP_PATH=""

fail() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

info() {
    printf 'Verified: %s\n' "$1"
}

command_path() {
    command -v "$1" >/dev/null 2>&1 || fail "$1 is required"
}

cleanup() {
    if [[ -n "$WORK_DIR" && "$KEEP_WORKDIR" != "1" ]]; then
        rm -rf "$WORK_DIR"
    elif [[ -n "$WORK_DIR" ]]; then
        printf 'Canary workdir kept at %s\n' "$WORK_DIR"
    fi
}

trap cleanup EXIT

plist_value() {
    local app_path="$1"
    local key="$2"

    /usr/libexec/PlistBuddy -c "Print :$key" "$app_path/Contents/Info.plist" 2>/dev/null \
        || true
}

require_app_bundle() {
    local app_path="$1"

    [[ -d "$app_path" ]] || fail "app bundle not found: $app_path"
    [[ -f "$app_path/Contents/Info.plist" ]] || fail "Info.plist not found in app bundle: $app_path"
}

resolve_sparkle_cli() {
    [[ -n "$SPARKLE_CLI" ]] || fail "SPARKLE_CLI is required; point it at Sparkle 2's sparkle.app/Contents/MacOS/sparkle"
    [[ -x "$SPARKLE_CLI" ]] || fail "SPARKLE_CLI is not executable: $SPARKLE_CLI"
}

resolve_feed_url() {
    if [[ -z "$FEED_URL" ]]; then
        FEED_URL="$(plist_value "$APP_PATH" SUFeedURL)"
    fi

    [[ -n "$FEED_URL" ]] || fail "Sparkle feed URL is missing; set SAFEMAC_CANARY_FEED_URL or SUFeedURL"
    [[ "$FEED_URL" != *'$('* ]] || fail "Sparkle feed URL contains an unresolved build setting"
    [[ "$FEED_URL" == https://* || "$FEED_URL" == file://* ]] || fail "Sparkle feed URL must be https:// or file:// for the canary"
}

verify_app_policy() {
    local app_path="$1"
    local label="$2"
    local bundle_id
    local details

    require_app_bundle "$app_path"
    bundle_id="$(plist_value "$app_path" CFBundleIdentifier)"
    [[ "$bundle_id" == "$EXPECTED_BUNDLE_ID" ]] \
        || fail "$label has unexpected bundle identifier: ${bundle_id:-missing}"

    if is_explicit_test_fixture "$app_path"; then
        info "$label uses the explicit unsigned temporary test-fixture override"
        return
    fi

    codesign --verify --deep --strict --verbose=2 "$app_path" \
        || fail "$label signature verification failed"

    details="$(codesign -dv --verbose=4 "$app_path" 2>&1)" \
        || fail "unable to inspect $label signature"
    grep -Fq 'Authority=Developer ID Application:' <<< "$details" \
        || fail "$label is not signed with Developer ID Application"
    grep -Fq "TeamIdentifier=$EXPECTED_TEAM_ID" <<< "$details" \
        || fail "$label is not signed by the expected Developer ID team"
    grep -Eq '^Timestamp=.+$' <<< "$details" \
        || fail "$label signature does not include a secure timestamp"
    if grep -Fq 'Timestamp=none' <<< "$details"; then
        fail "$label signature does not include a secure timestamp"
    fi
    grep -Fq 'runtime' <<< "$details" \
        || fail "$label signature is missing hardened runtime"

    spctl -a -vv -t execute "$app_path" >/dev/null 2>&1 \
        || fail "Gatekeeper does not trust $label"

    info "$label uses Developer ID Team $EXPECTED_TEAM_ID, hardened runtime, and Gatekeeper trust"
}

is_explicit_test_fixture() {
    local app_path="$1"
    local app_parent
    local temp_root

    [[ "$ALLOW_UNSIGNED_TEST_FIXTURE" == "1" ]] || return 1
    app_parent="$(cd "$(dirname "$app_path")" && pwd -P)"
    temp_root="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
    [[ "$app_parent/" == "$temp_root/"* ]] \
        || fail "unsigned fixture override is restricted to the temporary test directory"
}

copy_canary_app() {
    local parent_dir

    WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/safemac-sparkle-canary.XXXXXX")"
    parent_dir="$WORK_DIR/Applications"
    CANARY_APP_PATH="$parent_dir/$(basename "$APP_PATH")"
    mkdir -p "$parent_dir"

    ditto "$APP_PATH" "$CANARY_APP_PATH"
    chmod -R u+w "$CANARY_APP_PATH"
    require_app_bundle "$CANARY_APP_PATH"

    info "copied installed app to temporary canary bundle"
}

append_common_sparkle_arguments() {
    arguments+=("$CANARY_APP_PATH")
    arguments+=("--feed-url")
    arguments+=("$FEED_URL")
    arguments+=("--user-agent-name")
    arguments+=("$USER_AGENT")
    arguments+=("--verbose")
    if [[ "$ALLOW_MAJOR_UPGRADES" == "1" ]]; then
        arguments+=("--allow-major-upgrades")
    fi
}

append_install_sparkle_arguments() {
    append_common_sparkle_arguments
    arguments+=("--application")
    arguments+=("$CANARY_APP_PATH")
    arguments+=("--check-immediately")
}

run_probe() {
    local status
    local arguments=()

    append_common_sparkle_arguments
    arguments+=("--probe")

    set +e
    "$SPARKLE_CLI" "${arguments[@]}"
    status=$?
    set -e

    case "$status" in
        0)
            info "sparkle-cli found an available signed update"
            ;;
        4)
            [[ "$EXPECT_UPDATE" != "1" ]] || fail "sparkle-cli reported no available update"
            info "sparkle-cli reached the signed feed and reported no available update"
            ;;
        2)
            fail "sparkle-cli found a major upgrade; set SAFEMAC_CANARY_ALLOW_MAJOR_UPGRADES=1 if this is expected"
            ;;
        *)
            fail "sparkle-cli probe failed with exit status $status"
            ;;
    esac
}

wait_for_installed_version_change() {
    local before_version="$1"
    local after_version

    for _ in {1..30}; do
        after_version="$(plist_value "$CANARY_APP_PATH" CFBundleVersion)"
        if [[ -n "$after_version" && "$after_version" != "$before_version" ]]; then
            info "temporary canary app updated from build $before_version to $after_version"
            return
        fi
        sleep 2
    done

    fail "temporary canary app did not update within 60 seconds"
}

run_install() {
    local before_version
    local arguments=()

    before_version="$(plist_value "$CANARY_APP_PATH" CFBundleVersion)"
    [[ -n "$before_version" ]] || fail "temporary canary app is missing CFBundleVersion"

    append_install_sparkle_arguments
    "$SPARKLE_CLI" "${arguments[@]}"
    wait_for_installed_version_change "$before_version"
    verify_app_policy "$CANARY_APP_PATH" "updated temporary canary app"
}

main() {
    command_path codesign
    command_path ditto
    command_path spctl
    resolve_sparkle_cli
    resolve_feed_url
    verify_app_policy "$APP_PATH" "installed app"
    copy_canary_app

    if [[ "$INSTALL_UPDATE" == "1" ]]; then
        run_install
    else
        run_probe
    fi

    info "Sparkle installed-app canary completed without touching $APP_PATH"
}

main "$@"

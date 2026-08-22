#!/bin/bash

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/safemac-run-sparkle-canary-test.XXXXXX")"
FAKE_BIN="$WORK_DIR/bin"
APP_PATH="$WORK_DIR/SafeMac AV.app"
SPARKLE_LOG="$WORK_DIR/sparkle.log"
OUTSIDE_WORK_DIR="$(mktemp -d /tmp/safemac-run-sparkle-canary-outside.XXXXXX)"

cleanup() {
    rm -rf "$WORK_DIR"
    rm -rf "$OUTSIDE_WORK_DIR"
}

trap cleanup EXIT

fail() {
    printf 'Test failed: %s\n' "$1" >&2
    exit 1
}

write_fake_tool() {
    local name="$1"
    local body="$2"

    {
        printf '#!/bin/bash\n'
        printf 'set -Eeuo pipefail\n'
        printf '%s\n' "$body"
    } > "$FAKE_BIN/$name"
    chmod +x "$FAKE_BIN/$name"
}

write_info_plist() {
    local app_path="$1"
    local feed_url="$2"
    local version="$3"

    mkdir -p "$app_path/Contents/MacOS"
    cat > "$app_path/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>ClamAV-GUI</string>
    <key>CFBundleIdentifier</key>
    <string>com.newtonlorenz.ClamAV-GUI</string>
    <key>CFBundleShortVersionString</key>
    <string>1.2.0</string>
    <key>CFBundleVersion</key>
    <string>$version</string>
    <key>SUFeedURL</key>
    <string>$feed_url</string>
</dict>
</plist>
PLIST
    printf 'app\n' > "$app_path/Contents/MacOS/ClamAV-GUI"
    chmod +x "$app_path/Contents/MacOS/ClamAV-GUI"
}

make_fake_tools() {
    mkdir -p "$FAKE_BIN"

    write_fake_tool codesign '
target="${!#}"
if [[ " $* " == *" --verify "* && "${CANARY_CODESIGN_VERIFY_FAIL:-0}" == "1" ]]; then
    exit 1
fi
if [[ " $* " == *" -dv "* ]]; then
    flags="CodeDirectory v=20500 flags=0x10000(runtime)"
    team_id="${CANARY_CODESIGN_TEAM_ID:-CQPH8YR62A}"
    if [[ "${CANARY_CODESIGN_MISSING_RUNTIME:-0}" == "1" || ( "${CANARY_COPY_MISSING_RUNTIME:-0}" == "1" && "$target" == *"safemac-sparkle-canary."* ) ]]; then
        flags="CodeDirectory v=20500 flags=0x0(none)"
    fi
    printf "%s\n" \
        "Authority=Developer ID Application: SafeMac Test ($team_id)" \
        "TeamIdentifier=$team_id" \
        "Timestamp=Aug 22, 2026 at 02:00:00" \
        "$flags" >&2
fi'

    write_fake_tool spctl '[[ "${CANARY_SPCTL_FAIL:-0}" != "1" ]]'

    write_fake_tool ditto '
source_path="$1"
destination_path="$2"
/bin/cp -R "$source_path" "$destination_path"'

    write_fake_tool sparkle '
bundle_path="$1"
printf "%s\n" "$*" >> "${SPARKLE_LOG:?}"
if [[ " $* " == *" --probe "* ]]; then
    exit "${SPARKLE_PROBE_STATUS:-0}"
fi
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion 2" "$bundle_path/Contents/Info.plist"
exit 0'
}

run_canary() {
    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    SPARKLE_LOG="$SPARKLE_LOG" \
    SPARKLE_CLI="$FAKE_BIN/sparkle" \
    SAFEMAC_CANARY_APP_PATH="$APP_PATH" \
    SAFEMAC_CANARY_KEEP_WORKDIR=0 \
        "$PROJECT_DIR/scripts/run-installed-sparkle-canary.sh" >/dev/null
}

test_probe_invokes_sparkle_cli_against_temp_copy() {
    : > "$SPARKLE_LOG"
    write_info_plist "$APP_PATH" "https://updates.example.com/appcast.xml" 1
    run_canary

    grep -Fq -- "--probe" "$SPARKLE_LOG" \
        || fail "probe mode did not pass --probe"
    if grep -Fq -- "--check-immediately" "$SPARKLE_LOG"; then
        fail "probe mode passed incompatible --check-immediately"
    fi
    if grep -Fq -- "--application" "$SPARKLE_LOG"; then
        fail "probe mode passed incompatible --application"
    fi
    grep -Fq -- "--feed-url https://updates.example.com/appcast.xml" "$SPARKLE_LOG" \
        || fail "canary did not use the bundle feed URL"
    grep -Fq -- "safemac-sparkle-canary." "$SPARKLE_LOG" \
        || fail "canary did not operate on a temporary app copy"
}

test_install_mode_updates_temp_copy() {
    : > "$SPARKLE_LOG"
    write_info_plist "$APP_PATH" "https://updates.example.com/appcast.xml" 1

    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    SPARKLE_LOG="$SPARKLE_LOG" \
    SPARKLE_CLI="$FAKE_BIN/sparkle" \
    SAFEMAC_CANARY_APP_PATH="$APP_PATH" \
    SAFEMAC_CANARY_INSTALL=1 \
    SAFEMAC_CANARY_KEEP_WORKDIR=0 \
        "$PROJECT_DIR/scripts/run-installed-sparkle-canary.sh" >/dev/null

    if grep -Fq -- "--probe" "$SPARKLE_LOG"; then
        fail "install mode unexpectedly passed --probe"
    fi
    grep -Fq -- "--check-immediately" "$SPARKLE_LOG" \
        || fail "install mode did not check immediately"
    grep -Fq -- "--application" "$SPARKLE_LOG" \
        || fail "install mode did not pass an application bundle"
}

test_install_mode_verifies_updated_temp_copy_policy() {
    : > "$SPARKLE_LOG"
    write_info_plist "$APP_PATH" "https://updates.example.com/appcast.xml" 1

    if PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
       SPARKLE_LOG="$SPARKLE_LOG" \
       SPARKLE_CLI="$FAKE_BIN/sparkle" \
       CANARY_COPY_MISSING_RUNTIME=1 \
       SAFEMAC_CANARY_APP_PATH="$APP_PATH" \
       SAFEMAC_CANARY_INSTALL=1 \
       SAFEMAC_CANARY_KEEP_WORKDIR=0 \
            "$PROJECT_DIR/scripts/run-installed-sparkle-canary.sh" >/dev/null 2>&1; then
        fail "install mode accepted updated temporary app without hardened runtime"
    fi
}

test_installed_app_signature_policy_failures() {
    write_info_plist "$APP_PATH" "https://updates.example.com/appcast.xml" 1

    if CANARY_CODESIGN_TEAM_ID="WRONGTEAM01" run_canary >/dev/null 2>&1; then
        fail "wrong-team installed app was accepted"
    fi
    if CANARY_CODESIGN_VERIFY_FAIL=1 run_canary >/dev/null 2>&1; then
        fail "tampered or unsigned installed app was accepted"
    fi
    if CANARY_CODESIGN_MISSING_RUNTIME=1 run_canary >/dev/null 2>&1; then
        fail "installed app without hardened runtime was accepted"
    fi
    if CANARY_SPCTL_FAIL=1 run_canary >/dev/null 2>&1; then
        fail "Gatekeeper-rejected installed app was accepted"
    fi
}

test_unsigned_fixture_override() {
    write_info_plist "$APP_PATH" "https://updates.example.com/appcast.xml" 1
    printf 'SafeMac canary unsigned fixture\n' > "$WORK_DIR/.safemac-canary-unsigned-fixture"
    chmod 600 "$WORK_DIR/.safemac-canary-unsigned-fixture"

    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    SPARKLE_LOG="$SPARKLE_LOG" \
    SPARKLE_CLI="$FAKE_BIN/sparkle" \
    CANARY_CODESIGN_VERIFY_FAIL=1 \
    CANARY_SPCTL_FAIL=1 \
    SAFEMAC_CANARY_APP_PATH="$APP_PATH" \
    SAFEMAC_CANARY_TEST_ONLY_ALLOW_UNSIGNED_FIXTURE=1 \
    SAFEMAC_CANARY_TEST_ONLY_FIXTURE_ROOT="$WORK_DIR" \
        "$PROJECT_DIR/scripts/run-installed-sparkle-canary.sh" >/dev/null \
        || fail "explicit unsigned test-fixture override was rejected"
}

test_unsigned_fixture_override_covers_script_created_copy() {
    write_info_plist "$APP_PATH" "https://updates.example.com/appcast.xml" 1
    printf 'SafeMac canary unsigned fixture\n' > "$WORK_DIR/.safemac-canary-unsigned-fixture"
    chmod 600 "$WORK_DIR/.safemac-canary-unsigned-fixture"

    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    SPARKLE_LOG="$SPARKLE_LOG" \
    SPARKLE_CLI="$FAKE_BIN/sparkle" \
    CANARY_CODESIGN_VERIFY_FAIL=1 \
    CANARY_SPCTL_FAIL=1 \
    SAFEMAC_CANARY_APP_PATH="$APP_PATH" \
    SAFEMAC_CANARY_INSTALL=1 \
    SAFEMAC_CANARY_TEST_ONLY_ALLOW_UNSIGNED_FIXTURE=1 \
    SAFEMAC_CANARY_TEST_ONLY_FIXTURE_ROOT="$WORK_DIR" \
        "$PROJECT_DIR/scripts/run-installed-sparkle-canary.sh" >/dev/null \
        || fail "unsigned fixture override rejected the script-created canary copy"
}

test_unsigned_fixture_override_is_temp_scoped() {
    write_info_plist "$APP_PATH" "https://updates.example.com/appcast.xml" 1
    if TMPDIR="/Applications" \
       PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
       SPARKLE_LOG="$SPARKLE_LOG" \
       SPARKLE_CLI="$FAKE_BIN/sparkle" \
       CANARY_CODESIGN_VERIFY_FAIL=1 \
       SAFEMAC_CANARY_APP_PATH="$APP_PATH" \
       SAFEMAC_CANARY_TEST_ONLY_ALLOW_UNSIGNED_FIXTURE=1 \
        "$PROJECT_DIR/scripts/run-installed-sparkle-canary.sh" >/dev/null 2>&1; then
        fail "caller-controlled TMPDIR enabled the unsigned fixture override"
    fi
}

test_unsigned_fixture_override_requires_explicit_root() {
    write_info_plist "$APP_PATH" "https://updates.example.com/appcast.xml" 1
    if TMPDIR="$WORK_DIR" \
       PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
       SPARKLE_LOG="$SPARKLE_LOG" \
       SPARKLE_CLI="$FAKE_BIN/sparkle" \
       CANARY_CODESIGN_VERIFY_FAIL=1 \
       SAFEMAC_CANARY_APP_PATH="$APP_PATH" \
       SAFEMAC_CANARY_TEST_ONLY_ALLOW_UNSIGNED_FIXTURE=1 \
        "$PROJECT_DIR/scripts/run-installed-sparkle-canary.sh" >/dev/null 2>&1; then
        fail "unsigned fixture override trusted caller-controlled TMPDIR without a validated fixture root"
    fi
}

test_unsigned_fixture_override_rejects_symlink_escape() {
    local real_app_path="$OUTSIDE_WORK_DIR/SafeMac AV.app"

    write_info_plist "$real_app_path" "https://updates.example.com/appcast.xml" 1
    rm -rf "$APP_PATH"
    ln -s "$real_app_path" "$APP_PATH"
    if PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
       SPARKLE_LOG="$SPARKLE_LOG" \
       SPARKLE_CLI="$FAKE_BIN/sparkle" \
       CANARY_CODESIGN_VERIFY_FAIL=1 \
       SAFEMAC_CANARY_APP_PATH="$APP_PATH" \
       SAFEMAC_CANARY_TEST_ONLY_ALLOW_UNSIGNED_FIXTURE=1 \
        "$PROJECT_DIR/scripts/run-installed-sparkle-canary.sh" >/dev/null 2>&1; then
        fail "unsigned fixture override accepted a symlinked app outside the temporary directory"
    fi
    rm -f "$APP_PATH"
}

test_placeholder_feed_is_rejected() {
    write_info_plist "$APP_PATH" '$(SPARKLE_FEED_URL)' 1

    if run_canary >/dev/null 2>&1; then
        fail "placeholder Sparkle feed URL was accepted"
    fi
}

test_expected_update_fails_when_probe_reports_no_update() {
    write_info_plist "$APP_PATH" "https://updates.example.com/appcast.xml" 1

    if PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
       SPARKLE_LOG="$SPARKLE_LOG" \
       SPARKLE_CLI="$FAKE_BIN/sparkle" \
       SPARKLE_PROBE_STATUS=4 \
       SAFEMAC_CANARY_APP_PATH="$APP_PATH" \
       SAFEMAC_CANARY_EXPECT_UPDATE=1 \
            "$PROJECT_DIR/scripts/run-installed-sparkle-canary.sh" >/dev/null 2>&1; then
        fail "expected-update canary accepted no-update probe result"
    fi
}

main() {
    make_fake_tools
    test_probe_invokes_sparkle_cli_against_temp_copy
    test_install_mode_updates_temp_copy
    test_install_mode_verifies_updated_temp_copy_policy
    test_installed_app_signature_policy_failures
    test_unsigned_fixture_override
    test_unsigned_fixture_override_covers_script_created_copy
    test_unsigned_fixture_override_is_temp_scoped
    test_unsigned_fixture_override_requires_explicit_root
    test_unsigned_fixture_override_rejects_symlink_escape
    test_placeholder_feed_is_rejected
    test_expected_update_fails_when_probe_reports_no_update
    printf 'run installed Sparkle canary tests passed\n'
}

main "$@"

#!/bin/bash

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/safemac-signing-test.XXXXXX")"
FAKE_BIN="$WORK_DIR/bin"
SIGN_LOG="$WORK_DIR/codesign.log"
LSREGISTER_LOG="$WORK_DIR/lsregister.log"
TEST_IDENTITY="AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"

cleanup() {
    rm -rf "$WORK_DIR"
    rm -rf "$PROJECT_DIR/build"
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

make_fake_tools() {
    mkdir -p "$FAKE_BIN"

    write_fake_tool security '
if [[ "${1:-}" == "find-identity" ]]; then
    printf "  1) %s \"Developer ID Application: SafeMac Test (TESTTEAM01)\"\n" "${TEST_IDENTITY:?}"
    printf "     1 valid identities found\n"
fi'

    write_fake_tool xcodebuild '
archive_path=""
while (($#)); do
    if [[ "$1" == "-archivePath" ]]; then
        archive_path="$2"
        shift 2
        continue
    fi
    shift
done
[[ -n "$archive_path" ]]
app="$archive_path/Products/Applications/ClamAV-GUI.app"
sparkle="$app/Contents/Frameworks/Sparkle.framework/Versions/B"
mkdir -p \
    "$app/Contents/MacOS" \
    "$app/Contents/PlugIns/ClamAV-GUI-Finder.appex/Contents/MacOS" \
    "$sparkle/Updater.app/Contents/MacOS" \
    "$sparkle/XPCServices/Downloader.xpc/Contents/MacOS" \
    "$sparkle/XPCServices/Installer.xpc/Contents/MacOS"
printf app > "$app/Contents/MacOS/ClamAV-GUI"
printf finder > "$app/Contents/PlugIns/ClamAV-GUI-Finder.appex/Contents/MacOS/ClamAV-GUI-Finder"
printf sparkle > "$sparkle/Sparkle"
printf autoupdate > "$sparkle/Autoupdate"
printf updater > "$sparkle/Updater.app/Contents/MacOS/Updater"
printf downloader > "$sparkle/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
printf installer > "$sparkle/XPCServices/Installer.xpc/Contents/MacOS/Installer"
chmod +x \
    "$app/Contents/MacOS/ClamAV-GUI" \
    "$app/Contents/PlugIns/ClamAV-GUI-Finder.appex/Contents/MacOS/ClamAV-GUI-Finder" \
    "$sparkle/Sparkle" \
    "$sparkle/Autoupdate" \
    "$sparkle/Updater.app/Contents/MacOS/Updater" \
    "$sparkle/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
    "$sparkle/XPCServices/Installer.xpc/Contents/MacOS/Installer"'

    write_fake_tool ditto '
source_path="$1"
destination_path="$2"
/bin/cp -R "$source_path" "$destination_path"'

    write_fake_tool codesign '
if [[ " $* " == *" --sign "* ]]; then
    has_runtime=false
    has_timestamp=false
    has_identity=false
    preserves_metadata=false
    entitlement_path=""
    previous=""
    for argument in "$@"; do
        [[ "$previous" != "--options" || "$argument" != "runtime" ]] || has_runtime=true
        [[ "$argument" != "--timestamp" ]] || has_timestamp=true
        [[ "$previous" != "--sign" || "$argument" != "${TEST_IDENTITY:?}" ]] || has_identity=true
        [[ "$argument" != "--preserve-metadata=identifier,entitlements,requirements" ]] || preserves_metadata=true
        if [[ "$previous" == "--entitlements" ]]; then
            entitlement_path="$argument"
        fi
        previous="$argument"
    done
    printf "%s\truntime=%s timestamp=%s identity=%s preserves_metadata=%s entitlements=%s\n" \
        "${!#}" "$has_runtime" "$has_timestamp" "$has_identity" "$preserves_metadata" "$entitlement_path" >> "${SIGN_LOG:?}"
fi
if [[ " $* " == *" -dv "* ]]; then
    printf "%s\n" \
        "Authority=Developer ID Application: SafeMac Test (TESTTEAM01)" \
        "TeamIdentifier=TESTTEAM01" \
        "Timestamp=Aug 22, 2026 at 02:00:00" \
        "CodeDirectory v=20500 flags=0x10000(runtime)" >&2
elif [[ " $* " == *" --entitlements "* ]]; then
    target="${!#}"
    if [[ "$target" == *"/Sparkle.framework/Versions/B/Autoupdate" ]]; then
        printf "%s\n" "<plist><dict><key>com.apple.application-identifier</key><string>org.sparkle-project.Sparkle.Autoupdate</string></dict></plist>"
    elif [[ "$target" == *"/SafeMac AV.app" ]]; then
        printf "%s\n" "<plist><dict><key>com.apple.security.application-groups</key><array><string>CQPH8YR62A.com.newtonlorenz.ClamAV-GUI</string></array></dict></plist>"
    elif [[ "$target" == *"/ClamAV-GUI-Finder.appex" ]]; then
        printf "%s\n" "<plist><dict><key>com.apple.security.app-sandbox</key><true/><key>com.apple.security.application-groups</key><array><string>CQPH8YR62A.com.newtonlorenz.ClamAV-GUI</string></array></dict></plist>"
    fi
fi'

    write_fake_tool hdiutil '
if [[ "${1:-}" == "create" ]]; then
    printf dmg > "${!#}"
    exit "${MOCK_HDIUTIL_STATUS:-0}"
fi'

    write_fake_tool lipo 'printf "x86_64 arm64\n"'

    write_fake_tool lsregister '
[[ "$#" -eq 2 && "$1" == "-u" ]] || exit 93
printf "%s\n" "$2" >> "${LSREGISTER_LOG:?}"'
}

line_for_target() {
    local target="$1"
    awk -F '\t' -v target="$target" '$1 == target { print NR; exit }' "$SIGN_LOG"
}

assert_signed_with_distribution_options() {
    local target="$1"
    local must_preserve_metadata="${2:-true}"
    local expected_entitlements="${3:-}"
    local line

    line="$(awk -F '\t' -v target="$target" '$1 == target { print $2; exit }' "$SIGN_LOG")"
    [[ -n "$line" ]] || fail "nested code was not signed: $target"
    [[ "$line" == *"runtime=true"* ]] || fail "hardened runtime missing: $target"
    [[ "$line" == *"timestamp=true"* ]] || fail "secure timestamp missing: $target"
    [[ "$line" == *"identity=true"* ]] || fail "resolved Developer ID identity missing: $target"
    if [[ "$must_preserve_metadata" == "true" ]]; then
        [[ "$line" == *"preserves_metadata=true"* ]] || fail "signature metadata was not preserved: $target"
    fi
    if [[ -n "$expected_entitlements" ]]; then
        [[ "$line" == *"entitlements=$expected_entitlements"* ]] || fail "expected entitlements were not used: $target"
    fi
}

assert_before() {
    local first="$1"
    local second="$2"
    local first_line
    local second_line

    first_line="$(line_for_target "$first")"
    second_line="$(line_for_target "$second")"
    [[ -n "$first_line" && -n "$second_line" ]] || fail "cannot compare signing order"
    ((first_line < second_line)) || fail "expected $first to be signed before $second"
}

run_packaging() {
    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    TEST_IDENTITY="$TEST_IDENTITY" \
    SIGN_LOG="$SIGN_LOG" \
    LSREGISTER_LOG="$LSREGISTER_LOG" \
    LSREGISTER_BIN="$FAKE_BIN/lsregister" \
    SIGNING_IDENTITY="$TEST_IDENTITY" \
        "$PROJECT_DIR/scripts/create-dmg.sh" >/dev/null
}

run_failed_packaging() {
    set +e
    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    TEST_IDENTITY="$TEST_IDENTITY" \
    SIGN_LOG="$SIGN_LOG" \
    LSREGISTER_LOG="$LSREGISTER_LOG" \
    LSREGISTER_BIN="$FAKE_BIN/lsregister" \
    MOCK_HDIUTIL_STATUS=41 \
    SIGNING_IDENTITY="$TEST_IDENTITY" \
        "$PROJECT_DIR/scripts/create-dmg.sh" >/dev/null 2>&1
    PACKAGING_STATUS=$?
    set -e
}

verify_build_products_unregistered() {
    local expected="$WORK_DIR/expected-unregister-targets.txt"
    local actual="$WORK_DIR/actual-unregister-targets.txt"

    printf '%s\n' \
        "$PROJECT_DIR/build/ClamAV-GUI.xcarchive/Products/Applications/ClamAV-GUI.app" \
        "$PROJECT_DIR/build/export/SafeMac AV.app" \
        | sort > "$expected"
    sort "$LSREGISTER_LOG" > "$actual"
    cmp -s "$expected" "$actual" \
        || fail "packaging did not unregister exactly the archived and exported app bundles"
}

verify_required_build_products_unregistered() {
    grep -Fxq \
        "$PROJECT_DIR/build/ClamAV-GUI.xcarchive/Products/Applications/ClamAV-GUI.app" \
        "$LSREGISTER_LOG" \
        || fail "failed packaging did not unregister the archived app bundle"
    grep -Fxq \
        "$PROJECT_DIR/build/export/SafeMac AV.app" \
        "$LSREGISTER_LOG" \
        || fail "failed packaging did not unregister the exported app bundle"
    if grep -Fq '/Applications/SafeMac AV.app' "$LSREGISTER_LOG"; then
        fail "packaging cleanup targeted the installed SafeMac AV app"
    fi
}

verify_signing_order() {
    local app="$PROJECT_DIR/build/export/SafeMac AV.app"
    local sparkle="$app/Contents/Frameworks/Sparkle.framework"
    local version="$sparkle/Versions/B"
    local updater="$version/Updater.app"
    local downloader="$version/XPCServices/Downloader.xpc"
    local installer="$version/XPCServices/Installer.xpc"
    local autoupdate="$version/Autoupdate"
    local appex="$app/Contents/PlugIns/ClamAV-GUI-Finder.appex"

    assert_signed_with_distribution_options "$updater"
    assert_signed_with_distribution_options "$downloader"
    assert_signed_with_distribution_options "$installer"
    assert_signed_with_distribution_options "$autoupdate"
    assert_signed_with_distribution_options "$sparkle"
    assert_signed_with_distribution_options "$appex" false "$PROJECT_DIR/ClamAV-GUI-Finder/ClamAV_GUI_Finder.entitlements"
    assert_signed_with_distribution_options "$app" false

    assert_before "$autoupdate" "$sparkle"
    assert_before "$downloader" "$sparkle"
    assert_before "$installer" "$sparkle"
    assert_before "$updater" "$sparkle"
    assert_before "$sparkle" "$app"
    assert_before "$appex" "$app"
}

main() {
    make_fake_tools
    : > "$LSREGISTER_LOG"
    run_packaging
    verify_signing_order
    verify_build_products_unregistered
    : > "$LSREGISTER_LOG"
    run_failed_packaging
    [[ "$PACKAGING_STATUS" -eq 41 ]] \
        || fail "cleanup did not preserve the packaging failure status"
    verify_required_build_products_unregistered
    printf 'create-dmg signing tests passed\n'
}

main "$@"

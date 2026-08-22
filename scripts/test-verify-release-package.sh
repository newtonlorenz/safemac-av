#!/bin/bash

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/safemac-release-test.XXXXXX")"

cleanup() {
    rm -rf "$WORK_DIR"
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
    } > "$WORK_DIR/bin/$name"
    chmod +x "$WORK_DIR/bin/$name"
}

make_fixture() {
    local package_dir="$WORK_DIR/package"
    local app_dir="$WORK_DIR/SafeMac AV.app"
    local sparkle_dir="$app_dir/Contents/Frameworks/Sparkle.framework/Versions/B"

    mkdir -p \
        "$package_dir/appcast" \
        "$app_dir/Contents/MacOS" \
        "$app_dir/Contents/PlugIns/ClamAV-GUI-Finder.appex/Contents/MacOS" \
        "$sparkle_dir/Updater.app/Contents/MacOS" \
        "$sparkle_dir/XPCServices/Downloader.xpc/Contents/MacOS" \
        "$sparkle_dir/XPCServices/Installer.xpc/Contents/MacOS" \
        "$WORK_DIR/bin"
    printf 'fake dmg\n' > "$package_dir/SafeMac-AV.dmg"
    (cd "$package_dir" && shasum -a 256 SafeMac-AV.dmg > SHA256SUMS.txt)

    cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleShortVersionString</key>
    <string>1.2.0</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>CFBundleExecutable</key>
    <string>ClamAV-GUI</string>
</dict>
</plist>
PLIST
    printf '#!/bin/bash\n' > "$app_dir/Contents/MacOS/ClamAV-GUI"
    printf 'finder\n' > "$app_dir/Contents/PlugIns/ClamAV-GUI-Finder.appex/Contents/MacOS/ClamAV-GUI-Finder"
    chmod +x "$app_dir/Contents/MacOS/ClamAV-GUI"
    chmod +x "$app_dir/Contents/PlugIns/ClamAV-GUI-Finder.appex/Contents/MacOS/ClamAV-GUI-Finder"

    printf 'sparkle\n' > "$sparkle_dir/Sparkle"
    printf 'autoupdate\n' > "$sparkle_dir/Autoupdate"
    printf 'updater\n' > "$sparkle_dir/Updater.app/Contents/MacOS/Updater"
    printf 'downloader\n' > "$sparkle_dir/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
    printf 'installer\n' > "$sparkle_dir/XPCServices/Installer.xpc/Contents/MacOS/Installer"
    chmod +x \
        "$sparkle_dir/Sparkle" \
        "$sparkle_dir/Autoupdate" \
        "$sparkle_dir/Updater.app/Contents/MacOS/Updater" \
        "$sparkle_dir/XPCServices/Downloader.xpc/Contents/MacOS/Downloader" \
        "$sparkle_dir/XPCServices/Installer.xpc/Contents/MacOS/Installer"

    cat > "$package_dir/appcast/appcast.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <item>
      <enclosure url="https://example.com/SafeMac-AV.dmg" sparkle:version="3" sparkle:shortVersionString="1.2.0" sparkle:edSignature="signed" />
    </item>
  </channel>
</rss>
XML
}

make_fake_tools() {
    write_fake_tool codesign '
target="${!#}"
if [[ " $* " == *" -dv "* ]]; then
    if [[ "$target" == "${ADHOC_CODESIGN_PATH:-}" ]]; then
        printf "%s\n" \
            "Authority=adhoc" \
            "TeamIdentifier=not set" \
            "Timestamp=none" \
            "CodeDirectory v=20500 flags=0x10002(adhoc,runtime)" >&2
    else
        team_id="TESTTEAM01"
        timestamp="Timestamp=Aug 22, 2026 at 02:00:00"
        flags="CodeDirectory v=20500 flags=0x10000(runtime)"
        [[ "$target" != "${WRONG_TEAM_CODESIGN_PATH:-}" ]] || team_id="OTHERTEAM2"
        [[ "$target" != "${MISSING_TIMESTAMP_PATH:-}" ]] || timestamp="Timestamp=none"
        [[ "$target" != "${MISSING_RUNTIME_PATH:-}" ]] || flags="CodeDirectory v=20500 flags=0x0(none)"
        printf "%s\n" \
            "Authority=Developer ID Application: SafeMac Test (TESTTEAM01)" \
            "TeamIdentifier=$team_id" \
            "$timestamp" \
            "$flags" >&2
    fi
fi
if [[ " $* " == *" --entitlements :- "* && "$target" != "${MISSING_AUTOUPDATE_ENTITLEMENT_PATH:-}" ]]; then
    printf "%s\n" "<plist><dict><key>com.apple.application-identifier</key><string>org.sparkle-project.Sparkle.Autoupdate</string></dict></plist>"
fi
if [[ " $* " == *" --entitlements - --xml "* ]]; then
    app_path="${SAFEMAC_VERIFY_APP_PATH:?}"
    if [[ "$target" == "$app_path" ]]; then
        group="${APP_GROUP_ENTITLEMENT:-TESTTEAM01.com.newtonlorenz.ClamAV-GUI}"
        sandbox="false"
    else
        group="${FINDER_GROUP_ENTITLEMENT:-TESTTEAM01.com.newtonlorenz.ClamAV-GUI}"
        sandbox="${FINDER_SANDBOX_ENTITLEMENT:-true}"
    fi
    printf "%s\n" "<plist><dict><key>com.apple.security.application-groups</key><array><string>$group</string></array><key>com.apple.security.app-sandbox</key><$sandbox/></dict></plist>"
fi
exit 0'
    write_fake_tool spctl 'exit 0'
    write_fake_tool xcrun '[[ "${1:-}" == "stapler" && "${2:-}" == "validate" ]] || exit 2'
    write_fake_tool lipo '
target="${!#}"
if [[ "$target" == "${NON_UNIVERSAL_PATH:-}" ]]; then
    printf "arm64\n"
else
    printf "%s\n" "${LIPO_ARCHS:-x86_64 arm64}"
fi'
}

run_success_case() {
    PATH="$WORK_DIR/bin:$PATH" \
    SAFEMAC_VERIFY_APP_PATH="$WORK_DIR/SafeMac AV.app" \
        "$PROJECT_DIR/scripts/verify-release-package.sh" "$WORK_DIR/package" >/dev/null
}

run_arch_failure_case() {
    if PATH="$WORK_DIR/bin:$PATH" \
       LIPO_ARCHS="arm64" \
       SAFEMAC_VERIFY_APP_PATH="$WORK_DIR/SafeMac AV.app" \
        "$PROJECT_DIR/scripts/verify-release-package.sh" "$WORK_DIR/package" >/dev/null 2>&1; then
        fail "missing x86_64 architecture was accepted"
    fi
}

run_appcast_failure_case() {
    perl -0pi -e 's/sparkle:version="3"/sparkle:version="4"/' "$WORK_DIR/package/appcast/appcast.xml"
    if PATH="$WORK_DIR/bin:$PATH" \
       SAFEMAC_VERIFY_APP_PATH="$WORK_DIR/SafeMac AV.app" \
        "$PROJECT_DIR/scripts/verify-release-package.sh" "$WORK_DIR/package" >/dev/null 2>&1; then
        fail "mismatched appcast version was accepted"
    fi
    perl -0pi -e 's/sparkle:version="4"/sparkle:version="3"/' "$WORK_DIR/package/appcast/appcast.xml"
}

run_nested_adhoc_failure_cases() {
    local app_dir="$WORK_DIR/SafeMac AV.app"
    local sparkle_dir="$app_dir/Contents/Frameworks/Sparkle.framework/Versions/B"
    local component
    local -a components=(
        "$sparkle_dir/Updater.app"
        "$sparkle_dir/XPCServices/Downloader.xpc"
        "$sparkle_dir/XPCServices/Installer.xpc"
        "$sparkle_dir/Autoupdate"
        "$app_dir/Contents/Frameworks/Sparkle.framework"
        "$app_dir/Contents/PlugIns/ClamAV-GUI-Finder.appex"
    )

    for component in "${components[@]}"; do
        if PATH="$WORK_DIR/bin:$PATH" \
           ADHOC_CODESIGN_PATH="$component" \
           SAFEMAC_VERIFY_APP_PATH="$app_dir" \
            "$PROJECT_DIR/scripts/verify-release-package.sh" "$WORK_DIR/package" >/dev/null 2>&1; then
            fail "ad-hoc nested Sparkle component was accepted: $component"
        fi
    done
}

run_nested_arch_failure_case() {
    local component="$WORK_DIR/SafeMac AV.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"

    if PATH="$WORK_DIR/bin:$PATH" \
       NON_UNIVERSAL_PATH="$component" \
       SAFEMAC_VERIFY_APP_PATH="$WORK_DIR/SafeMac AV.app" \
        "$PROJECT_DIR/scripts/verify-release-package.sh" "$WORK_DIR/package" >/dev/null 2>&1; then
        fail "non-universal nested Sparkle component was accepted"
    fi
}

run_nested_signature_policy_failure_cases() {
    local component="$WORK_DIR/SafeMac AV.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
    local variable
    local -a variables=(
        WRONG_TEAM_CODESIGN_PATH
        MISSING_TIMESTAMP_PATH
        MISSING_RUNTIME_PATH
    )

    for variable in "${variables[@]}"; do
        if env \
            PATH="$WORK_DIR/bin:$PATH" \
            "$variable=$component" \
            SAFEMAC_VERIFY_APP_PATH="$WORK_DIR/SafeMac AV.app" \
            "$PROJECT_DIR/scripts/verify-release-package.sh" "$WORK_DIR/package" >/dev/null 2>&1; then
            fail "invalid nested Sparkle signature policy was accepted: $variable"
        fi
    done
}

run_missing_autoupdate_entitlement_case() {
    local component="$WORK_DIR/SafeMac AV.app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"

    if PATH="$WORK_DIR/bin:$PATH" \
       MISSING_AUTOUPDATE_ENTITLEMENT_PATH="$component" \
       SAFEMAC_VERIFY_APP_PATH="$WORK_DIR/SafeMac AV.app" \
        "$PROJECT_DIR/scripts/verify-release-package.sh" "$WORK_DIR/package" >/dev/null 2>&1; then
        fail "missing Sparkle Autoupdate entitlement was accepted"
    fi
}

run_finder_entitlement_failure_cases() {
    local variable
    local -a variables=(
        APP_GROUP_ENTITLEMENT
        FINDER_GROUP_ENTITLEMENT
        FINDER_SANDBOX_ENTITLEMENT
    )

    for variable in "${variables[@]}"; do
        local value="WRONGTEAM.com.newtonlorenz.ClamAV-GUI"
        [[ "$variable" != "FINDER_SANDBOX_ENTITLEMENT" ]] || value="false"
        if env \
            PATH="$WORK_DIR/bin:$PATH" \
            "$variable=$value" \
            SAFEMAC_VERIFY_APP_PATH="$WORK_DIR/SafeMac AV.app" \
            "$PROJECT_DIR/scripts/verify-release-package.sh" "$WORK_DIR/package" >/dev/null 2>&1; then
            fail "invalid Finder handoff entitlement was accepted: $variable"
        fi
    done
}

main() {
    make_fixture
    make_fake_tools
    run_success_case
    run_arch_failure_case
    run_nested_adhoc_failure_cases
    run_nested_arch_failure_case
    run_nested_signature_policy_failure_cases
    run_missing_autoupdate_entitlement_case
    run_finder_entitlement_failure_cases
    run_appcast_failure_case
    printf 'verify-release-package tests passed\n'
}

main "$@"

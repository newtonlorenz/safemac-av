#!/bin/bash

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SYSTEM_TEMP_ROOT="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)"
SYSTEM_TEMP_ROOT="${SYSTEM_TEMP_ROOT%/}"
WORK_DIR="$(mktemp -d "$SYSTEM_TEMP_ROOT/safemac-release-test.XXXXXX")"
OUTSIDE_WORK_DIR="$(mktemp -d "$SYSTEM_TEMP_ROOT/safemac-release-outside.XXXXXX")"
WORK_DIR="$(cd "$WORK_DIR" && pwd -P)"
OUTSIDE_WORK_DIR="$(cd "$OUTSIDE_WORK_DIR" && pwd -P)"

cleanup() {
    local status=$?

    trap - EXIT
    set +e
    if [[ -x "$PROJECT_DIR/scripts/clean-build-registrations.sh" ]]; then
        LSREGISTER_BIN="${TEST_LSREGISTER_BIN:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}" \
            "$PROJECT_DIR/scripts/clean-build-registrations.sh" "$WORK_DIR" >/dev/null 2>&1 || true
        LSREGISTER_BIN="${TEST_LSREGISTER_BIN:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}" \
            "$PROJECT_DIR/scripts/clean-build-registrations.sh" "$OUTSIDE_WORK_DIR" >/dev/null 2>&1 || true
    fi
    rm -rf "$WORK_DIR"
    rm -rf "$OUTSIDE_WORK_DIR"
    return "$status"
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
    local helper_dir="$app_dir/Contents/Library/LoginItems/SafeMacAVBackground.app"

    mkdir -p \
        "$package_dir/appcast" \
        "$app_dir/Contents/MacOS" \
        "$helper_dir/Contents/MacOS" \
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
    <key>SUFeedURL</key>
    <string>https://updates.example.com/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>__SPARKLE_PUBLIC_ED_KEY__</string>
    <key>SURequireSignedFeed</key>
    <true/>
    <key>SUVerifyUpdateBeforeExtraction</key>
    <true/>
</dict>
</plist>
PLIST
    printf '#!/bin/bash\n' > "$app_dir/Contents/MacOS/ClamAV-GUI"
    printf 'finder\n' > "$app_dir/Contents/PlugIns/ClamAV-GUI-Finder.appex/Contents/MacOS/ClamAV-GUI-Finder"
    chmod +x "$app_dir/Contents/MacOS/ClamAV-GUI"
    printf '#!/bin/bash\n' > "$helper_dir/Contents/MacOS/SafeMacAVBackground"
    chmod +x "$helper_dir/Contents/MacOS/SafeMacAVBackground"
    cat > "$helper_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>CFBundleIdentifier</key><string>com.newtonlorenz.ClamAV-GUI.Background</string>
    <key>CFBundleExecutable</key><string>SafeMacAVBackground</string>
    <key>LSUIElement</key><true/>
</dict></plist>
PLIST
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

    swift - "$package_dir/SafeMac-AV.dmg" "$package_dir/appcast/appcast.xml" "$app_dir/Contents/Info.plist" "$WORK_DIR/sparkle-public-key.txt" <<'SWIFT'
import CryptoKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let dmgPath = arguments[0]
let appcastPath = arguments[1]
let infoPlistPath = arguments[2]
let publicKeyPath = arguments[3]

let seed = Data(repeating: 1, count: 32)
let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
let publicKeyBase64 = privateKey.publicKey.rawRepresentation.base64EncodedString()
let archiveSignature = try privateKey.signature(for: Data(contentsOf: URL(fileURLWithPath: dmgPath))).base64EncodedString()
let content = """
<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <item>
      <sparkle:version>3</sparkle:version>
      <sparkle:shortVersionString>1.2.0</sparkle:shortVersionString>
      <enclosure url="https://downloads.example.com/SafeMac-AV.dmg" length="\(try Data(contentsOf: URL(fileURLWithPath: dmgPath)).count)" sparkle:edSignature="\(archiveSignature)" />
    </item>
  </channel>
</rss>
"""
let contentWithTrailingNewline = content + "\n"
let feedSignature = try privateKey.signature(for: Data(contentWithTrailingNewline.utf8)).base64EncodedString()
let signedAppcast = "\(contentWithTrailingNewline)<!-- sparkle-signatures:\nedSignature: \(feedSignature)\nlength: \(contentWithTrailingNewline.utf8.count)\n-->\n"
try signedAppcast.write(to: URL(fileURLWithPath: appcastPath), atomically: true, encoding: .utf8)
try publicKeyBase64.write(to: URL(fileURLWithPath: publicKeyPath), atomically: true, encoding: .utf8)
let plist = try String(contentsOfFile: infoPlistPath, encoding: .utf8)
try plist.replacingOccurrences(of: "__SPARKLE_PUBLIC_ED_KEY__", with: publicKeyBase64)
    .write(to: URL(fileURLWithPath: infoPlistPath), atomically: true, encoding: .utf8)
SWIFT
}

configure_test_app_override() {
    printf 'SafeMac release verifier app fixture\n' > "$WORK_DIR/.safemac-release-verify-app-fixture"
    chmod 600 "$WORK_DIR/.safemac-release-verify-app-fixture"
    export SAFEMAC_VERIFY_TEST_ONLY_ALLOW_APP_OVERRIDE=1
    export SAFEMAC_VERIFY_TEST_ONLY_FIXTURE_ROOT="$WORK_DIR"
    export SAFEMAC_VERIFY_APP_PATH="$WORK_DIR/SafeMac AV.app"
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
    if [[ "$target" == */SafeMacAVBackground.app ]]; then
        if [[ "${BACKGROUND_HELPER_ENTITLEMENT_MODE:-valid}" == "valid" ]]; then
            printf "%s\n" "<plist><dict><key>com.apple.security.app-sandbox</key><false/></dict></plist>"
        elif [[ "${BACKGROUND_HELPER_ENTITLEMENT_MODE:-}" == "sandbox-true-with-unrelated-false" ]]; then
            printf "%s\n" "<plist><dict><key>com.apple.security.app-sandbox</key><true/><key>com.apple.security.get-task-allow</key><false/></dict></plist>"
        else
            printf "%s\n" "<plist><dict><key>com.apple.security.application-groups</key><array><string>unexpected</string></array></dict></plist>"
        fi
    else
        printf "%s\n" "<plist><dict><key>com.apple.application-identifier</key><string>org.sparkle-project.Sparkle.Autoupdate</string></dict></plist>"
    fi
fi
if [[ " $* " == *" --entitlements - --xml "* ]]; then
    if [[ "$target" == */SafeMac\ AV.app ]]; then
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
    write_fake_tool lsregister '
printf "unregister:%s\n" "${2:?}" >> "${CLEANUP_EVENT_LOG:?}"'
    write_fake_tool hdiutil '
case "${1:-}" in
    attach)
        mount_point="${!#}"
        cp -R "${HDIUTIL_FIXTURE_APP:?}" "$mount_point/SafeMac AV.app"
        ;;
    detach)
        printf "detach:%s\n" "${2:?}" >> "${CLEANUP_EVENT_LOG:?}"
        rm -rf "${2:?}/SafeMac AV.app"
        ;;
    *) exit 2 ;;
esac'
    TEST_LSREGISTER_BIN="$WORK_DIR/bin/lsregister"
    CLEANUP_EVENT_LOG="$WORK_DIR/fixture-cleanup-events.log"
    : > "$CLEANUP_EVENT_LOG"
    export TEST_LSREGISTER_BIN
    export CLEANUP_EVENT_LOG
}

run_success_case() {
    PATH="$WORK_DIR/bin:$PATH" \
    EXPECTED_SPARKLE_FEED_URL="https://updates.example.com/appcast.xml" \
    EXPECTED_SPARKLE_PUBLIC_ED_KEY="$(cat "$WORK_DIR/sparkle-public-key.txt")" \
    EXPECTED_SPARKLE_DOWNLOAD_URL_PREFIX="https://downloads.example.com/" \
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

assert_mounted_cleanup_events() {
    local mount_root
    local expected
    local actual

    mount_root="$(sed -n 's/^detach://p' "$WORK_DIR/mounted-cleanup-events.log")"
    [[ -n "$mount_root" ]] || fail "temporary DMG mount was not detached"
    expected="unregister:$mount_root/SafeMac AV.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app
unregister:$mount_root/SafeMac AV.app
detach:$mount_root"
    actual="$(cat "$WORK_DIR/mounted-cleanup-events.log")"
    [[ "$actual" == "$expected" ]] \
        || fail "temporary DMG app was not unregistered from its exact mount root before detach"
    [[ "$mount_root" != /Applications && "$mount_root" != /Applications/* ]] \
        || fail "temporary DMG cleanup targeted /Applications"
}

run_mounted_cleanup_case() {
    : > "$WORK_DIR/mounted-cleanup-events.log"
    if ! env \
        -u SAFEMAC_VERIFY_APP_PATH \
        -u SAFEMAC_VERIFY_TEST_ONLY_ALLOW_APP_OVERRIDE \
        -u SAFEMAC_VERIFY_TEST_ONLY_FIXTURE_ROOT \
        PATH="$WORK_DIR/bin:$PATH" \
        CLEANUP_EVENT_LOG="$WORK_DIR/mounted-cleanup-events.log" \
        HDIUTIL_FIXTURE_APP="$WORK_DIR/SafeMac AV.app" \
        LSREGISTER_BIN="$WORK_DIR/bin/lsregister" \
        EXPECTED_SPARKLE_FEED_URL="https://updates.example.com/appcast.xml" \
        EXPECTED_SPARKLE_PUBLIC_ED_KEY="$(cat "$WORK_DIR/sparkle-public-key.txt")" \
        EXPECTED_SPARKLE_DOWNLOAD_URL_PREFIX="https://downloads.example.com/" \
        "$PROJECT_DIR/scripts/verify-release-package.sh" "$WORK_DIR/package" >/dev/null; then
        fail "mounted release verification failed"
    fi
    assert_mounted_cleanup_events
}

run_mounted_failure_cleanup_case() {
    : > "$WORK_DIR/mounted-cleanup-events.log"
    if env \
        -u SAFEMAC_VERIFY_APP_PATH \
        -u SAFEMAC_VERIFY_TEST_ONLY_ALLOW_APP_OVERRIDE \
        -u SAFEMAC_VERIFY_TEST_ONLY_FIXTURE_ROOT \
        PATH="$WORK_DIR/bin:$PATH" \
        CLEANUP_EVENT_LOG="$WORK_DIR/mounted-cleanup-events.log" \
        HDIUTIL_FIXTURE_APP="$WORK_DIR/SafeMac AV.app" \
        LSREGISTER_BIN="$WORK_DIR/bin/lsregister" \
        LIPO_ARCHS="arm64" \
        "$PROJECT_DIR/scripts/verify-release-package.sh" "$WORK_DIR/package" >/dev/null 2>&1; then
        fail "mounted release architecture failure was accepted"
    fi
    assert_mounted_cleanup_events
}

run_unscoped_app_override_failure_cases() {
    if env \
       -u SAFEMAC_VERIFY_TEST_ONLY_ALLOW_APP_OVERRIDE \
       -u SAFEMAC_VERIFY_TEST_ONLY_FIXTURE_ROOT \
       SAFEMAC_VERIFY_APP_PATH="$WORK_DIR/SafeMac AV.app" \
       PATH="$WORK_DIR/bin:$PATH" \
        "$PROJECT_DIR/scripts/verify-release-package.sh" "$WORK_DIR/package" >/dev/null 2>&1; then
        fail "unscoped release app override was accepted"
    fi

    cp -R "$WORK_DIR/SafeMac AV.app" "$OUTSIDE_WORK_DIR/SafeMac AV.app"
    ln -s "$OUTSIDE_WORK_DIR/SafeMac AV.app" "$WORK_DIR/Symlinked SafeMac AV.app"
    if SAFEMAC_VERIFY_APP_PATH="$WORK_DIR/Symlinked SafeMac AV.app" \
       PATH="$WORK_DIR/bin:$PATH" \
        "$PROJECT_DIR/scripts/verify-release-package.sh" "$WORK_DIR/package" >/dev/null 2>&1; then
        fail "symlinked release app override escaped its fixture root"
    fi
}

run_fixture_root_cleanup_case() {
    local expected
    local actual

    : > "$CLEANUP_EVENT_LOG"
    LSREGISTER_BIN="$TEST_LSREGISTER_BIN" \
        "$PROJECT_DIR/scripts/clean-build-registrations.sh" "$WORK_DIR"
    LSREGISTER_BIN="$TEST_LSREGISTER_BIN" \
        "$PROJECT_DIR/scripts/clean-build-registrations.sh" "$OUTSIDE_WORK_DIR"
    expected="unregister:$WORK_DIR/SafeMac AV.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app
unregister:$WORK_DIR/SafeMac AV.app
unregister:$OUTSIDE_WORK_DIR/SafeMac AV.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app
unregister:$OUTSIDE_WORK_DIR/SafeMac AV.app"
    actual="$(cat "$CLEANUP_EVENT_LOG")"
    [[ "$actual" == "$expected" ]] \
        || fail "test fixture roots were not cleaned independently by exact root"
}

run_embedded_feed_url_failure_cases() {
    local original_url="https://updates.example.com/appcast.xml"
    local invalid_url
    local -a invalid_urls=(
        "https://user@updates.example.com/appcast.xml"
        "https://user:password@updates.example.com/appcast.xml"
        "https://updates.example.com/appcast.xml?token=secret"
        "https://updates.example.com/appcast.xml#fragment"
    )

    for invalid_url in "${invalid_urls[@]}"; do
        cp "$WORK_DIR/SafeMac AV.app/Contents/Info.plist" "$WORK_DIR/Info.plist.bak"
        INVALID_URL="$invalid_url" perl -0pi -e \
            's|https://updates\.example\.com/appcast\.xml|$ENV{INVALID_URL}|' \
            "$WORK_DIR/SafeMac AV.app/Contents/Info.plist"
        if PATH="$WORK_DIR/bin:$PATH" \
           EXPECTED_SPARKLE_FEED_URL="$invalid_url" \
           SAFEMAC_VERIFY_APP_PATH="$WORK_DIR/SafeMac AV.app" \
            "$PROJECT_DIR/scripts/verify-release-package.sh" "$WORK_DIR/package" >/dev/null 2>&1; then
            fail "unsafe embedded Sparkle feed URL was accepted: $invalid_url"
        fi
        mv "$WORK_DIR/Info.plist.bak" "$WORK_DIR/SafeMac AV.app/Contents/Info.plist"
        grep -Fq "$original_url" "$WORK_DIR/SafeMac AV.app/Contents/Info.plist" \
            || fail "embedded Sparkle feed URL fixture was not restored"
    done
}

run_appcast_failure_case() {
    perl -0pi -e 's|<sparkle:version>3</sparkle:version>|<sparkle:version>4</sparkle:version>|' "$WORK_DIR/package/appcast/appcast.xml"
    if PATH="$WORK_DIR/bin:$PATH" \
       SAFEMAC_VERIFY_APP_PATH="$WORK_DIR/SafeMac AV.app" \
        "$PROJECT_DIR/scripts/verify-release-package.sh" "$WORK_DIR/package" >/dev/null 2>&1; then
        fail "mismatched appcast version was accepted"
    fi
    perl -0pi -e 's|<sparkle:version>4</sparkle:version>|<sparkle:version>3</sparkle:version>|' "$WORK_DIR/package/appcast/appcast.xml"
}

run_missing_appcast_failure_case() {
    mv "$WORK_DIR/package/appcast/appcast.xml" "$WORK_DIR/package/appcast/appcast.xml.bak"
    if PATH="$WORK_DIR/bin:$PATH" \
       SAFEMAC_VERIFY_APP_PATH="$WORK_DIR/SafeMac AV.app" \
        "$PROJECT_DIR/scripts/verify-release-package.sh" "$WORK_DIR/package" >/dev/null 2>&1; then
        fail "missing appcast was accepted"
    fi
    mv "$WORK_DIR/package/appcast/appcast.xml.bak" "$WORK_DIR/package/appcast/appcast.xml"
}

run_feed_signature_failure_case() {
    cp "$WORK_DIR/package/appcast/appcast.xml" "$WORK_DIR/package/appcast/appcast.xml.bak"
    perl -0pi -e 's|<channel>|<channel>\n    <title>Tampered</title>|' "$WORK_DIR/package/appcast/appcast.xml"
    if PATH="$WORK_DIR/bin:$PATH" \
       SAFEMAC_VERIFY_APP_PATH="$WORK_DIR/SafeMac AV.app" \
        "$PROJECT_DIR/scripts/verify-release-package.sh" "$WORK_DIR/package" >/dev/null 2>&1; then
        fail "tampered signed appcast was accepted"
    fi
    mv "$WORK_DIR/package/appcast/appcast.xml.bak" "$WORK_DIR/package/appcast/appcast.xml"
}

run_malformed_feed_signature_failure_cases() {
    local replacement

    for replacement in 'not-base64!' 'YWJj'; do
        cp "$WORK_DIR/package/appcast/appcast.xml" "$WORK_DIR/package/appcast/appcast.xml.bak"
        REPLACEMENT="$replacement" perl -0pi -e \
            's/(?m)^edSignature:\s*\S+/edSignature: $ENV{REPLACEMENT}/' \
            "$WORK_DIR/package/appcast/appcast.xml"
        if PATH="$WORK_DIR/bin:$PATH" \
           SAFEMAC_VERIFY_APP_PATH="$WORK_DIR/SafeMac AV.app" \
            "$PROJECT_DIR/scripts/verify-release-package.sh" "$WORK_DIR/package" >/dev/null 2>&1; then
            fail "malformed or wrong-length signed-feed signature was accepted: $replacement"
        fi
        mv "$WORK_DIR/package/appcast/appcast.xml.bak" "$WORK_DIR/package/appcast/appcast.xml"
    done
}

write_resigned_archive_signature() {
    local replacement="$1"

    swift - "$WORK_DIR/package/appcast/appcast.xml" "$replacement" <<'SWIFT'
import CryptoKit
import Foundation

let appcastURL = URL(fileURLWithPath: CommandLine.arguments[1])
let replacement = CommandLine.arguments[2]
let appcastData = try Data(contentsOf: appcastURL)
let prefix = Data("<!-- sparkle-signatures:\n".utf8)
guard let prefixRange = appcastData.range(of: prefix, options: [.backwards]),
      var content = String(data: appcastData[..<prefixRange.lowerBound], encoding: .utf8) else {
    exit(1)
}

let expression = try NSRegularExpression(pattern: #"sparkle:edSignature="[^"]+""#)
let range = NSRange(content.startIndex..<content.endIndex, in: content)
content = expression.stringByReplacingMatches(
    in: content,
    range: range,
    withTemplate: "sparkle:edSignature=\"\(replacement)\""
)
let signedContent = Data(content.utf8)
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))
let feedSignature = try key.signature(for: signedContent).base64EncodedString()
let signedAppcast = "\(content)<!-- sparkle-signatures:\nedSignature: \(feedSignature)\nlength: \(signedContent.count)\n-->\n"
try signedAppcast.write(to: appcastURL, atomically: true, encoding: .utf8)
SWIFT
}

mutate_and_resign_appcast() {
    local mode="$1"

    swift - "$WORK_DIR/package/appcast/appcast.xml" "$mode" <<'SWIFT'
import CryptoKit
import Foundation

let appcastURL = URL(fileURLWithPath: CommandLine.arguments[1])
let mode = CommandLine.arguments[2]
let appcastData = try Data(contentsOf: appcastURL)
let prefix = Data("<!-- sparkle-signatures:\n".utf8)
guard let prefixRange = appcastData.range(of: prefix, options: [.backwards]),
      var content = String(data: appcastData[..<prefixRange.lowerBound], encoding: .utf8) else {
    exit(1)
}

switch mode {
case "misleading-version":
    content = content.replacingOccurrences(
        of: "<sparkle:version>3</sparkle:version>",
        with: "<data-sparkle:version>3</data-sparkle:version><sparkle:version>999</sparkle:version>"
    )
case "misleading-short-version":
    content = content.replacingOccurrences(
        of: "<sparkle:shortVersionString>1.2.0</sparkle:shortVersionString>",
        with: "<data-sparkle:shortVersionString>1.2.0</data-sparkle:shortVersionString><sparkle:shortVersionString>9.9.9</sparkle:shortVersionString>"
    )
case "version-on-enclosure":
    content = content.replacingOccurrences(of: "<sparkle:version>3</sparkle:version>\n", with: "")
    content = content.replacingOccurrences(of: "<enclosure ", with: "<enclosure sparkle:version=\"3\" ")
case "duplicate-item-version":
    content = content.replacingOccurrences(
        of: "<sparkle:version>3</sparkle:version>",
        with: "<sparkle:version>3</sparkle:version><sparkle:version>3</sparkle:version>"
    )
case "nested-item-version":
    content = content.replacingOccurrences(
        of: "<sparkle:version>3</sparkle:version>",
        with: "<description><sparkle:version>3</sparkle:version></description>"
    )
case "nested-matching-item":
    content = content.replacingOccurrences(
        of: "<sparkle:version>3</sparkle:version>",
        with: "<sparkle:version>999</sparkle:version>"
    )
    let expression = try NSRegularExpression(pattern: #"<enclosure\b[^>]*>"#)
    let range = NSRange(content.startIndex..<content.endIndex, in: content)
    guard let match = expression.firstMatch(in: content, range: range),
          let swiftRange = Range(match.range, in: content) else { exit(2) }
    let enclosure = String(content[swiftRange])
    let nestedItem = """
      <description><item>
        <sparkle:version>3</sparkle:version>
        <sparkle:shortVersionString>1.2.0</sparkle:shortVersionString>
        \(enclosure)
      </item></description>
"""
    content = content.replacingOccurrences(of: "  </channel>", with: nestedItem + "  </channel>")
case "extra-decoy-item":
    let decoyItem = """
      <item>
        <sparkle:version>4</sparkle:version>
        <sparkle:shortVersionString>1.2.0</sparkle:shortVersionString>
        <enclosure url="https://outside.example/decoy.dmg" length="0" sparkle:edSignature="invalid" />
      </item>
"""
    content = content.replacingOccurrences(of: "  </channel>", with: decoyItem + "  </channel>")
case "wrong-length":
    content = content.replacingOccurrences(of: #"length="9""#, with: #"length="999""#)
case "url-user":
    content = content.replacingOccurrences(
        of: "https://downloads.example.com/SafeMac-AV.dmg",
        with: "https://user@downloads.example.com/SafeMac-AV.dmg"
    )
case "url-password":
    content = content.replacingOccurrences(
        of: "https://downloads.example.com/SafeMac-AV.dmg",
        with: "https://user:password@downloads.example.com/SafeMac-AV.dmg"
    )
case "url-query":
    content = content.replacingOccurrences(
        of: "https://downloads.example.com/SafeMac-AV.dmg",
        with: "https://downloads.example.com/SafeMac-AV.dmg?token=secret"
    )
case "url-fragment":
    content = content.replacingOccurrences(
        of: "https://downloads.example.com/SafeMac-AV.dmg",
        with: "https://downloads.example.com/SafeMac-AV.dmg#fragment"
    )
case "commented-valid-invalid-real", "cdata-valid-invalid-real":
    let validVersion = "<sparkle:version>3</sparkle:version>"
    let invalidVersion = "<sparkle:version>999</sparkle:version>"
    let hiddenValidEnclosure = mode == "commented-valid-invalid-real"
        ? "<!-- \(validVersion) -->"
        : "<![CDATA[\(validVersion)]]>"
    content = content.replacingOccurrences(of: validVersion, with: "\(hiddenValidEnclosure)\n      \(invalidVersion)")
default:
    exit(2)
}

let signedContent = Data(content.utf8)
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))
let feedSignature = try key.signature(for: signedContent).base64EncodedString()
let signedAppcast = "\(content)<!-- sparkle-signatures:\nedSignature: \(feedSignature)\nlength: \(signedContent.count)\n-->\n"
try signedAppcast.write(to: appcastURL, atomically: true, encoding: .utf8)
SWIFT
}

run_exact_enclosure_metadata_failure_cases() {
    local mode

    for mode in \
        misleading-version \
        misleading-short-version \
        version-on-enclosure \
        duplicate-item-version \
        nested-item-version \
        nested-matching-item \
        extra-decoy-item \
        wrong-length \
        url-user \
        url-password \
        url-query \
        url-fragment \
        commented-valid-invalid-real \
        cdata-valid-invalid-real; do
        cp "$WORK_DIR/package/appcast/appcast.xml" "$WORK_DIR/package/appcast/appcast.xml.bak"
        mutate_and_resign_appcast "$mode"
        if PATH="$WORK_DIR/bin:$PATH" \
           SAFEMAC_VERIFY_APP_PATH="$WORK_DIR/SafeMac AV.app" \
            "$PROJECT_DIR/scripts/verify-release-package.sh" "$WORK_DIR/package" >/dev/null 2>&1; then
            fail "invalid exact enclosure metadata was accepted: $mode"
        fi
        mv "$WORK_DIR/package/appcast/appcast.xml.bak" "$WORK_DIR/package/appcast/appcast.xml"
    done
}

run_unsigned_trailing_appcast_failure_cases() {
    local trailing

    for trailing in '<!-- unsigned trailing comment -->' '<extra />' 'unsigned-junk'; do
        cp "$WORK_DIR/package/appcast/appcast.xml" "$WORK_DIR/package/appcast/appcast.xml.bak"
        printf '%s\n' "$trailing" >> "$WORK_DIR/package/appcast/appcast.xml"
        if PATH="$WORK_DIR/bin:$PATH" \
            "$PROJECT_DIR/scripts/verify-release-package.sh" "$WORK_DIR/package" >/dev/null 2>&1; then
            fail "unsigned trailing appcast content was accepted: $trailing"
        fi
        mv "$WORK_DIR/package/appcast/appcast.xml.bak" "$WORK_DIR/package/appcast/appcast.xml"
    done
}

run_malformed_archive_signature_failure_cases() {
    local replacement

    for replacement in 'not-base64!' 'YWJj'; do
        cp "$WORK_DIR/package/appcast/appcast.xml" "$WORK_DIR/package/appcast/appcast.xml.bak"
        write_resigned_archive_signature "$replacement"
        if PATH="$WORK_DIR/bin:$PATH" \
           SAFEMAC_VERIFY_APP_PATH="$WORK_DIR/SafeMac AV.app" \
            "$PROJECT_DIR/scripts/verify-release-package.sh" "$WORK_DIR/package" >/dev/null 2>&1; then
            fail "malformed or wrong-length archive signature was accepted: $replacement"
        fi
        mv "$WORK_DIR/package/appcast/appcast.xml.bak" "$WORK_DIR/package/appcast/appcast.xml"
    done
}

run_archive_signature_failure_case() {
    cp "$WORK_DIR/package/SafeMac-AV.dmg" "$WORK_DIR/package/SafeMac-AV.dmg.bak"
    cp "$WORK_DIR/package/SHA256SUMS.txt" "$WORK_DIR/package/SHA256SUMS.txt.bak"
    printf 'tampered dmg\n' > "$WORK_DIR/package/SafeMac-AV.dmg"
    (cd "$WORK_DIR/package" && shasum -a 256 SafeMac-AV.dmg > SHA256SUMS.txt)
    if PATH="$WORK_DIR/bin:$PATH" \
       SAFEMAC_VERIFY_APP_PATH="$WORK_DIR/SafeMac AV.app" \
        "$PROJECT_DIR/scripts/verify-release-package.sh" "$WORK_DIR/package" >/dev/null 2>&1; then
        fail "tampered DMG with stale Sparkle signature was accepted"
    fi
    mv "$WORK_DIR/package/SafeMac-AV.dmg.bak" "$WORK_DIR/package/SafeMac-AV.dmg"
    mv "$WORK_DIR/package/SHA256SUMS.txt.bak" "$WORK_DIR/package/SHA256SUMS.txt"
}

run_duplicate_matching_enclosure_failure_case() {
    cp "$WORK_DIR/package/appcast/appcast.xml" "$WORK_DIR/package/appcast/appcast.xml.bak"
    swift - "$WORK_DIR/package/appcast/appcast.xml" <<'SWIFT'
import CryptoKit
import Foundation

let appcastPath = CommandLine.arguments[1]
let appcastURL = URL(fileURLWithPath: appcastPath)
let appcastData = try Data(contentsOf: appcastURL)
let prefix = Data("<!-- sparkle-signatures:\n".utf8)
guard let prefixRange = appcastData.range(of: prefix, options: [.backwards]) else { exit(1) }
guard var content = String(data: appcastData[..<prefixRange.lowerBound], encoding: .utf8) else { exit(1) }
    let duplicate = #"      <enclosure url="https://downloads.example.com/SafeMac-AV.dmg" sparkle:edSignature="duplicate" />"#
content = content.replacingOccurrences(of: "    </item>", with: duplicate + "\n    </item>")
let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))
let signedContent = Data(content.utf8)
let feedSignature = try privateKey.signature(for: signedContent).base64EncodedString()
let signedAppcast = "\(content)<!-- sparkle-signatures:\nedSignature: \(feedSignature)\nlength: \(signedContent.count)\n-->\n"
try signedAppcast.write(to: appcastURL, atomically: true, encoding: .utf8)
SWIFT
    if PATH="$WORK_DIR/bin:$PATH" \
       SAFEMAC_VERIFY_APP_PATH="$WORK_DIR/SafeMac AV.app" \
        "$PROJECT_DIR/scripts/verify-release-package.sh" "$WORK_DIR/package" >/dev/null 2>&1; then
        fail "duplicate matching appcast enclosure was accepted"
    fi
    mv "$WORK_DIR/package/appcast/appcast.xml.bak" "$WORK_DIR/package/appcast/appcast.xml"
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

run_background_helper_presence_and_policy_failure_cases() {
    local helper="$WORK_DIR/SafeMac AV.app/Contents/Library/LoginItems/SafeMacAVBackground.app"
    local executable="$helper/Contents/MacOS/SafeMacAVBackground"

    mv "$helper" "$helper.missing"
    if PATH="$WORK_DIR/bin:$PATH" \
       SAFEMAC_VERIFY_APP_PATH="$WORK_DIR/SafeMac AV.app" \
        "$PROJECT_DIR/scripts/verify-release-package.sh" "$WORK_DIR/package" >/dev/null 2>&1; then
        fail "release verifier accepted a missing background helper"
    fi
    mv "$helper.missing" "$helper"

    if PATH="$WORK_DIR/bin:$PATH" \
       NON_UNIVERSAL_PATH="$executable" \
       SAFEMAC_VERIFY_APP_PATH="$WORK_DIR/SafeMac AV.app" \
        "$PROJECT_DIR/scripts/verify-release-package.sh" "$WORK_DIR/package" >/dev/null 2>&1; then
        fail "release verifier accepted a non-universal background helper"
    fi

    /usr/libexec/PlistBuddy -c 'Set :LSUIElement false' "$helper/Contents/Info.plist"
    if PATH="$WORK_DIR/bin:$PATH" \
       SAFEMAC_VERIFY_APP_PATH="$WORK_DIR/SafeMac AV.app" \
        "$PROJECT_DIR/scripts/verify-release-package.sh" "$WORK_DIR/package" >/dev/null 2>&1; then
        fail "release verifier accepted a foreground-capable background helper"
    fi
    /usr/libexec/PlistBuddy -c 'Set :LSUIElement true' "$helper/Contents/Info.plist"

    if PATH="$WORK_DIR/bin:$PATH" \
       BACKGROUND_HELPER_ENTITLEMENT_MODE=invalid \
       SAFEMAC_VERIFY_APP_PATH="$WORK_DIR/SafeMac AV.app" \
        "$PROJECT_DIR/scripts/verify-release-package.sh" "$WORK_DIR/package" >/dev/null 2>&1; then
        fail "release verifier accepted invalid background helper entitlements"
    fi

    if PATH="$WORK_DIR/bin:$PATH" \
       BACKGROUND_HELPER_ENTITLEMENT_MODE=sandbox-true-with-unrelated-false \
       SAFEMAC_VERIFY_APP_PATH="$WORK_DIR/SafeMac AV.app" \
        "$PROJECT_DIR/scripts/verify-release-package.sh" "$WORK_DIR/package" >/dev/null 2>&1; then
        fail "release verifier accepted an enabled helper sandbox with an unrelated false entitlement"
    fi

    local signature_failure_variable
    local -a signature_failure_variables=(
        WRONG_TEAM_CODESIGN_PATH
        ADHOC_CODESIGN_PATH
        MISSING_TIMESTAMP_PATH
        MISSING_RUNTIME_PATH
    )
    for signature_failure_variable in "${signature_failure_variables[@]}"; do
        if env \
            PATH="$WORK_DIR/bin:$PATH" \
            "$signature_failure_variable=$helper" \
            SAFEMAC_VERIFY_APP_PATH="$WORK_DIR/SafeMac AV.app" \
            "$PROJECT_DIR/scripts/verify-release-package.sh" "$WORK_DIR/package" >/dev/null 2>&1; then
            fail "release verifier accepted invalid background helper signature policy: $signature_failure_variable"
        fi
    done
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
    configure_test_app_override
    run_success_case
    run_mounted_cleanup_case
    run_mounted_failure_cleanup_case
    run_unscoped_app_override_failure_cases
    run_fixture_root_cleanup_case
    run_embedded_feed_url_failure_cases
    run_arch_failure_case
    run_nested_adhoc_failure_cases
    run_nested_arch_failure_case
    run_background_helper_presence_and_policy_failure_cases
    run_nested_signature_policy_failure_cases
    run_missing_autoupdate_entitlement_case
    run_finder_entitlement_failure_cases
    run_appcast_failure_case
    run_missing_appcast_failure_case
    run_feed_signature_failure_case
    run_malformed_feed_signature_failure_cases
    run_archive_signature_failure_case
    run_malformed_archive_signature_failure_cases
    run_exact_enclosure_metadata_failure_cases
    run_unsigned_trailing_appcast_failure_cases
    run_duplicate_matching_enclosure_failure_case
    printf 'verify-release-package tests passed\n'
}

main "$@"

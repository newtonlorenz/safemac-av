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
      <enclosure url="https://downloads.example.com/SafeMac-AV.dmg" length="\(try Data(contentsOf: URL(fileURLWithPath: dmgPath)).count)" sparkle:version="3" sparkle:shortVersionString="1.2.0" sparkle:edSignature="\(archiveSignature)" />
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

run_appcast_failure_case() {
    perl -0pi -e 's/sparkle:version="3"/sparkle:version="4"/' "$WORK_DIR/package/appcast/appcast.xml"
    if PATH="$WORK_DIR/bin:$PATH" \
       SAFEMAC_VERIFY_APP_PATH="$WORK_DIR/SafeMac AV.app" \
        "$PROJECT_DIR/scripts/verify-release-package.sh" "$WORK_DIR/package" >/dev/null 2>&1; then
        fail "mismatched appcast version was accepted"
    fi
    perl -0pi -e 's/sparkle:version="4"/sparkle:version="3"/' "$WORK_DIR/package/appcast/appcast.xml"
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
        of: #"sparkle:version="3""#,
        with: #"data-sparkle:version="3" sparkle:version="999""#
    )
case "misleading-short-version":
    content = content.replacingOccurrences(
        of: #"sparkle:shortVersionString="1.2.0""#,
        with: #"data-sparkle:shortVersionString="1.2.0" sparkle:shortVersionString="9.9.9""#
    )
case "single-quoted-version":
    content = content.replacingOccurrences(of: #"sparkle:version="3""#, with: "sparkle:version='3'")
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
        single-quoted-version \
        wrong-length \
        url-user \
        url-password \
        url-query \
        url-fragment; do
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
let duplicate = #"      <enclosure url="https://downloads.example.com/SafeMac-AV.dmg" sparkle:version="3" sparkle:shortVersionString="1.2.0" sparkle:edSignature="duplicate" />"#
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
    run_missing_appcast_failure_case
    run_feed_signature_failure_case
    run_malformed_feed_signature_failure_cases
    run_archive_signature_failure_case
    run_malformed_archive_signature_failure_cases
    run_exact_enclosure_metadata_failure_cases
    run_duplicate_matching_enclosure_failure_case
    printf 'verify-release-package tests passed\n'
}

main "$@"

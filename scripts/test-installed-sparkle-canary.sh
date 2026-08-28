#!/bin/bash

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
TEMP_ROOT="$(cd "$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)" && pwd -P)"
WORK_DIR="$(mktemp -d "$TEMP_ROOT/safemac-installed-sparkle-canary.XXXXXX")"
FAKE_BIN="$WORK_DIR/bin"
OUTSIDE_WORK_DIR="$(mktemp -d "$TEMP_ROOT/safemac-installed-sparkle-canary-outside.XXXXXX")"
LSREGISTER_LOG="$OUTSIDE_WORK_DIR/lsregister.log"
LSREGISTER_BIN="$OUTSIDE_WORK_DIR/lsregister"

cleanup_root() {
    local root="$1"

    [[ -d "$root" ]] || return 0
    if LSREGISTER_BIN="$LSREGISTER_BIN" \
        "$PROJECT_DIR/scripts/clean-build-registrations.sh" "$root"; then
        rm -rf "$root"
    else
        printf 'Warning: could not validate extension cleanup; preserving test workdir at %s\n' \
            "$root" >&2
    fi
}

cleanup() {
    local status=$?

    trap - EXIT
    cleanup_root "$WORK_DIR"
    cleanup_root "$OUTSIDE_WORK_DIR"
    exit "$status"
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
    write_fake_tool codesign '
if [[ " $* " == *" --verify "* && "${CANARY_CODESIGN_VERIFY_FAIL:-0}" == "1" ]]; then
    exit 1
fi
if [[ " $* " == *" -dv "* ]]; then
    team_id="${CANARY_CODESIGN_TEAM_ID:-CQPH8YR62A}"
    flags="CodeDirectory v=20500 flags=0x10000(runtime)"
    [[ "${CANARY_CODESIGN_MISSING_RUNTIME:-0}" != "1" ]] || flags="CodeDirectory v=20500 flags=0x0(none)"
    printf "%s\n" \
        "Authority=Developer ID Application: SafeMac Test ($team_id)" \
        "TeamIdentifier=$team_id" \
        "Timestamp=Aug 22, 2026 at 02:00:00" \
        "$flags" >&2
fi'
    write_fake_tool spctl '[[ "${CANARY_SPCTL_FAIL:-0}" != "1" ]]'
    write_fake_tool lsregister '
printf "%s\n" "$*" >> "${LSREGISTER_LOG:?}"'
    cp "$FAKE_BIN/lsregister" "$LSREGISTER_BIN"
}

make_fixture() {
    local app_dir="$WORK_DIR/SafeMac AV.app"
    local package_dir="$WORK_DIR/package"

    mkdir -p "$app_dir/Contents" "$package_dir/appcast"
    printf 'fake dmg\n' > "$package_dir/SafeMac-AV.dmg"

    cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleShortVersionString</key>
    <string>1.1.0</string>
    <key>CFBundleVersion</key>
    <string>2</string>
    <key>CFBundleIdentifier</key>
    <string>com.newtonlorenz.ClamAV-GUI</string>
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

    write_appcast "3" "$app_dir/Contents/Info.plist" "$package_dir/SafeMac-AV.dmg" "$package_dir/appcast/appcast.xml"
}

write_appcast() {
    local update_version="$1"
    local info_plist="$2"
    local dmg_path="$3"
    local appcast_path="$4"

    swift - "$update_version" "$info_plist" "$dmg_path" "$appcast_path" "$WORK_DIR/sparkle-public-key.txt" <<'SWIFT'
import CryptoKit
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
let updateVersion = arguments[0]
let infoPlistPath = arguments[1]
let dmgPath = arguments[2]
let appcastPath = arguments[3]
let publicKeyPath = arguments[4]

let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))
let publicKeyBase64 = privateKey.publicKey.rawRepresentation.base64EncodedString()
let dmgData = try Data(contentsOf: URL(fileURLWithPath: dmgPath))
let archiveSignature = try privateKey.signature(for: dmgData).base64EncodedString()
let content = """
<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <item>
      <sparkle:version>\(updateVersion)</sparkle:version>
      <sparkle:shortVersionString>1.2.0</sparkle:shortVersionString>
      <enclosure url="https://downloads.example.com/SafeMac-AV.dmg" length="\(dmgData.count)" sparkle:edSignature="\(archiveSignature)" />
    </item>
  </channel>
</rss>
"""
let signedContent = Data((content + "\n").utf8)
let feedSignature = try privateKey.signature(for: signedContent).base64EncodedString()
let signedAppcast = "\(content)\n<!-- sparkle-signatures:\nedSignature: \(feedSignature)\nlength: \(signedContent.count)\n-->\n"
try signedAppcast.write(to: URL(fileURLWithPath: appcastPath), atomically: true, encoding: .utf8)
try publicKeyBase64.write(to: URL(fileURLWithPath: publicKeyPath), atomically: true, encoding: .utf8)
let plist = try String(contentsOfFile: infoPlistPath, encoding: .utf8)
try plist.replacingOccurrences(of: "__SPARKLE_PUBLIC_ED_KEY__", with: publicKeyBase64)
    .write(to: URL(fileURLWithPath: infoPlistPath), atomically: true, encoding: .utf8)
SWIFT
}

mutate_and_resign_installed_appcast() {
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
case "misleading-version":
    content = content.replacingOccurrences(
        of: "<sparkle:version>3</sparkle:version>",
        with: "<data-sparkle:version>3</data-sparkle:version><sparkle:version>1</sparkle:version>"
    )
case "commented-valid-invalid-real", "cdata-valid-invalid-real":
    let validVersion = "<sparkle:version>3</sparkle:version>"
    let invalidVersion = "<sparkle:version>1</sparkle:version>"
    let hiddenValidEnclosure = mode == "commented-valid-invalid-real"
        ? "<!-- \(validVersion) -->"
        : "<![CDATA[\(validVersion)]]>"
    content = content.replacingOccurrences(
        of: validVersion,
        with: "\(hiddenValidEnclosure)\n      \(invalidVersion)"
    )
default:
    exit(2)
}
let signedContent = Data(content.utf8)
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))
let signature = try key.signature(for: signedContent).base64EncodedString()
let signedAppcast = "\(content)<!-- sparkle-signatures:\nedSignature: \(signature)\nlength: \(signedContent.count)\n-->\n"
try signedAppcast.write(to: appcastURL, atomically: true, encoding: .utf8)
SWIFT
}

run_success_case() {
    EXPECTED_SPARKLE_DOWNLOAD_URL_PREFIX="https://downloads.example.com/" \
        "$PROJECT_DIR/scripts/verify-installed-sparkle-canary.sh" \
        "$WORK_DIR/SafeMac AV.app" \
        "$WORK_DIR/package/appcast/appcast.xml" \
        "$WORK_DIR/package/SafeMac-AV.dmg" >/dev/null
}

run_same_version_failure_case() {
    write_appcast "2" \
        "$WORK_DIR/SafeMac AV.app/Contents/Info.plist" \
        "$WORK_DIR/package/SafeMac-AV.dmg" \
        "$WORK_DIR/package/appcast/appcast.xml"
    if "$PROJECT_DIR/scripts/verify-installed-sparkle-canary.sh" \
        "$WORK_DIR/SafeMac AV.app" \
        "$WORK_DIR/package/appcast/appcast.xml" \
        "$WORK_DIR/package/SafeMac-AV.dmg" >/dev/null 2>&1; then
        fail "same-version appcast was accepted"
    fi
    write_appcast "3" \
        "$WORK_DIR/SafeMac AV.app/Contents/Info.plist" \
        "$WORK_DIR/package/SafeMac-AV.dmg" \
        "$WORK_DIR/package/appcast/appcast.xml"
}

run_feed_signature_failure_case() {
    cp "$WORK_DIR/package/appcast/appcast.xml" "$WORK_DIR/package/appcast/appcast.xml.bak"
    perl -0pi -e 's|<channel>|<channel>\n    <title>Tampered</title>|' "$WORK_DIR/package/appcast/appcast.xml"
    if "$PROJECT_DIR/scripts/verify-installed-sparkle-canary.sh" \
        "$WORK_DIR/SafeMac AV.app" \
        "$WORK_DIR/package/appcast/appcast.xml" \
        "$WORK_DIR/package/SafeMac-AV.dmg" >/dev/null 2>&1; then
        fail "tampered appcast was accepted"
    fi
    mv "$WORK_DIR/package/appcast/appcast.xml.bak" "$WORK_DIR/package/appcast/appcast.xml"
}

run_archive_signature_failure_case() {
    cp "$WORK_DIR/package/SafeMac-AV.dmg" "$WORK_DIR/package/SafeMac-AV.dmg.bak"
    printf 'tampered dmg\n' > "$WORK_DIR/package/SafeMac-AV.dmg"
    if "$PROJECT_DIR/scripts/verify-installed-sparkle-canary.sh" \
        "$WORK_DIR/SafeMac AV.app" \
        "$WORK_DIR/package/appcast/appcast.xml" \
        "$WORK_DIR/package/SafeMac-AV.dmg" >/dev/null 2>&1; then
        fail "tampered DMG was accepted"
    fi
    mv "$WORK_DIR/package/SafeMac-AV.dmg.bak" "$WORK_DIR/package/SafeMac-AV.dmg"
}

run_duplicate_newer_enclosure_failure_case() {
    cp "$WORK_DIR/package/appcast/appcast.xml" "$WORK_DIR/package/appcast/appcast.xml.bak"
    swift - "$WORK_DIR/package/appcast/appcast.xml" "$WORK_DIR/package/SafeMac-AV.dmg" <<'SWIFT'
import CryptoKit
import Foundation

let appcastPath = CommandLine.arguments[1]
let dmgPath = CommandLine.arguments[2]
let appcastURL = URL(fileURLWithPath: appcastPath)
let appcastData = try Data(contentsOf: appcastURL)
let prefix = Data("<!-- sparkle-signatures:\n".utf8)
guard let prefixRange = appcastData.range(of: prefix, options: [.backwards]) else { exit(1) }
guard var content = String(data: appcastData[..<prefixRange.lowerBound], encoding: .utf8) else { exit(1) }
let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32))
let dmgData = try Data(contentsOf: URL(fileURLWithPath: dmgPath))
let archiveSignature = try privateKey.signature(for: dmgData).base64EncodedString()
let duplicate = #"      <enclosure url="https://downloads.example.com/SafeMac-AV.dmg" length="\#(dmgData.count)" sparkle:edSignature="\#(archiveSignature)" />"#
content = content.replacingOccurrences(of: "    </item>", with: duplicate + "\n    </item>")
let signedContent = Data(content.utf8)
let feedSignature = try privateKey.signature(for: signedContent).base64EncodedString()
let signedAppcast = "\(content)<!-- sparkle-signatures:\nedSignature: \(feedSignature)\nlength: \(signedContent.count)\n-->\n"
try signedAppcast.write(to: appcastURL, atomically: true, encoding: .utf8)
SWIFT
    if "$PROJECT_DIR/scripts/verify-installed-sparkle-canary.sh" \
        "$WORK_DIR/SafeMac AV.app" \
        "$WORK_DIR/package/appcast/appcast.xml" \
        "$WORK_DIR/package/SafeMac-AV.dmg" >/dev/null 2>&1; then
        fail "duplicate newer appcast enclosure was accepted"
    fi
    mv "$WORK_DIR/package/appcast/appcast.xml.bak" "$WORK_DIR/package/appcast/appcast.xml"
}

run_invalid_installed_key_failure_case() {
    cp "$WORK_DIR/SafeMac AV.app/Contents/Info.plist" "$WORK_DIR/SafeMac AV.app/Contents/Info.plist.bak"
    /usr/libexec/PlistBuddy -c "Set :SUPublicEDKey invalid" "$WORK_DIR/SafeMac AV.app/Contents/Info.plist"
    if "$PROJECT_DIR/scripts/verify-installed-sparkle-canary.sh" \
        "$WORK_DIR/SafeMac AV.app" \
        "$WORK_DIR/package/appcast/appcast.xml" \
        "$WORK_DIR/package/SafeMac-AV.dmg" >/dev/null 2>&1; then
        fail "invalid installed public key was accepted"
    fi
    mv "$WORK_DIR/SafeMac AV.app/Contents/Info.plist.bak" "$WORK_DIR/SafeMac AV.app/Contents/Info.plist"
}

run_unsafe_feed_url_failure_case() {
    local feed_url
    local -a feed_urls=(
        "https://user@updates.example.com/appcast.xml"
        "https://user:password@updates.example.com/appcast.xml"
        "https://updates.example.com/appcast.xml?token=secret"
        "https://updates.example.com/appcast.xml#fragment"
    )

    for feed_url in "${feed_urls[@]}"; do
        cp "$WORK_DIR/SafeMac AV.app/Contents/Info.plist" "$WORK_DIR/SafeMac AV.app/Contents/Info.plist.bak"
        /usr/libexec/PlistBuddy -c "Set :SUFeedURL $feed_url" \
            "$WORK_DIR/SafeMac AV.app/Contents/Info.plist"
        if run_success_case >/dev/null 2>&1; then
            fail "unsafe feed URL was accepted: $feed_url"
        fi
        mv "$WORK_DIR/SafeMac AV.app/Contents/Info.plist.bak" "$WORK_DIR/SafeMac AV.app/Contents/Info.plist"
    done
}

run_unsafe_archive_metadata_failure_cases() {
    local mode

    for mode in url-user url-password url-query url-fragment misleading-version commented-valid-invalid-real cdata-valid-invalid-real; do
        cp "$WORK_DIR/package/appcast/appcast.xml" "$WORK_DIR/package/appcast/appcast.xml.bak"
        mutate_and_resign_installed_appcast "$mode"
        if "$PROJECT_DIR/scripts/verify-installed-sparkle-canary.sh" \
            "$WORK_DIR/SafeMac AV.app" \
            "$WORK_DIR/package/appcast/appcast.xml" \
            "$WORK_DIR/package/SafeMac-AV.dmg" >/dev/null 2>&1; then
            fail "unsafe installed appcast metadata was accepted: $mode"
        fi
        mv "$WORK_DIR/package/appcast/appcast.xml.bak" "$WORK_DIR/package/appcast/appcast.xml"
    done
}

run_unsigned_trailing_appcast_failure_cases() {
    local trailing

    for trailing in '<!-- unsigned trailing comment -->' '<extra />' 'unsigned-junk'; do
        cp "$WORK_DIR/package/appcast/appcast.xml" "$WORK_DIR/package/appcast/appcast.xml.bak"
        printf '%s\n' "$trailing" >> "$WORK_DIR/package/appcast/appcast.xml"
        if run_success_case >/dev/null 2>&1; then
            fail "unsigned trailing installed appcast content was accepted: $trailing"
        fi
        mv "$WORK_DIR/package/appcast/appcast.xml.bak" "$WORK_DIR/package/appcast/appcast.xml"
    done
}

run_signature_policy_failure_cases() {
    if CANARY_CODESIGN_TEAM_ID="WRONGTEAM01" run_success_case >/dev/null 2>&1; then
        fail "wrong-team installed app was accepted"
    fi
    if CANARY_CODESIGN_VERIFY_FAIL=1 run_success_case >/dev/null 2>&1; then
        fail "tampered or unsigned installed app was accepted"
    fi
    if CANARY_CODESIGN_MISSING_RUNTIME=1 run_success_case >/dev/null 2>&1; then
        fail "installed app without hardened runtime was accepted"
    fi
    if CANARY_SPCTL_FAIL=1 run_success_case >/dev/null 2>&1; then
        fail "Gatekeeper-rejected installed app was accepted"
    fi
}

run_test_fixture_override_case() {
    printf 'SafeMac canary unsigned fixture\n' > "$WORK_DIR/.safemac-canary-unsigned-fixture"
    chmod 600 "$WORK_DIR/.safemac-canary-unsigned-fixture"
    CANARY_CODESIGN_VERIFY_FAIL=1 \
    CANARY_SPCTL_FAIL=1 \
    SAFEMAC_CANARY_TEST_ONLY_ALLOW_UNSIGNED_FIXTURE=1 \
    SAFEMAC_CANARY_TEST_ONLY_FIXTURE_ROOT="$WORK_DIR" \
        run_success_case >/dev/null \
        || fail "explicit unsigned test-fixture override was rejected"
}

run_test_fixture_override_scope_case() {
    if TMPDIR="/Applications" \
       CANARY_CODESIGN_VERIFY_FAIL=1 \
       SAFEMAC_CANARY_TEST_ONLY_ALLOW_UNSIGNED_FIXTURE=1 \
        run_success_case >/dev/null 2>&1; then
        fail "caller-controlled TMPDIR enabled the unsigned fixture override"
    fi
}

run_test_fixture_override_requires_explicit_root() {
    if TMPDIR="$WORK_DIR" \
       CANARY_CODESIGN_VERIFY_FAIL=1 \
       SAFEMAC_CANARY_TEST_ONLY_ALLOW_UNSIGNED_FIXTURE=1 \
        run_success_case >/dev/null 2>&1; then
        fail "unsigned fixture override trusted caller-controlled TMPDIR without a validated fixture root"
    fi
}

run_test_fixture_override_symlink_escape_case() {
    local real_app_path="$OUTSIDE_WORK_DIR/SafeMac AV.app"
    local symlink_app_path="$WORK_DIR/Symlinked SafeMac AV.app"

    cp -R "$WORK_DIR/SafeMac AV.app" "$real_app_path"
    ln -s "$real_app_path" "$symlink_app_path"
    if CANARY_CODESIGN_VERIFY_FAIL=1 \
       SAFEMAC_CANARY_TEST_ONLY_ALLOW_UNSIGNED_FIXTURE=1 \
        "$PROJECT_DIR/scripts/verify-installed-sparkle-canary.sh" \
        "$symlink_app_path" \
        "$WORK_DIR/package/appcast/appcast.xml" \
        "$WORK_DIR/package/SafeMac-AV.dmg" >/dev/null 2>&1; then
        fail "unsigned fixture override accepted a symlinked installed app outside the temporary directory"
    fi
    rm -f "$symlink_app_path"
}

main() {
    make_fake_tools
    export PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
    export LSREGISTER_BIN LSREGISTER_LOG
    make_fixture
    run_success_case
    run_signature_policy_failure_cases
    run_test_fixture_override_case
    run_test_fixture_override_scope_case
    run_test_fixture_override_requires_explicit_root
    run_test_fixture_override_symlink_escape_case
    run_same_version_failure_case
    run_feed_signature_failure_case
    run_archive_signature_failure_case
    run_duplicate_newer_enclosure_failure_case
    run_invalid_installed_key_failure_case
    run_unsafe_feed_url_failure_case
    run_unsafe_archive_metadata_failure_cases
    run_unsigned_trailing_appcast_failure_cases
    printf 'installed Sparkle canary tests passed\n'
}

main "$@"

#!/bin/bash

# Verify that an installed SafeMac AV app can see exactly one signed, newer
# Sparkle update in a release appcast. This is a preflight for the manual
# installed update canary; it does not launch Sparkle or modify /Applications.

set -Eeuo pipefail
IFS=$'\n\t'

INSTALLED_APP_PATH="${1:-/Applications/SafeMac AV.app}"
APPCAST_PATH="${2:-build/appcast/appcast.xml}"
DMG_PATH="${3:-build/SafeMac-AV.dmg}"
EXPECTED_SPARKLE_DOWNLOAD_URL_PREFIX="${EXPECTED_SPARKLE_DOWNLOAD_URL_PREFIX:-}"
EXPECTED_BUNDLE_ID="com.newtonlorenz.ClamAV-GUI"
EXPECTED_TEAM_ID="CQPH8YR62A"
ALLOW_UNSIGNED_TEST_FIXTURE="${SAFEMAC_CANARY_TEST_ONLY_ALLOW_UNSIGNED_FIXTURE:-0}"

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

bundle_value() {
    local key="$1"
    local info_plist="$INSTALLED_APP_PATH/Contents/Info.plist"

    /usr/libexec/PlistBuddy -c "Print :$key" "$info_plist" 2>/dev/null \
        || fail "unable to read $key from $info_plist"
}

optional_bundle_value() {
    local key="$1"
    local info_plist="$INSTALLED_APP_PATH/Contents/Info.plist"

    /usr/libexec/PlistBuddy -c "Print :$key" "$info_plist" 2>/dev/null || true
}

is_explicit_test_fixture() {
    local app_parent
    local temp_root

    [[ "$ALLOW_UNSIGNED_TEST_FIXTURE" == "1" ]] || return 1
    app_parent="$(cd "$(dirname "$INSTALLED_APP_PATH")" && pwd -P)"
    temp_root="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
    [[ "$app_parent/" == "$temp_root/"* ]] \
        || fail "unsigned fixture override is restricted to the temporary test directory"
}

verify_installed_app_policy() {
    local bundle_id
    local details

    bundle_id="$(bundle_value CFBundleIdentifier)"
    [[ "$bundle_id" == "$EXPECTED_BUNDLE_ID" ]] \
        || fail "installed app has an unexpected bundle identifier"

    if is_explicit_test_fixture; then
        info "unsigned temporary test fixture override is active"
        return
    fi

    codesign --verify --deep --strict --verbose=2 "$INSTALLED_APP_PATH" \
        || fail "installed app signature verification failed"
    details="$(codesign -dv --verbose=4 "$INSTALLED_APP_PATH" 2>&1)" \
        || fail "unable to inspect installed app signature"
    grep -Fq 'Authority=Developer ID Application:' <<< "$details" \
        || fail "installed app is not signed with Developer ID Application"
    grep -Fq "TeamIdentifier=$EXPECTED_TEAM_ID" <<< "$details" \
        || fail "installed app is not signed by the expected Developer ID team"
    grep -Eq '^Timestamp=.+$' <<< "$details" \
        || fail "installed app signature does not include a secure timestamp"
    if grep -Fq 'Timestamp=none' <<< "$details"; then
        fail "installed app signature does not include a secure timestamp"
    fi
    grep -Fq 'runtime' <<< "$details" \
        || fail "installed app signature is missing hardened runtime"
    spctl -a -vv -t execute "$INSTALLED_APP_PATH" >/dev/null 2>&1 \
        || fail "Gatekeeper does not trust the installed app"

    info "installed app uses Developer ID Team $EXPECTED_TEAM_ID, hardened runtime, and Gatekeeper trust"
}

main() {
    command_path codesign
    command_path spctl
    command_path swift
    [[ -d "$INSTALLED_APP_PATH" ]] || fail "installed app not found: $INSTALLED_APP_PATH"
    require_file "$APPCAST_PATH" "Sparkle appcast"
    require_file "$DMG_PATH" "release DMG"
    verify_installed_app_policy

    local installed_version
    local installed_short_version
    local sparkle_feed_url
    local sparkle_public_ed_key
    local requires_signed_feed
    local verifies_before_extraction

    installed_version="$(bundle_value CFBundleVersion)"
    installed_short_version="$(bundle_value CFBundleShortVersionString)"
    sparkle_feed_url="$(bundle_value SUFeedURL)"
    sparkle_public_ed_key="$(bundle_value SUPublicEDKey)"
    requires_signed_feed="$(optional_bundle_value SURequireSignedFeed)"
    verifies_before_extraction="$(optional_bundle_value SUVerifyUpdateBeforeExtraction)"

    [[ "$sparkle_feed_url" != *'$('* ]] || fail "SUFeedURL contains an unresolved build setting"
    [[ "$sparkle_public_ed_key" != *'$('* ]] || fail "SUPublicEDKey contains an unresolved build setting"
    [[ "$requires_signed_feed" == "true" ]] || fail "SURequireSignedFeed must be true"
    [[ "$verifies_before_extraction" == "true" ]] || fail "SUVerifyUpdateBeforeExtraction must be true"

    if ! swift - "$sparkle_feed_url" "$sparkle_public_ed_key" <<'SWIFT'
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2,
      let components = URLComponents(string: arguments[0]),
      components.scheme == "https",
      components.host?.isEmpty == false,
      let publicKey = Data(base64Encoded: arguments[1]),
      publicKey.count == 32 else {
    exit(1)
}
SWIFT
    then
        fail "installed Sparkle feed URL or public EdDSA key is invalid"
    fi

    if ! swift - "$APPCAST_PATH" "$DMG_PATH" "$sparkle_public_ed_key" "$installed_version" "$EXPECTED_SPARKLE_DOWNLOAD_URL_PREFIX" <<'SWIFT'
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func firstMatch(_ pattern: String, in value: String) -> String? {
    guard let expression = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    guard let match = expression.firstMatch(in: value, range: range),
          match.numberOfRanges > 1,
          let swiftRange = Range(match.range(at: 1), in: value) else {
        return nil
    }
    return String(value[swiftRange])
}

func allMatches(_ pattern: String, in value: String) -> [String] {
    guard let expression = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
        return []
    }
    let range = NSRange(value.startIndex..<value.endIndex, in: value)
    return expression.matches(in: value, range: range).compactMap { match in
        guard let swiftRange = Range(match.range, in: value) else { return nil }
        return String(value[swiftRange])
    }
}

func attribute(_ name: String, in tag: String) -> String? {
    let escapedName = NSRegularExpression.escapedPattern(for: name)
    return firstMatch(#"\b\#(escapedName)="([^"]+)""#, in: tag)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 5 else { fail("invalid verifier arguments") }

let appcastURL = URL(fileURLWithPath: arguments[0])
let dmgURL = URL(fileURLWithPath: arguments[1])
let publicKeyBase64 = arguments[2]
guard let installedVersion = Int(arguments[3]) else {
    fail("installed CFBundleVersion must be numeric")
}
let expectedDownloadURLPrefix = arguments[4]

let appcastData = try Data(contentsOf: appcastURL)
guard let publicKeyData = Data(base64Encoded: publicKeyBase64),
      publicKeyData.count == 32 else {
    fail("invalid public key")
}
let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData)

let prefix = Data("<!-- sparkle-signatures:\n".utf8)
let suffix = Data("-->".utf8)
guard let prefixRange = appcastData.range(of: prefix, options: [.backwards]) else {
    fail("signed-feed block missing")
}
let contentData = appcastData[..<prefixRange.lowerBound]
guard let suffixRange = appcastData.range(of: suffix, in: prefixRange.upperBound..<appcastData.endIndex) else {
    fail("signed-feed block terminator missing")
}
guard let block = String(data: appcastData[prefixRange.upperBound..<suffixRange.lowerBound], encoding: .utf8) else {
    fail("signed-feed block is not UTF-8")
}
guard let feedSignatureBase64 = firstMatch(#"(?m)^edSignature:\s*(\S+)"#, in: block),
      let signedLengthString = firstMatch(#"(?m)^length:\s*(\d+)"#, in: block),
      Int(signedLengthString) == contentData.count else {
    fail("signed-feed metadata invalid")
}
guard let feedSignature = Data(base64Encoded: feedSignatureBase64),
      feedSignature.count == 64,
      publicKey.isValidSignature(feedSignature, for: contentData) else {
    fail("signed-feed signature invalid")
}

guard let content = String(data: contentData, encoding: .utf8) else {
    fail("appcast content is not UTF-8")
}
let updateEnclosures = allMatches(#"<enclosure\b[^>]*>"#, in: content).compactMap { tag -> (tag: String, version: Int)? in
    guard let versionString = attribute("sparkle:version", in: tag),
          let version = Int(versionString),
          version > installedVersion else {
        return nil
    }
    return (tag, version)
}
guard updateEnclosures.count == 1 else {
    fail("expected exactly one newer appcast enclosure")
}
let enclosure = updateEnclosures[0].tag

guard let archiveSignatureBase64 = attribute("sparkle:edSignature", in: enclosure),
      let archiveURLString = attribute("url", in: enclosure),
      let archiveURL = URL(string: archiveURLString),
      archiveURL.scheme == "https",
      archiveURL.host?.isEmpty == false,
      archiveURL.lastPathComponent == dmgURL.lastPathComponent else {
    fail("archive signature or URL invalid")
}
if !expectedDownloadURLPrefix.isEmpty && !archiveURLString.hasPrefix(expectedDownloadURLPrefix) {
    fail("archive URL does not use expected download prefix")
}
let fileSize = (try FileManager.default.attributesOfItem(atPath: dmgURL.path)[.size] as? NSNumber)?.int64Value
let declaredLength = attribute("sparkle:length", in: enclosure) ?? attribute("length", in: enclosure)
guard let declaredLength, Int64(declaredLength) == fileSize else {
    fail("archive length does not match release DMG")
}
guard let archiveSignature = Data(base64Encoded: archiveSignatureBase64),
      archiveSignature.count == 64,
      publicKey.isValidSignature(archiveSignature, for: try Data(contentsOf: dmgURL)) else {
    fail("archive signature invalid")
}
SWIFT
    then
        fail "installed Sparkle update canary failed"
    fi

    info "installed app $installed_short_version ($installed_version) sees one signed newer Sparkle update"
}

main "$@"

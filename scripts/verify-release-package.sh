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
EXPECTED_SPARKLE_FEED_URL="${EXPECTED_SPARKLE_FEED_URL:-}"
EXPECTED_SPARKLE_PUBLIC_ED_KEY="${EXPECTED_SPARKLE_PUBLIC_ED_KEY:-}"
EXPECTED_SPARKLE_DOWNLOAD_URL_PREFIX="${EXPECTED_SPARKLE_DOWNLOAD_URL_PREFIX:-}"

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
entitlements_dir=""
sparkle_feed_url=""
sparkle_public_ed_key=""

cleanup() {
    if [[ -n "$entitlements_dir" && -d "$entitlements_dir" ]]; then
        rm -f "$entitlements_dir/app.plist" "$entitlements_dir/finder.plist"
        rmdir "$entitlements_dir" >/dev/null 2>&1 || true
    fi
    if [[ -n "$mount_point" && -d "$mount_point" ]]; then
        hdiutil detach "$mount_point" -quiet >/dev/null 2>&1 || true
        rmdir "$mount_point" >/dev/null 2>&1 || true
    fi
}

verify_finder_handoff_entitlements() {
    local app_path="$1"
    local finder_extension="$2"
    local expected_team_id="$3"
    local expected_group="$expected_team_id.com.newtonlorenz.ClamAV-GUI"
    local app_entitlements
    local finder_entitlements
    local app_group
    local finder_group
    local finder_sandbox

    [[ -x /usr/libexec/PlistBuddy ]] || fail "PlistBuddy is required"
    entitlements_dir="$(mktemp -d "${TMPDIR:-/tmp}/safemac-entitlements.XXXXXX")"
    app_entitlements="$entitlements_dir/app.plist"
    finder_entitlements="$entitlements_dir/finder.plist"

    codesign -d --entitlements - --xml "$app_path" >"$app_entitlements" 2>/dev/null \
        || fail "unable to inspect app entitlements"
    codesign -d --entitlements - --xml "$finder_extension" >"$finder_entitlements" 2>/dev/null \
        || fail "unable to inspect Finder extension entitlements"

    app_group="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$app_entitlements" 2>/dev/null)" \
        || fail "app is missing the Finder handoff app group"
    finder_group="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.application-groups:0' "$finder_entitlements" 2>/dev/null)" \
        || fail "Finder extension is missing the handoff app group"
    finder_sandbox="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$finder_entitlements" 2>/dev/null)" \
        || fail "Finder extension is missing its sandbox entitlement"

    [[ "$app_group" == "$expected_group" ]] \
        || fail "app Finder handoff group does not match its Developer ID Team"
    [[ "$finder_group" == "$expected_group" ]] \
        || fail "Finder extension handoff group does not match the app and Developer ID Team"
    [[ "$finder_sandbox" == "true" ]] \
        || fail "Finder extension sandbox entitlement is not enabled"

    rm -f "$app_entitlements" "$finder_entitlements"
    rmdir "$entitlements_dir"
    entitlements_dir=""
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

optional_bundle_value() {
    local key="$1"
    local info_plist="$mounted_app_path/Contents/Info.plist"

    /usr/libexec/PlistBuddy -c "Print :$key" "$info_plist" 2>/dev/null || true
}

verify_sparkle_configuration() {
    local requires_signed_feed
    local verifies_before_extraction

    command_path swift

    sparkle_feed_url="$(bundle_value SUFeedURL)"
    sparkle_public_ed_key="$(bundle_value SUPublicEDKey)"
    requires_signed_feed="$(optional_bundle_value SURequireSignedFeed)"
    verifies_before_extraction="$(optional_bundle_value SUVerifyUpdateBeforeExtraction)"

    [[ "$sparkle_feed_url" != *'$('* ]] || fail "SUFeedURL contains an unresolved build setting"
    [[ "$sparkle_public_ed_key" != *'$('* ]] || fail "SUPublicEDKey contains an unresolved build setting"
    [[ "$requires_signed_feed" == "true" ]] || fail "SURequireSignedFeed must be true"
    [[ "$verifies_before_extraction" == "true" ]] || fail "SUVerifyUpdateBeforeExtraction must be true"

    if [[ -n "$EXPECTED_SPARKLE_FEED_URL" ]]; then
        [[ "$sparkle_feed_url" == "$EXPECTED_SPARKLE_FEED_URL" ]] \
            || fail "SUFeedURL does not match EXPECTED_SPARKLE_FEED_URL"
    fi
    if [[ -n "$EXPECTED_SPARKLE_PUBLIC_ED_KEY" ]]; then
        [[ "$sparkle_public_ed_key" == "$EXPECTED_SPARKLE_PUBLIC_ED_KEY" ]] \
            || fail "SUPublicEDKey does not match EXPECTED_SPARKLE_PUBLIC_ED_KEY"
    fi

    if ! swift - "$sparkle_feed_url" "$sparkle_public_ed_key" <<'SWIFT'
import Foundation

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2 else { exit(1) }
let feedURL = arguments[0]
guard feedURL.unicodeScalars.allSatisfy({
          !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0)
      }),
      let components = URLComponents(string: feedURL),
      components.scheme == "https",
      components.host?.isEmpty == false,
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil,
      !components.percentEncodedPath.isEmpty,
      let url = components.url,
      url.absoluteString == feedURL else {
    exit(1)
}
guard let publicKey = Data(base64Encoded: arguments[1]),
      publicKey.count == 32 else {
    exit(1)
}
SWIFT
    then
        fail "Sparkle feed URL or public EdDSA key is invalid"
    fi
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
    verify_finder_handoff_entitlements "$mounted_app_path" "$finder_extension" "$expected_team_id"

    verify_sparkle_configuration

    codesign --verify --deep --strict --verbose=2 "$mounted_app_path"
    info "mounted app and Finder extension share the Team-ID app group; Finder sandbox is enabled"
    info "mounted app, Finder extension, and nested Sparkle code use Developer ID Team $expected_team_id, hardened runtime, secure timestamps, and universal architectures"
}

verify_appcast() {
    local bundle_version
    local short_version

    require_file "$APPCAST_PATH" "Sparkle appcast"

    bundle_version="$(bundle_value CFBundleVersion)"
    short_version="$(bundle_value CFBundleShortVersionString)"

    if ! swift - "$APPCAST_PATH" "$DMG_PATH" "$sparkle_public_ed_key" "$DMG_NAME" "$bundle_version" "$short_version" "$EXPECTED_SPARKLE_DOWNLOAD_URL_PREFIX" <<'SWIFT'
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
    return firstMatch(#"(?:^|\s)\#(escapedName)="([^"]+)""#, in: tag)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 7 else { fail("invalid verifier arguments") }

let appcastURL = URL(fileURLWithPath: arguments[0])
let dmgURL = URL(fileURLWithPath: arguments[1])
let publicKeyBase64 = arguments[2]
let dmgName = arguments[3]
let bundleVersion = arguments[4]
let shortVersion = arguments[5]
let expectedDownloadURLPrefix = arguments[6]

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
let matchingEnclosures = allMatches(#"<enclosure\b[^>]*>"#, in: content).filter { tag in
    attribute("sparkle:version", in: tag) == bundleVersion &&
    attribute("sparkle:shortVersionString", in: tag) == shortVersion
}
guard matchingEnclosures.count == 1 else {
    fail("expected exactly one matching appcast enclosure")
}
let enclosure = matchingEnclosures[0]
guard let archiveSignatureBase64 = attribute("sparkle:edSignature", in: enclosure),
      let archiveURLString = attribute("url", in: enclosure),
      let archiveComponents = URLComponents(string: archiveURLString),
      archiveComponents.scheme == "https",
      archiveComponents.host?.isEmpty == false,
      archiveComponents.user == nil,
      archiveComponents.password == nil,
      archiveComponents.query == nil,
      archiveComponents.fragment == nil,
      let archiveURL = archiveComponents.url,
      archiveURL.absoluteString == archiveURLString,
      archiveURL.lastPathComponent == dmgName else {
    fail("archive signature or URL invalid")
}
if !expectedDownloadURLPrefix.isEmpty && !archiveURLString.hasPrefix(expectedDownloadURLPrefix) {
    fail("archive URL does not use expected download prefix")
}
let fileSize = (try FileManager.default.attributesOfItem(atPath: dmgURL.path)[.size] as? NSNumber)?.int64Value
let declaredLength = attribute("sparkle:length", in: enclosure) ?? attribute("length", in: enclosure)
guard let declaredLength,
      let declaredLengthValue = Int64(declaredLength),
      let fileSize,
      declaredLengthValue == fileSize else {
    fail("archive length does not match release DMG")
}
guard let archiveSignature = Data(base64Encoded: archiveSignatureBase64),
      archiveSignature.count == 64,
      publicKey.isValidSignature(archiveSignature, for: try Data(contentsOf: dmgURL)) else {
    fail("archive signature invalid")
}
SWIFT
    then
        fail "Sparkle appcast EdDSA verification failed"
    fi

    info "Sparkle appcast references the DMG, matches app version $short_version ($bundle_version), and verifies with the embedded EdDSA key"
}

main() {
    verify_checksum
    verify_dmg_trust
    verify_app_bundle
    verify_appcast
}

main "$@"

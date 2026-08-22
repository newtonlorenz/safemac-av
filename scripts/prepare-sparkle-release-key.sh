#!/bin/bash

# Validate the complete Sparkle release trust configuration and materialize the
# exported private key without printing any secret-derived value.

set -Eeuo pipefail
IFS=$'\n\t'

OUTPUT_PATH="${1:-${RUNNER_TEMP:-/tmp}/sparkle_private_ed_key}"
OUTPUT_DIRECTORY="$(dirname "$OUTPUT_PATH")"
TEMP_PATH=""
CREATED_OUTPUT=0
PRIVATE_KEY_SECRET="${SPARKLE_PRIVATE_ED_KEY_BASE64:-}"
unset SPARKLE_PRIVATE_ED_KEY_BASE64

fail() {
    printf 'Error: Sparkle release configuration is invalid\n' >&2
    exit 1
}

cleanup() {
    local status=$?

    if [[ -n "$TEMP_PATH" ]]; then
        rm -f "$TEMP_PATH"
    fi
    if [[ $status -ne 0 && "$CREATED_OUTPUT" == "1" ]]; then
        rm -f "$OUTPUT_PATH"
    fi
    exit "$status"
}

trap cleanup EXIT

[[ -n "${RUNNER_TEMP:-}" && -d "$RUNNER_TEMP" && ! -L "$RUNNER_TEMP" ]] || fail
[[ -d "$OUTPUT_DIRECTORY" && ! -L "$OUTPUT_DIRECTORY" ]] || fail
[[ "$(cd "$OUTPUT_DIRECTORY" && pwd -P)" == "$(cd "$RUNNER_TEMP" && pwd -P)" ]] || fail
[[ "$(basename "$OUTPUT_PATH")" == "sparkle_private_ed_key" ]] || fail
[[ ! -e "$OUTPUT_PATH" && ! -L "$OUTPUT_PATH" ]] || fail
[[ -n "$PRIVATE_KEY_SECRET" ]] || fail
TEMP_PATH="$(mktemp "$OUTPUT_PATH.tmp.XXXXXX")" || fail
chmod 600 "$TEMP_PATH" || fail

if ! /usr/bin/swift - "$TEMP_PATH" 3<<< "$PRIVATE_KEY_SECRET" <<'SWIFT'
import CryptoKit
import Foundation

func invalid() -> Never {
    FileHandle.standardError.write(Data("Error: Sparkle release configuration is invalid\n".utf8))
    exit(1)
}

func requiredEnvironment(_ name: String) -> String {
    guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
        invalid()
    }
    return value
}

func validHTTPSURL(_ value: String, requiresTrailingSlash: Bool) -> Bool {
    guard value.unicodeScalars.allSatisfy({
              !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0)
          }),
          let components = URLComponents(string: value),
          components.scheme == "https",
          let host = components.host, !host.isEmpty,
          components.user == nil,
          components.password == nil,
          components.query == nil,
          components.fragment == nil,
          !components.percentEncodedPath.isEmpty,
          let url = components.url,
          url.absoluteString == value else {
        return false
    }
    return !requiresTrailingSlash || components.percentEncodedPath.hasSuffix("/")
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 1 else { invalid() }

let feedURL = requiredEnvironment("SPARKLE_FEED_URL")
let downloadURLPrefix = requiredEnvironment("SPARKLE_DOWNLOAD_URL_PREFIX")
let publicKeyBase64 = requiredEnvironment("SPARKLE_PUBLIC_ED_KEY")
let privateKeyFileBase64: String
do {
    let secretData = try FileHandle(fileDescriptor: 3).readToEnd() ?? Data()
    guard let secret = String(data: secretData, encoding: .utf8) else { invalid() }
    privateKeyFileBase64 = secret.trimmingCharacters(in: .whitespacesAndNewlines)
} catch {
    invalid()
}

guard validHTTPSURL(feedURL, requiresTrailingSlash: false),
      validHTTPSURL(downloadURLPrefix, requiresTrailingSlash: true),
      let publicKeyData = Data(base64Encoded: publicKeyBase64),
      publicKeyData.count == 32,
      publicKeyData.base64EncodedString() == publicKeyBase64,
      let exportedKeyData = Data(base64Encoded: privateKeyFileBase64),
      exportedKeyData.base64EncodedString() == privateKeyFileBase64,
      let exportedKeyString = String(data: exportedKeyData, encoding: .utf8) else {
    invalid()
}

let trimmedKey = exportedKeyString.trimmingCharacters(in: .whitespacesAndNewlines)
guard !trimmedKey.isEmpty,
      exportedKeyString.unicodeScalars.allSatisfy({
          !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\r" || $0 == "\t"
      }),
      let privateSeed = Data(base64Encoded: trimmedKey),
      privateSeed.count == 32,
      privateSeed.base64EncodedString() == trimmedKey,
      let privateKey = try? Curve25519.Signing.PrivateKey(rawRepresentation: privateSeed),
      privateKey.publicKey.rawRepresentation == publicKeyData else {
    invalid()
}

let probe = Data("SafeMac AV Sparkle release preflight".utf8)
guard let signature = try? privateKey.signature(for: probe),
      privateKey.publicKey.isValidSignature(signature, for: probe) else {
    invalid()
}

do {
    let output = try FileHandle(forWritingTo: URL(fileURLWithPath: arguments[0]))
    try output.truncate(atOffset: 0)
    try output.write(contentsOf: Data((trimmedKey + "\n").utf8))
    try output.synchronize()
    try output.close()
} catch {
    invalid()
}
SWIFT
then
    exit 1
fi

chmod 600 "$TEMP_PATH" || fail
mv -f "$TEMP_PATH" "$OUTPUT_PATH" || fail
TEMP_PATH=""
CREATED_OUTPUT=1
chmod 600 "$OUTPUT_PATH" || fail
printf 'Verified: Sparkle release configuration and signing key match\n'

#!/bin/bash

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/safemac-sparkle-preflight-test.XXXXXX")"
KEY_PATH="$WORK_DIR/sparkle_private_ed_key"

cleanup() {
    rm -rf "$WORK_DIR"
}

trap cleanup EXIT

fail() {
    printf 'Test failed: %s\n' "$1" >&2
    exit 1
}

make_key_fixture() {
    swift - "$WORK_DIR" <<'SWIFT'
import CryptoKit
import Foundation

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let seed = Data(repeating: 1, count: 32)
let otherSeed = Data(repeating: 2, count: 32)
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
let otherKey = try Curve25519.Signing.PrivateKey(rawRepresentation: otherSeed)
let exportedKey = seed.base64EncodedString() + "\n"

try Data(exportedKey.utf8).base64EncodedString()
    .write(to: directory.appendingPathComponent("private-secret.txt"), atomically: true, encoding: .utf8)
try key.publicKey.rawRepresentation.base64EncodedString()
    .write(to: directory.appendingPathComponent("public-key.txt"), atomically: true, encoding: .utf8)
try otherKey.publicKey.rawRepresentation.base64EncodedString()
    .write(to: directory.appendingPathComponent("wrong-public-key.txt"), atomically: true, encoding: .utf8)
SWIFT
}

run_preflight() {
    SPARKLE_FEED_URL="${SPARKLE_FEED_URL_VALUE:-https://updates.example.com/appcast.xml}" \
    SPARKLE_DOWNLOAD_URL_PREFIX="${SPARKLE_DOWNLOAD_URL_PREFIX_VALUE:-https://downloads.example.com/releases/}" \
    SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY_VALUE:-$(cat "$WORK_DIR/public-key.txt")}" \
    SPARKLE_PRIVATE_ED_KEY_BASE64="${SPARKLE_PRIVATE_ED_KEY_BASE64_VALUE:-$(cat "$WORK_DIR/private-secret.txt")}" \
        "$PROJECT_DIR/scripts/prepare-sparkle-release-key.sh" "$KEY_PATH"
}

expect_failure() {
    local label="$1"
    shift

    rm -f "$KEY_PATH"
    if "$@" >"$WORK_DIR/stdout" 2>"$WORK_DIR/stderr"; then
        fail "$label was accepted"
    fi
    [[ ! -e "$KEY_PATH" ]] || fail "$label left private key material behind"
    [[ "$(cat "$WORK_DIR/stderr")" == "Error: Sparkle release configuration is invalid" ]] \
        || fail "$label did not use the generic redacted error"
    if grep -Fq "$(cat "$WORK_DIR/private-secret.txt")" "$WORK_DIR/stdout" "$WORK_DIR/stderr"; then
        fail "$label leaked private key material"
    fi
}

test_valid_configuration() {
    run_preflight >/dev/null
    [[ -f "$KEY_PATH" ]] || fail "preflight did not create the private key file"
    [[ "$(stat -f '%Lp' "$KEY_PATH")" == "600" ]] || fail "private key file mode is not 0600"
    [[ "$(cat "$KEY_PATH")" == "$(printf '\001%.0s' {1..32} | base64)" ]] \
        || fail "preflight did not preserve the Sparkle exported key format"
}

test_invalid_urls() {
    SPARKLE_FEED_URL_VALUE="http://updates.example.com/appcast.xml" \
        expect_failure "non-HTTPS feed URL" run_preflight
    SPARKLE_FEED_URL_VALUE="https://user:password@updates.example.com/appcast.xml" \
        expect_failure "credential-bearing feed URL" run_preflight
    SPARKLE_DOWNLOAD_URL_PREFIX_VALUE="https://downloads.example.com/releases" \
        expect_failure "download prefix without trailing slash" run_preflight
    SPARKLE_DOWNLOAD_URL_PREFIX_VALUE="https://downloads.example.com/releases/?token=secret" \
        expect_failure "download prefix with query" run_preflight
}

test_invalid_public_keys() {
    SPARKLE_PUBLIC_ED_KEY_VALUE="not-base64" \
        expect_failure "malformed public key" run_preflight
    SPARKLE_PUBLIC_ED_KEY_VALUE="$(printf 'short' | base64)" \
        expect_failure "wrong-length public key" run_preflight
}

test_invalid_private_keys() {
    SPARKLE_PRIVATE_ED_KEY_BASE64_VALUE="not-base64" \
        expect_failure "malformed private-key secret" run_preflight
    SPARKLE_PRIVATE_ED_KEY_BASE64_VALUE="$(printf 'not-an-exported-key' | base64)" \
        expect_failure "malformed exported private key" run_preflight
    SPARKLE_PRIVATE_ED_KEY_BASE64_VALUE="$(cat "$WORK_DIR/private-secret.txt")==" \
        expect_failure "non-canonical private-key secret" run_preflight
}

test_public_private_mismatch() {
    SPARKLE_PUBLIC_ED_KEY_VALUE="$(cat "$WORK_DIR/wrong-public-key.txt")" \
        expect_failure "public/private key mismatch" run_preflight
}

test_workflow_runs_preflight_before_signing() {
    local workflow="$PROJECT_DIR/.github/workflows/release-package.yml"
    local preflight_line
    local certificate_line

    preflight_line="$(grep -n 'name: Preflight Sparkle release trust' "$workflow" | cut -d: -f1)"
    certificate_line="$(grep -n 'name: Import Developer ID certificate' "$workflow" | cut -d: -f1)"
    [[ -n "$preflight_line" && -n "$certificate_line" && "$preflight_line" -lt "$certificate_line" ]] \
        || fail "workflow does not run Sparkle preflight before certificate import"
    grep -Fq 'rm -f "$RUNNER_TEMP/sparkle_private_ed_key"' "$workflow" \
        || fail "workflow does not clean up the Sparkle private key"
}

main() {
    make_key_fixture
    test_valid_configuration
    test_invalid_urls
    test_invalid_public_keys
    test_invalid_private_keys
    test_public_private_mismatch
    test_workflow_runs_preflight_before_signing
    printf 'Sparkle release preflight tests passed\n'
}

main "$@"

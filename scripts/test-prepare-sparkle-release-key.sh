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
    RUNNER_TEMP="$WORK_DIR" \
    SPARKLE_FEED_URL="${SPARKLE_FEED_URL_VALUE:-https://updates.example.com/appcast.xml}" \
    SPARKLE_DOWNLOAD_URL_PREFIX="${SPARKLE_DOWNLOAD_URL_PREFIX_VALUE:-https://downloads.example.com/releases/}" \
    SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY_VALUE:-$(cat "$WORK_DIR/public-key.txt")}" \
    SPARKLE_PRIVATE_ED_KEY_BASE64="${SPARKLE_PRIVATE_ED_KEY_BASE64_VALUE:-$(cat "$WORK_DIR/private-secret.txt")}" \
        "$PROJECT_DIR/scripts/prepare-sparkle-release-key.sh" "$KEY_PATH"
}

run_preflight_check_only() {
    RUNNER_TEMP="${CHECK_ONLY_RUNNER_TEMP:-$WORK_DIR}" \
    SAFEMAC_SPARKLE_KEY_CHECK_ONLY=1 \
    SPARKLE_FEED_URL="${SPARKLE_FEED_URL_VALUE:-https://updates.example.com/appcast.xml}" \
    SPARKLE_DOWNLOAD_URL_PREFIX="${SPARKLE_DOWNLOAD_URL_PREFIX_VALUE:-https://downloads.example.com/releases/}" \
    SPARKLE_PUBLIC_ED_KEY="${SPARKLE_PUBLIC_ED_KEY_VALUE:-$(cat "$WORK_DIR/public-key.txt")}" \
    SPARKLE_PRIVATE_ED_KEY_BASE64="${SPARKLE_PRIVATE_ED_KEY_BASE64_VALUE:-$(cat "$WORK_DIR/private-secret.txt")}" \
        "$PROJECT_DIR/scripts/prepare-sparkle-release-key.sh"
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

test_check_only_configuration() {
    local read_only_runner_temp="$WORK_DIR/read-only-runner-temp"

    rm -f "$KEY_PATH"
    run_preflight_check_only >/dev/null
    [[ ! -e "$KEY_PATH" ]] || fail "check-only preflight created the release key output"
    if find "$WORK_DIR" -maxdepth 1 -name 'sparkle_private_ed_key.preflight.*' -print -quit | grep -q .; then
        fail "check-only preflight left temporary private key material behind"
    fi

    printf 'existing-key\n' > "$KEY_PATH"
    chmod 600 "$KEY_PATH"
    run_preflight_check_only >/dev/null
    [[ "$(cat "$KEY_PATH")" == "existing-key" ]] \
        || fail "check-only preflight changed an existing release key output"
    rm -f "$KEY_PATH"

    mkdir "$read_only_runner_temp"
    chmod 500 "$read_only_runner_temp"
    CHECK_ONLY_RUNNER_TEMP="$read_only_runner_temp" run_preflight_check_only >/dev/null \
        || fail "check-only preflight required a filesystem write"
    chmod 700 "$read_only_runner_temp"
    rmdir "$read_only_runner_temp"

    if SPARKLE_FEED_URL_VALUE="http://updates.example.com/appcast.xml" \
       run_preflight_check_only >"$WORK_DIR/stdout" 2>"$WORK_DIR/stderr"; then
        fail "invalid check-only configuration was accepted"
    fi
    [[ "$(cat "$WORK_DIR/stderr")" == "Error: Sparkle release configuration is invalid" ]] \
        || fail "check-only failure did not use the generic redacted error"
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

test_existing_output_survives_failure() {
    printf 'existing-key\n' > "$KEY_PATH"
    chmod 600 "$KEY_PATH"
    if SPARKLE_FEED_URL_VALUE="http://updates.example.com/appcast.xml" \
        run_preflight >"$WORK_DIR/stdout" 2>"$WORK_DIR/stderr"; then
        fail "invalid configuration with existing output was accepted"
    fi
    [[ "$(cat "$WORK_DIR/stderr")" == "Error: Sparkle release configuration is invalid" ]] \
        || fail "invalid configuration with existing output did not use the generic redacted error"
    if grep -Fq "$(cat "$WORK_DIR/private-secret.txt")" "$WORK_DIR/stdout" "$WORK_DIR/stderr"; then
        fail "invalid configuration with existing output leaked private key material"
    fi
    [[ "$(cat "$KEY_PATH")" == "existing-key" ]] \
        || fail "preflight failure changed an existing output key"
}

test_symlink_output_is_rejected() {
    local outside_key="$WORK_DIR/outside-key"

    rm -f "$KEY_PATH"
    printf 'outside-key\n' > "$outside_key"
    ln -s "$outside_key" "$KEY_PATH"
    if run_preflight >"$WORK_DIR/stdout" 2>"$WORK_DIR/stderr"; then
        fail "symlinked private-key output was accepted"
    fi
    [[ -L "$KEY_PATH" ]] || fail "preflight replaced the symlinked output"
    [[ "$(cat "$outside_key")" == "outside-key" ]] \
        || fail "preflight changed the symlink target"
    rm -f "$KEY_PATH"
}

test_workflow_runs_preflight_before_signing() {
    local workflow="$PROJECT_DIR/.github/workflows/release-package.yml"
    local validation_line
    local preflight_line
    local certificate_line
    local credential_cleanup_line
    local appcast_line
    local sparkle_cleanup_line
    local verifier_line
    local upload_line

    validation_line="$(grep -n 'name: Validate immutable release tag' "$workflow" | cut -d: -f1)"
    preflight_line="$(grep -n 'name: Preflight Sparkle release trust' "$workflow" | cut -d: -f1)"
    certificate_line="$(grep -n 'name: Import Developer ID certificate' "$workflow" | cut -d: -f1)"
    credential_cleanup_line="$(grep -n 'name: Remove release credentials before artifact upload' "$workflow" | cut -d: -f1 || true)"
    appcast_line="$(grep -n 'name: Generate Sparkle appcast' "$workflow" | cut -d: -f1)"
    sparkle_cleanup_line="$(grep -n 'cleanup_sparkle_key' "$workflow" | head -1 | cut -d: -f1 || true)"
    verifier_line="$(grep -n 'name: Verify distribution artifacts' "$workflow" | cut -d: -f1)"
    upload_line="$(grep -n 'name: Upload release artifacts' "$workflow" | cut -d: -f1)"
    [[ -n "$validation_line" && -n "$preflight_line" && -n "$certificate_line" && -n "$appcast_line" && -n "$verifier_line" && -n "$upload_line" ]] \
        || fail "workflow trust steps are missing"
    [[ "$validation_line" -lt "$preflight_line" && "$preflight_line" -lt "$certificate_line" ]] \
        || fail "workflow does not validate the release tag before secret-bearing steps"
    grep -Fq "if: github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/main'" "$workflow" \
        || fail "release job is not restricted to workflow dispatch from main"
    grep -Fq 'environment: release' "$workflow" \
        || fail "release job does not use the protected release environment"
    grep -Fq 'ref: ${{ github.sha }}' "$workflow" \
        || fail "workflow does not check out trusted main before validation"
    grep -Fq 'ref: ${{ steps.validate_release.outputs.release_commit }}' "$workflow" \
        || fail "workflow does not check out the immutable validated commit"
    grep -Fq '[[ "$release_commit" == "$main_commit" ]] || fail' "$workflow" \
        || fail "workflow does not require the tag commit to equal current main"
    grep -Fq '"$RUNNER_TEMP/sparkle_private_ed_key"' "$workflow" \
        || fail "workflow does not clean up the Sparkle private key"
    [[ -n "$credential_cleanup_line" && "$credential_cleanup_line" -lt "$upload_line" ]] \
        || fail "workflow does not remove release credentials before artifact upload"
    grep -Fq 'security delete-keychain "$RUNNER_TEMP/safemac-release.keychain-db"' "$workflow" \
        || fail "workflow cleanup does not cover a partially-created deterministic keychain"
    [[ -n "$sparkle_cleanup_line" && "$appcast_line" -lt "$sparkle_cleanup_line" && "$sparkle_cleanup_line" -lt "$verifier_line" ]] \
        || fail "workflow does not remove the Sparkle private key before verification"
    grep -Fq 'SAFEMAC_SPARKLE_KEY_CHECK_ONLY: "1"' "$workflow" \
        || fail "workflow preflight does not use check-only private-key validation"
    if grep -Fq 'echo "SPARKLE_PRIVATE_ED_KEY=$SPARKLE_PRIVATE_ED_KEY"' "$workflow"; then
        fail "workflow persists the Sparkle private-key path globally"
    fi
}

extract_release_ref_validation() {
    local workflow="$PROJECT_DIR/.github/workflows/release-package.yml"

    awk '
        /name: Validate immutable release tag/ { in_step = 1; next }
        in_step && /^        run: \|$/ { in_run = 1; next }
        in_run && /^      - name:/ { exit }
        in_run { sub(/^          /, ""); print }
    ' "$workflow"
}

run_workflow_validation() {
    local repository="$1"
    local release_ref="$2"
    local github_output="$WORK_DIR/github-output"
    local validation_script="$WORK_DIR/validate-release-ref.sh"

    : > "$github_output"
    extract_release_ref_validation > "$validation_script"
    chmod +x "$validation_script"
    (
        cd "$repository"
        GITHUB_REF="refs/heads/main" \
        GITHUB_OUTPUT="$github_output" \
        RELEASE_REF="$release_ref" \
            bash "$validation_script"
    )
}

test_workflow_release_ref_validation_behavior() {
    local origin="$WORK_DIR/release-origin.git"
    local source="$WORK_DIR/release-source"
    local runner="$WORK_DIR/release-runner"
    local main_commit

    git init --bare -q "$origin"
    git init -q -b main "$source"
    git -C "$source" config user.name "SafeMac Test"
    git -C "$source" config user.email "test@example.com"
    printf 'historical main\n' > "$source/release.txt"
    git -C "$source" add release.txt
    git -C "$source" commit -q -m "historical release"
    git -C "$source" tag -a v1.2.2 -m "SafeMac AV v1.2.2"
    printf 'current main\n' > "$source/release.txt"
    git -C "$source" commit -qam "current release"
    main_commit="$(git -C "$source" rev-parse HEAD)"
    git -C "$source" remote add origin "$origin"
    git -C "$source" push -q -u origin main

    git -C "$source" tag -a v1.2.3 -m "SafeMac AV v1.2.3"
    git -C "$source" tag v1.2.4
    git -C "$source" switch -q -c not-main
    printf 'not main\n' >> "$source/release.txt"
    git -C "$source" commit -qam "off-main release"
    git -C "$source" tag -a v1.2.5 -m "SafeMac AV v1.2.5"
    git -C "$source" push -q origin refs/tags/v1.2.2 refs/tags/v1.2.3 refs/tags/v1.2.4 refs/tags/v1.2.5

    git clone -q --branch main "$origin" "$runner"
    run_workflow_validation "$runner" "refs/tags/v1.2.3" >/dev/null
    grep -Fxq "release_commit=$main_commit" "$WORK_DIR/github-output" \
        || fail "valid annotated tag did not resolve to the expected commit"

    if run_workflow_validation "$runner" "refs/tags/v1.2.2" >/dev/null 2>&1; then
        fail "historical main release tag was accepted"
    fi

    if run_workflow_validation "$runner" "refs/tags/v1.2.4" >/dev/null 2>&1; then
        fail "lightweight release tag was accepted"
    fi
    if run_workflow_validation "$runner" "refs/tags/v1.2.5" >/dev/null 2>&1; then
        fail "release tag outside main was accepted"
    fi
    if run_workflow_validation "$runner" "refs/heads/main" >/dev/null 2>&1; then
        fail "branch release ref was accepted"
    fi
    if run_workflow_validation "$runner" "refs/tags/release-1.2.3" >/dev/null 2>&1; then
        fail "malformed release tag ref was accepted"
    fi
}

main() {
    make_key_fixture
    test_valid_configuration
    test_check_only_configuration
    test_invalid_urls
    test_invalid_public_keys
    test_invalid_private_keys
    test_public_private_mismatch
    test_existing_output_survives_failure
    test_symlink_output_is_rejected
    test_workflow_runs_preflight_before_signing
    test_workflow_release_ref_validation_behavior
    printf 'Sparkle release preflight tests passed\n'
}

main "$@"

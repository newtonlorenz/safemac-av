#!/bin/bash

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/safemac-github-controls-test.XXXXXX")"

cleanup() {
    rm -rf "$WORK_DIR"
}

trap cleanup EXIT

fail() {
    printf 'Test failed: %s\n' "$1" >&2
    exit 1
}

write_fake_gh() {
    local body="$1"

    mkdir -p "$WORK_DIR/bin"
    {
        printf '#!/bin/bash\n'
        printf 'set -Eeuo pipefail\n'
        printf '%s\n' "$body"
    } > "$WORK_DIR/bin/gh"
    chmod +x "$WORK_DIR/bin/gh"
}

install_success_fixture() {
    write_fake_gh '
[[ "${1:-}" == "api" ]] || exit 2
path=""
has_jq=0
for argument in "$@"; do
    if [[ "$argument" == repos/* ]]; then
        path="$argument"
    fi
    [[ "$argument" != "--jq" ]] || has_jq=1
done
case "$path" in
    repos/newtonlorenz/safemac-av/environments/release)
        if [[ "$has_jq" == "0" ]]; then
            printf "%s\n" "{\"name\":\"release\",\"protection_rules\":[{\"type\":\"required_reviewers\",\"reviewers\":[{\"type\":\"User\",\"reviewer\":{\"login\":\"maintainer\"}}]}]}"
        elif [[ "${SAFEMAC_FAKE_MISSING_REVIEWER:-0}" == "1" ]]; then
            printf "%s\n" "0"
        else
            printf "%s\n" "1"
        fi
        ;;
    repos/newtonlorenz/safemac-av/environments/release/secrets)
        printf "%s\n" \
            DEVELOPER_ID_CERTIFICATE_BASE64 \
            DEVELOPER_ID_CERTIFICATE_PASSWORD \
            RELEASE_KEYCHAIN_PASSWORD \
            NOTARY_KEY_BASE64 \
            NOTARY_KEY_ID \
            NOTARY_ISSUER_ID
        if [[ "${SAFEMAC_FAKE_MISSING_SECRET:-0}" != "1" ]]; then
            printf "%s\n" SPARKLE_PRIVATE_ED_KEY_BASE64
        fi
        ;;
    repos/newtonlorenz/safemac-av/actions/variables)
        printf "%s\n" \
            SPARKLE_FEED_URL \
            SPARKLE_PUBLIC_ED_KEY
        if [[ "${SAFEMAC_FAKE_MISSING_VARIABLE:-0}" != "1" ]]; then
            printf "%s\n" SPARKLE_DOWNLOAD_URL_PREFIX
        fi
        ;;
    repos/newtonlorenz/safemac-av/rulesets)
        if [[ "${SAFEMAC_FAKE_MISSING_RULESET:-0}" == "1" ]]; then
            printf "%s\n" "0"
        else
            printf "%s\n" "1"
        fi
        ;;
    *)
        exit 2
        ;;
esac'
}

run_verifier() {
    env \
    SAFEMAC_GITHUB_REPOSITORY="newtonlorenz/safemac-av" \
    PATH="$WORK_DIR/bin:$PATH" \
        "$PROJECT_DIR/scripts/verify-github-release-controls.sh"
}

test_success_case() {
    install_success_fixture
    if ! run_verifier >"$WORK_DIR/stdout" 2>"$WORK_DIR/stderr"; then
        sed 's/^/verifier stderr: /' "$WORK_DIR/stderr" >&2
        fail "success case failed"
    fi
    grep -Fq "Verified: release environment, reviewers, and required secrets" "$WORK_DIR/stdout" \
        || fail "success case did not verify release environment"
    grep -Fq "Verified: Sparkle release repository variables" "$WORK_DIR/stdout" \
        || fail "success case did not verify repository variables"
    grep -Fq "Verified: immutable v* tag ruleset" "$WORK_DIR/stdout" \
        || fail "success case did not verify tag ruleset"
}

test_missing_reviewer_fails() {
    install_success_fixture
    if SAFEMAC_FAKE_MISSING_REVIEWER=1 run_verifier >"$WORK_DIR/stdout" 2>"$WORK_DIR/stderr"; then
        fail "missing release reviewer was accepted"
    fi
    grep -Fq "has no required reviewers" "$WORK_DIR/stderr" \
        || fail "missing reviewer failure was not specific"
}

test_missing_secret_fails() {
    install_success_fixture
    if SAFEMAC_FAKE_MISSING_SECRET=1 run_verifier >"$WORK_DIR/stdout" 2>"$WORK_DIR/stderr"; then
        fail "missing Sparkle private key secret was accepted"
    fi
    grep -Fq "release environment secrets is missing SPARKLE_PRIVATE_ED_KEY_BASE64" "$WORK_DIR/stderr" \
        || fail "missing secret failure was not specific"
}

test_missing_variable_fails() {
    install_success_fixture
    if SAFEMAC_FAKE_MISSING_VARIABLE=1 run_verifier >"$WORK_DIR/stdout" 2>"$WORK_DIR/stderr"; then
        fail "missing download URL variable was accepted"
    fi
    grep -Fq "repository variables is missing SPARKLE_DOWNLOAD_URL_PREFIX" "$WORK_DIR/stderr" \
        || fail "missing variable failure was not specific"
}

test_missing_ruleset_fails() {
    install_success_fixture
    if SAFEMAC_FAKE_MISSING_RULESET=1 run_verifier >"$WORK_DIR/stdout" 2>"$WORK_DIR/stderr"; then
        fail "missing tag ruleset was accepted"
    fi
    grep -Fq "active tag ruleset for refs/tags/v*" "$WORK_DIR/stderr" \
        || fail "missing ruleset failure was not specific"
}

test_invalid_repository_override_fails() {
    install_success_fixture
    if SAFEMAC_GITHUB_REPOSITORY="../bad" \
       PATH="$WORK_DIR/bin:$PATH" \
        "$PROJECT_DIR/scripts/verify-github-release-controls.sh" >"$WORK_DIR/stdout" 2>"$WORK_DIR/stderr"; then
        fail "invalid repository override was accepted"
    fi
    grep -Fq "SAFEMAC_GITHUB_REPOSITORY must be owner/name" "$WORK_DIR/stderr" \
        || fail "invalid repository failure was not specific"
}

test_tag_ruleset_query_requires_update_rule() {
    grep -Fq 'index("update")' "$PROJECT_DIR/scripts/verify-github-release-controls.sh" \
        || fail "tag ruleset query does not require the update rule"
    if grep -Fq 'index("non_fast_forward")' "$PROJECT_DIR/scripts/verify-github-release-controls.sh"; then
        fail "tag ruleset query still relies on non_fast_forward for tag updates"
    fi
}

main() {
    test_success_case
    test_missing_reviewer_fails
    test_missing_secret_fails
    test_missing_variable_fails
    test_missing_ruleset_fails
    test_invalid_repository_override_fails
    test_tag_ruleset_query_requires_update_rule
    printf 'GitHub release controls tests passed\n'
}

main "$@"

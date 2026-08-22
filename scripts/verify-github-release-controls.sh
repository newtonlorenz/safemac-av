#!/bin/bash

# Read-only preflight for GitHub release controls that cannot be enforced by a
# pull request. It validates the protected release environment, required release
# secrets/variables, and immutable v* tag rules before a notarized release run.

set -Eeuo pipefail
IFS=$'\n\t'

REPOSITORY="${SAFEMAC_GITHUB_REPOSITORY:-}"
RELEASE_ENVIRONMENT="${SAFEMAC_RELEASE_ENVIRONMENT:-release}"

REQUIRED_ENVIRONMENT_SECRETS=(
    DEVELOPER_ID_CERTIFICATE_BASE64
    DEVELOPER_ID_CERTIFICATE_PASSWORD
    RELEASE_KEYCHAIN_PASSWORD
    NOTARY_KEY_BASE64
    NOTARY_KEY_ID
    NOTARY_ISSUER_ID
    SPARKLE_PRIVATE_ED_KEY_BASE64
)

REQUIRED_REPOSITORY_VARIABLES=(
    SPARKLE_FEED_URL
    SPARKLE_PUBLIC_ED_KEY
    SPARKLE_DOWNLOAD_URL_PREFIX
)

fail() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

info() {
    printf 'Verified: %s\n' "$1"
}

require_gh() {
    command -v gh >/dev/null 2>&1 || fail "gh is required"
}

resolve_repository() {
    local owner
    local name

    if [[ -n "$REPOSITORY" ]]; then
        [[ "$REPOSITORY" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
            || fail "SAFEMAC_GITHUB_REPOSITORY must be owner/name"
        owner="${REPOSITORY%%/*}"
        name="${REPOSITORY#*/}"
        [[ "$owner" != "." && "$owner" != ".." && "$name" != "." && "$name" != ".." ]] \
            || fail "SAFEMAC_GITHUB_REPOSITORY must be owner/name"
        return
    fi

    REPOSITORY="$(gh repo view --json owner,name --jq '.owner.login + "/" + .name')" \
        || fail "unable to resolve GitHub repository"
    [[ -n "$REPOSITORY" ]] || fail "unable to resolve GitHub repository"
}

api() {
    local path="$1"
    shift
    gh api "repos/$REPOSITORY/$path" "$@"
}

require_named_values() {
    local label="$1"
    local values="$2"
    shift 2
    local expected

    for expected in "$@"; do
        grep -Fxq "$expected" <<< "$values" \
            || fail "$label is missing $expected"
    done
}

verify_release_environment() {
    local reviewers
    local secrets

    api "environments/$RELEASE_ENVIRONMENT" >/dev/null \
        || fail "GitHub environment '$RELEASE_ENVIRONMENT' is missing"

    reviewers="$(api "environments/$RELEASE_ENVIRONMENT" \
        --jq '[.protection_rules[]? | select(.type == "required_reviewers") | .reviewers[]?] | length')" \
        || fail "unable to inspect release environment reviewers"
    [[ "$reviewers" =~ ^[0-9]+$ && "$reviewers" -gt 0 ]] \
        || fail "GitHub environment '$RELEASE_ENVIRONMENT' has no required reviewers"

    secrets="$(api "environments/$RELEASE_ENVIRONMENT/secrets" --jq '.secrets[]?.name')" \
        || fail "unable to inspect release environment secrets"
    require_named_values "release environment secrets" "$secrets" "${REQUIRED_ENVIRONMENT_SECRETS[@]}"
    info "release environment, reviewers, and required secrets"
}

verify_repository_variables() {
    local variables

    variables="$(api "actions/variables" --jq '.variables[]?.name')" \
        || fail "unable to inspect repository variables"
    require_named_values "repository variables" "$variables" "${REQUIRED_REPOSITORY_VARIABLES[@]}"
    info "Sparkle release repository variables"
}

verify_tag_ruleset() {
    local matching_ruleset_count

    matching_ruleset_count="$(api "rulesets" --jq '
        [
          .[]?
          | select(.target == "tag")
          | select(.enforcement == "active")
          | select(
              (
                [.conditions.ref_name.include[]?] | index("refs/tags/v*")
              ) or (
                [.conditions.ref_name.include[]?] | index("~ALL")
              )
            )
          | select([.rules[]?.type] | index("creation"))
          | select([.rules[]?.type] | index("update"))
          | select([.rules[]?.type] | index("deletion"))
        ] | length
    ')" || fail "unable to inspect repository rulesets"

    [[ "$matching_ruleset_count" =~ ^[0-9]+$ && "$matching_ruleset_count" -gt 0 ]] \
        || fail "active tag ruleset for refs/tags/v* must restrict creation, update, and deletion"
    info "immutable v* tag ruleset"
}

main() {
    require_gh
    resolve_repository
    verify_release_environment
    verify_repository_variables
    verify_tag_ruleset
}

main "$@"

#!/bin/bash

# Generate a Sparkle appcast for a directory containing release archives.
# Set SPARKLE_PRIVATE_ED_KEY to the private EdDSA key path used by Sparkle.

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
APPCAST_INPUT_DIR="${1:-$PROJECT_DIR/build/appcast}"
SPARKLE_PRIVATE_ED_KEY="${SPARKLE_PRIVATE_ED_KEY:-}"
SPARKLE_DOWNLOAD_URL_PREFIX="${SPARKLE_DOWNLOAD_URL_PREFIX:-}"
GENERATE_APPCAST="${GENERATE_APPCAST:-}"

fail() {
    printf 'Error: %s\n' "$1" >&2
    exit 1
}

find_generate_appcast() {
    local candidate
    local search_root

    if [[ -n "$GENERATE_APPCAST" ]]; then
        [[ -x "$GENERATE_APPCAST" ]] || fail "GENERATE_APPCAST is not executable: $GENERATE_APPCAST"
        printf '%s\n' "$GENERATE_APPCAST"
        return
    fi

    for candidate in \
        "$PROJECT_DIR/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast" \
        "$PROJECT_DIR/build/DerivedData/SourcePackages/checkouts/Sparkle/bin/generate_appcast" \
        "$PROJECT_DIR/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast" \
        "$PROJECT_DIR/SourcePackages/checkouts/Sparkle/bin/generate_appcast"; do
        if [[ -x "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return
        fi
    done

    search_root="$HOME/Library/Developer/Xcode/DerivedData"
    if [[ -d "$search_root" ]]; then
        candidate="$(find "$search_root" \( -path '*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast' -o -path '*/SourcePackages/checkouts/Sparkle/bin/generate_appcast' \) -perm -111 -print -quit)"
        if [[ -n "$candidate" ]]; then
            printf '%s\n' "$candidate"
            return
        fi
    fi

    fail "Sparkle generate_appcast not found. Resolve packages or set GENERATE_APPCAST."
}

main() {
    local -a appcast_args

    [[ -d "$APPCAST_INPUT_DIR" ]] || fail "Appcast input directory not found: $APPCAST_INPUT_DIR"
    [[ -n "$SPARKLE_PRIVATE_ED_KEY" ]] || fail "SPARKLE_PRIVATE_ED_KEY is required."
    [[ -f "$SPARKLE_PRIVATE_ED_KEY" ]] || fail "Sparkle private key not found: $SPARKLE_PRIVATE_ED_KEY"

    appcast_args=(
        --ed-key-file "$SPARKLE_PRIVATE_ED_KEY"
    )
    if [[ -n "$SPARKLE_DOWNLOAD_URL_PREFIX" ]]; then
        appcast_args+=(--download-url-prefix "$SPARKLE_DOWNLOAD_URL_PREFIX")
    fi

    "$(find_generate_appcast)" \
        "${appcast_args[@]}" \
        "$APPCAST_INPUT_DIR"

    [[ -f "$APPCAST_INPUT_DIR/appcast.xml" ]] || fail "appcast.xml was not created in $APPCAST_INPUT_DIR"
    printf 'Appcast generated: %s\n' "$APPCAST_INPUT_DIR/appcast.xml"
}

main "$@"

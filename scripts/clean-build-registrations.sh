#!/bin/bash

set -Eeuo pipefail
IFS=$'\n\t'

LSREGISTER_BIN="${LSREGISTER_BIN:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"

fail() {
    printf 'Error: %s\n' "$1" >&2
    exit 2
}

has_symlink_component() {
    local path="$1"

    while [[ "$path" != "/" ]]; do
        [[ ! -L "$path" ]] || return 0
        path="${path%/*}"
        [[ -n "$path" ]] || path="/"
    done
    return 1
}

validate_build_root() {
    local path="$1"

    [[ "$path" == /* ]] || fail "build root must be an absolute path"
    case "$path" in
        /|/Applications|/Applications/*)
            fail "refusing unsafe build root: $path"
            ;;
        *//*|*/./*|*/../*|*/.|*/..)
            fail "build root must not contain ambiguous path components: $path"
            ;;
    esac
    if has_symlink_component "$path"; then
        fail "build root must not contain symlinks: $path"
    fi
    [[ ! -e "$path" || -d "$path" ]] || fail "build root is not a directory: $path"
}

unregister_build_products() {
    local build_root="$1"
    local app_path
    local nested_app_path
    local unregister_status=0

    [[ -d "$build_root" ]] || return 0
    while IFS= read -r -d '' app_path; do
        case "$app_path" in
            "$build_root"/SafeMac\ AV.app|"$build_root"/ClamAV-GUI.app|\
            "$build_root"/ClamAV-GUIUITests-Runner.app|\
            "$build_root"/*/SafeMac\ AV.app|"$build_root"/*/ClamAV-GUI.app|\
            "$build_root"/*/ClamAV-GUIUITests-Runner.app)
                while IFS= read -r -d '' nested_app_path; do
                    if ! "$LSREGISTER_BIN" -u "$nested_app_path" >/dev/null 2>&1; then
                        printf 'Warning: could not unregister %s\n' "$nested_app_path" >&2
                        unregister_status=1
                    fi
                done < <(
                    /usr/bin/find "$app_path" \
                        -mindepth 1 \
                        -type d \
                        -name '*.app' \
                        -prune \
                        -print0
                )
                if ! "$LSREGISTER_BIN" -u "$app_path" >/dev/null 2>&1; then
                    printf 'Warning: could not unregister %s\n' "$app_path" >&2
                    unregister_status=1
                fi
                ;;
            *)
                fail "refusing cleanup target outside build root: $app_path"
                ;;
        esac
    done < <(
        /usr/bin/find "$build_root" \
            -type d \( \
                -name 'SafeMac AV.app' \
                -o -name 'ClamAV-GUI.app' \
                -o -name 'ClamAV-GUIUITests-Runner.app' \
            \) \
            -prune -print0
    )
    return "$unregister_status"
}

main() {
    (($# == 1)) || fail "usage: ${0##*/} BUILD_ROOT"
    validate_build_root "$1"
    [[ -x "$LSREGISTER_BIN" ]] || fail "lsregister is unavailable: $LSREGISTER_BIN"
    unregister_build_products "$1"
}

main "$@"

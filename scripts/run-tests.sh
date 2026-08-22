#!/bin/bash

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
XCODEBUILD_BIN="${XCODEBUILD_BIN:-/usr/bin/xcodebuild}"
LSREGISTER_BIN="${LSREGISTER_BIN:-/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister}"
CLEAN_REGISTRATIONS_BIN="$PROJECT_DIR/scripts/clean-build-registrations.sh"
DERIVED_DATA_ROOT=""
OWNS_DERIVED_DATA_ROOT=false

fail() {
    printf 'Error: %s\n' "$1" >&2
    exit 2
}

make_derived_data_root() {
    local requested_root="${SAFEMAC_TEST_DERIVED_DATA_ROOT:-}"
    local system_temp_root

    if [[ -n "$requested_root" ]]; then
        LSREGISTER_BIN="$LSREGISTER_BIN" "$CLEAN_REGISTRATIONS_BIN" "$requested_root"
        [[ ! -e "$requested_root" && ! -L "$requested_root" ]] \
            || fail "test DerivedData root must not already exist: $requested_root"
        /bin/mkdir -p "$requested_root"
        DERIVED_DATA_ROOT="$requested_root"
    else
        system_temp_root="$(/usr/bin/getconf DARWIN_USER_TEMP_DIR)"
        system_temp_root="$(cd "$system_temp_root" && pwd -P)"
        DERIVED_DATA_ROOT="$(mktemp -d "$system_temp_root/safemac-tests-derived-data.XXXXXX")"
        LSREGISTER_BIN="$LSREGISTER_BIN" "$CLEAN_REGISTRATIONS_BIN" "$DERIVED_DATA_ROOT"
    fi

    OWNS_DERIVED_DATA_ROOT=true
    [[ "$(cd "$DERIVED_DATA_ROOT" && pwd -P)" == "$DERIVED_DATA_ROOT" ]] \
        || fail "DerivedData root resolved outside its requested path"
}

cleanup() {
    local command_status=$?

    trap - EXIT
    if [[ "$OWNS_DERIVED_DATA_ROOT" == true ]]; then
        if LSREGISTER_BIN="$LSREGISTER_BIN" \
            "$CLEAN_REGISTRATIONS_BIN" "$DERIVED_DATA_ROOT"; then
            /bin/rm -rf -- "$DERIVED_DATA_ROOT"
        else
            printf 'Warning: preserved unvalidated DerivedData root: %s\n' \
                "$DERIVED_DATA_ROOT" >&2
        fi
    fi
    exit "$command_status"
}

usage() {
    printf 'Usage: %s [unit|release|ui]\n' "${0##*/}" >&2
}

run_xcodebuild() {
    local mode="$1"
    local -a common_arguments=(
        -project "$PROJECT_DIR/ClamAV-GUI.xcodeproj"
        -destination 'platform=macOS'
        -derivedDataPath "$DERIVED_DATA_ROOT"
    )

    case "$mode" in
        unit)
            "$XCODEBUILD_BIN" \
                "${common_arguments[@]}" \
                -scheme ClamAV-GUI \
                CODE_SIGNING_ALLOWED=NO \
                CODE_SIGNING_REQUIRED=NO \
                test
            ;;
        release)
            "$XCODEBUILD_BIN" \
                "${common_arguments[@]}" \
                -scheme ClamAV-GUI \
                -configuration Release \
                CODE_SIGNING_ALLOWED=NO \
                CODE_SIGNING_REQUIRED=NO \
                build
            ;;
        ui)
            "$XCODEBUILD_BIN" \
                "${common_arguments[@]}" \
                -scheme ClamAV-GUI-UI \
                test
            ;;
        *)
            usage
            return 2
            ;;
    esac
}

main() {
    local mode="${1:-unit}"

    (($# <= 1)) || {
        usage
        return 2
    }
    case "$mode" in
        unit|release|ui) ;;
        *)
            usage
            return 2
            ;;
    esac

    [[ -x "$XCODEBUILD_BIN" ]] || fail "xcodebuild is unavailable: $XCODEBUILD_BIN"
    [[ -x "$LSREGISTER_BIN" ]] || fail "lsregister is unavailable: $LSREGISTER_BIN"
    [[ -x "$CLEAN_REGISTRATIONS_BIN" ]] \
        || fail "cleanup helper is unavailable: $CLEAN_REGISTRATIONS_BIN"
    trap cleanup EXIT
    make_derived_data_root
    run_xcodebuild "$mode"
}

main "$@"

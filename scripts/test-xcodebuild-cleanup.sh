#!/bin/bash

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/safemac-xcodebuild-cleanup-test.XXXXXX")"
WORK_DIR="$(cd "$WORK_DIR" && pwd -P)"
FAKE_BIN="$WORK_DIR/bin"
XCODEBUILD_LOG="$WORK_DIR/xcodebuild.log"
LSREGISTER_LOG="$WORK_DIR/lsregister.log"

cleanup() {
    rm -rf "$WORK_DIR"
}

trap cleanup EXIT

fail() {
    printf 'Test failed: %s\n' "$1" >&2
    exit 1
}

write_fake_tool() {
    local name="$1"
    local body="$2"

    {
        printf '#!/bin/bash\n'
        printf 'set -Eeuo pipefail\n'
        printf '%s\n' "$body"
    } > "$FAKE_BIN/$name"
    chmod +x "$FAKE_BIN/$name"
}

make_fake_tools() {
    mkdir -p "$FAKE_BIN"

    write_fake_tool xcodebuild '
printf "%s\n" "$@" > "${XCODEBUILD_LOG:?}"
derived_data_path=""
while (($#)); do
    if [[ "$1" == "-derivedDataPath" ]]; then
        derived_data_path="${2:-}"
        shift 2
        continue
    fi
    shift
done
[[ -n "$derived_data_path" ]] || exit 91
[[ "$derived_data_path" == "${EXPECTED_DERIVED_DATA_ROOT:?}" ]] || exit 92
products="$derived_data_path/Build/Products/Debug"
    mkdir -p \
        "$products/SafeMac AV.app" \
        "$products/SafeMac AV.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" \
        "$products/ClamAV-GUI.app" \
        "$products/ClamAV-GUI.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" \
        "$products/ClamAV-GUIUITests-Runner.app" \
        "$products/Not SafeMac AV.app" \
        "$products/SafeMac AV.app.backup"
exit "${MOCK_XCODEBUILD_STATUS:-0}"'

    write_fake_tool lsregister '
[[ "$#" -eq 2 && "$1" == "-u" ]] || exit 93
printf "%s\n" "$2" >> "${LSREGISTER_LOG:?}"
[[ "$2" != "${MOCK_LSREGISTER_FAIL_TARGET:-}" ]] || exit 94'
}

reset_logs() {
    : > "$XCODEBUILD_LOG"
    : > "$LSREGISTER_LOG"
}

run_wrapper() {
    local derived_data_root="$1"
    local xcodebuild_status="$2"

    set +e
    PATH="$FAKE_BIN:/usr/bin:/bin:/usr/sbin:/sbin" \
    XCODEBUILD_BIN="$FAKE_BIN/xcodebuild" \
    LSREGISTER_BIN="$FAKE_BIN/lsregister" \
    XCODEBUILD_LOG="$XCODEBUILD_LOG" \
    LSREGISTER_LOG="$LSREGISTER_LOG" \
    EXPECTED_DERIVED_DATA_ROOT="$derived_data_root" \
    MOCK_XCODEBUILD_STATUS="$xcodebuild_status" \
    MOCK_LSREGISTER_FAIL_TARGET="${MOCK_LSREGISTER_FAIL_TARGET:-}" \
    SAFEMAC_TEST_DERIVED_DATA_ROOT="$derived_data_root" \
        "$PROJECT_DIR/scripts/run-tests.sh" >/dev/null 2>&1
    WRAPPER_STATUS=$?
    set -e
}

assert_exact_cleanup_targets() {
    local derived_data_root="$1"
    local expected="$WORK_DIR/expected-cleanup-targets.txt"
    local actual="$WORK_DIR/actual-cleanup-targets.txt"

    printf '%s\n' \
        "$derived_data_root/Build/Products/Debug/ClamAV-GUI.app" \
        "$derived_data_root/Build/Products/Debug/ClamAV-GUI.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" \
        "$derived_data_root/Build/Products/Debug/ClamAV-GUIUITests-Runner.app" \
        "$derived_data_root/Build/Products/Debug/SafeMac AV.app" \
        "$derived_data_root/Build/Products/Debug/SafeMac AV.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" \
        | sort > "$expected"
    sort "$LSREGISTER_LOG" > "$actual"
    cmp -s "$expected" "$actual" \
        || fail "cleanup did not unregister exactly the owned SafeMac app products"
    if grep -Fq '/Applications/SafeMac AV.app' "$LSREGISTER_LOG"; then
        fail "cleanup targeted the installed SafeMac AV app"
    fi
}

test_cleanup_on_success() {
    local derived_data_root="$WORK_DIR/success-derived-data"

    reset_logs
    run_wrapper "$derived_data_root" 0
    [[ "$WRAPPER_STATUS" -eq 0 ]] || fail "wrapper changed successful xcodebuild status"
    grep -Fxq -- '-derivedDataPath' "$XCODEBUILD_LOG" \
        || fail "wrapper did not give xcodebuild a dedicated DerivedData path"
    grep -Fxq -- "$derived_data_root" "$XCODEBUILD_LOG" \
        || fail "wrapper passed the wrong DerivedData path"
    assert_exact_cleanup_targets "$derived_data_root"
}

test_cleanup_on_failure_preserves_status() {
    local derived_data_root="$WORK_DIR/failure-derived-data"

    reset_logs
    run_wrapper "$derived_data_root" 37
    [[ "$WRAPPER_STATUS" -eq 37 ]] || fail "wrapper did not preserve failed xcodebuild status"
    assert_exact_cleanup_targets "$derived_data_root"
}

assert_rejected_before_tool_invocation() {
    local derived_data_root="$1"

    reset_logs
    run_wrapper "$derived_data_root" 0
    [[ "$WRAPPER_STATUS" -ne 0 ]] || fail "unsafe DerivedData root was accepted: $derived_data_root"
    [[ ! -s "$XCODEBUILD_LOG" ]] || fail "xcodebuild ran for unsafe root: $derived_data_root"
    [[ ! -s "$LSREGISTER_LOG" ]] || fail "lsregister ran for unsafe root: $derived_data_root"
}

test_rejects_unsafe_roots() {
    assert_rejected_before_tool_invocation "/Applications"
    assert_rejected_before_tool_invocation "/"
}

test_rejects_symlink_escape() {
    local outside_root="$WORK_DIR/outside-derived-data"
    local symlink_root="$WORK_DIR/symlink-derived-data"

    mkdir -p "$outside_root"
    ln -s "$outside_root" "$symlink_root"
    assert_rejected_before_tool_invocation "$symlink_root"
}

make_cleanup_fixture() {
    local build_root="$1"
    local products="$build_root/Build/Products/Debug"

    mkdir -p \
        "$products/SafeMac AV.app" \
        "$products/SafeMac AV.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" \
        "$products/ClamAV-GUI.app" \
        "$products/ClamAV-GUI.app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" \
        "$products/ClamAV-GUIUITests-Runner.app"
}

test_helper_reports_failure_after_attempting_all_targets() {
    local build_root="$WORK_DIR/helper-failure-derived-data"
    local failed_target="$build_root/Build/Products/Debug/ClamAV-GUI.app"
    local helper_status

    make_cleanup_fixture "$build_root"
    reset_logs
    set +e
    LSREGISTER_BIN="$FAKE_BIN/lsregister" \
    LSREGISTER_LOG="$LSREGISTER_LOG" \
    MOCK_LSREGISTER_FAIL_TARGET="$failed_target" \
        "$PROJECT_DIR/scripts/clean-build-registrations.sh" "$build_root" \
        >/dev/null 2>&1
    helper_status=$?
    set -e

    [[ "$helper_status" -ne 0 ]] || fail "cleanup helper hid an lsregister failure"
    assert_exact_cleanup_targets "$build_root"
    [[ -d "$build_root" ]] || fail "cleanup helper removed its build root"
}

test_wrapper_preserves_root_and_xcodebuild_status_on_cleanup_failure() {
    local success_root="$WORK_DIR/wrapper-success-cleanup-failure-derived-data"
    local failure_root="$WORK_DIR/wrapper-failed-cleanup-failure-derived-data"
    local failed_target="$success_root/Build/Products/Debug/ClamAV-GUI.app"

    reset_logs
    MOCK_LSREGISTER_FAIL_TARGET="$failed_target" run_wrapper "$success_root" 0
    [[ "$WRAPPER_STATUS" -eq 0 ]] \
        || fail "cleanup failure replaced the successful xcodebuild status"
    [[ -d "$success_root" ]] \
        || fail "wrapper removed its root after incomplete unregister cleanup"
    assert_exact_cleanup_targets "$success_root"

    failed_target="$failure_root/Build/Products/Debug/ClamAV-GUI.app"
    reset_logs
    MOCK_LSREGISTER_FAIL_TARGET="$failed_target" run_wrapper "$failure_root" 37
    [[ "$WRAPPER_STATUS" -eq 37 ]] \
        || fail "cleanup failure replaced the original xcodebuild status"
    [[ -d "$failure_root" ]] \
        || fail "wrapper removed its root after incomplete unregister cleanup"
    assert_exact_cleanup_targets "$failure_root"
}

main() {
    [[ -x "$PROJECT_DIR/scripts/run-tests.sh" ]] \
        || fail "scripts/run-tests.sh is missing or not executable"
    make_fake_tools
    test_cleanup_on_success
    test_cleanup_on_failure_preserves_status
    test_rejects_unsafe_roots
    test_rejects_symlink_escape
    test_helper_reports_failure_after_attempting_all_targets
    test_wrapper_preserves_root_and_xcodebuild_status_on_cleanup_failure
    printf 'xcodebuild cleanup tests passed\n'
}

main "$@"

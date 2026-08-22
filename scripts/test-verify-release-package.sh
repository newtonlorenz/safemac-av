#!/bin/bash

set -Eeuo pipefail
IFS=$'\n\t'

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/safemac-release-test.XXXXXX")"

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
    } > "$WORK_DIR/bin/$name"
    chmod +x "$WORK_DIR/bin/$name"
}

make_fixture() {
    local package_dir="$WORK_DIR/package"
    local app_dir="$WORK_DIR/SafeMac AV.app"

    mkdir -p "$package_dir/appcast" "$app_dir/Contents/MacOS" "$WORK_DIR/bin"
    printf 'fake dmg\n' > "$package_dir/SafeMac-AV.dmg"
    (cd "$package_dir" && shasum -a 256 SafeMac-AV.dmg > SHA256SUMS.txt)

    cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleShortVersionString</key>
    <string>1.2.0</string>
    <key>CFBundleVersion</key>
    <string>3</string>
    <key>CFBundleExecutable</key>
    <string>ClamAV-GUI</string>
</dict>
</plist>
PLIST
    printf '#!/bin/bash\n' > "$app_dir/Contents/MacOS/ClamAV-GUI"
    chmod +x "$app_dir/Contents/MacOS/ClamAV-GUI"

    cat > "$package_dir/appcast/appcast.xml" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <item>
      <enclosure url="https://example.com/SafeMac-AV.dmg" sparkle:version="3" sparkle:shortVersionString="1.2.0" sparkle:edSignature="signed" />
    </item>
  </channel>
</rss>
XML
}

make_fake_tools() {
    write_fake_tool codesign 'exit 0'
    write_fake_tool spctl 'exit 0'
    write_fake_tool xcrun '[[ "${1:-}" == "stapler" && "${2:-}" == "validate" ]] || exit 2'
    write_fake_tool lipo 'printf "%s\n" "${LIPO_ARCHS:-x86_64 arm64}"'
}

run_success_case() {
    PATH="$WORK_DIR/bin:$PATH" \
    SAFEMAC_VERIFY_APP_PATH="$WORK_DIR/SafeMac AV.app" \
        "$PROJECT_DIR/scripts/verify-release-package.sh" "$WORK_DIR/package" >/dev/null
}

run_arch_failure_case() {
    if PATH="$WORK_DIR/bin:$PATH" \
       LIPO_ARCHS="arm64" \
       SAFEMAC_VERIFY_APP_PATH="$WORK_DIR/SafeMac AV.app" \
        "$PROJECT_DIR/scripts/verify-release-package.sh" "$WORK_DIR/package" >/dev/null 2>&1; then
        fail "missing x86_64 architecture was accepted"
    fi
}

run_appcast_failure_case() {
    perl -0pi -e 's/sparkle:version="3"/sparkle:version="4"/' "$WORK_DIR/package/appcast/appcast.xml"
    if PATH="$WORK_DIR/bin:$PATH" \
       SAFEMAC_VERIFY_APP_PATH="$WORK_DIR/SafeMac AV.app" \
        "$PROJECT_DIR/scripts/verify-release-package.sh" "$WORK_DIR/package" >/dev/null 2>&1; then
        fail "mismatched appcast version was accepted"
    fi
}

main() {
    make_fixture
    make_fake_tools
    run_success_case
    run_arch_failure_case
    run_appcast_failure_case
    printf 'verify-release-package tests passed\n'
}

main "$@"

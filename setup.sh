#!/bin/bash

set -euo pipefail

usage() {
    cat <<'USAGE'
Usage: ./setup.sh [options]

Check the local macOS development and ClamAV environment. The default action
is read-only. System changes occur only when an explicit option is supplied.

Options:
  --install-clamav       Install ClamAV with Homebrew when it is missing.
  --configure-freshclam  Copy the sample freshclam.conf when no config exists
                         and comment the sample's standalone Example line.
  --update-signatures    Run freshclam after configuration is valid.
  -h, --help             Show this help.

Examples:
  ./setup.sh
  ./setup.sh --install-clamav --configure-freshclam --update-signatures
USAGE
}

install_clamav=false
configure_freshclam=false
update_signatures=false

while (($# > 0)); do
    case "$1" in
        --install-clamav) install_clamav=true ;;
        --configure-freshclam) configure_freshclam=true ;;
        --update-signatures) update_signatures=true ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
    shift
done

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "SafeMac AV requires macOS." >&2
    exit 1
fi

if ! command -v xcodebuild >/dev/null 2>&1; then
    echo "Xcode command-line tools are missing. Install Xcode, then run this check again." >&2
    exit 1
fi

if ! command -v brew >/dev/null 2>&1; then
    echo "Homebrew is missing. Install it from https://brew.sh/ and run this check again." >&2
    exit 1
fi

brew_prefix="$(brew --prefix)"
clamav_config_dir="$brew_prefix/etc/clamav"
freshclam_sample="$clamav_config_dir/freshclam.conf.sample"
freshclam_config="$clamav_config_dir/freshclam.conf"
freshclam_binary="$brew_prefix/bin/freshclam"
clamscan_binary="$brew_prefix/bin/clamscan"

if [[ ! -x "$clamscan_binary" || ! -x "$freshclam_binary" ]]; then
    if [[ "$install_clamav" == true ]]; then
        brew install clamav
    else
        echo "ClamAV is not installed at $brew_prefix." >&2
        echo "Run 'brew install clamav' or rerun with --install-clamav." >&2
        exit 1
    fi
fi

if [[ "$configure_freshclam" == true ]]; then
    if [[ -f "$freshclam_config" ]]; then
        echo "Keeping existing configuration: $freshclam_config"
    elif [[ -f "$freshclam_sample" ]]; then
        cp "$freshclam_sample" "$freshclam_config"
        /usr/bin/sed -i '' -e 's/^[[:space:]]*Example[[:space:]]*$/#Example/' "$freshclam_config"
        echo "Created $freshclam_config"
    else
        echo "Sample configuration not found: $freshclam_sample" >&2
        exit 1
    fi
fi

if [[ ! -f "$freshclam_config" ]]; then
    echo "freshclam configuration is missing: $freshclam_config" >&2
    echo "Copy the sample and comment its standalone Example line, or use --configure-freshclam." >&2
    exit 1
fi

if /usr/bin/grep -Eq '^[[:space:]]*Example[[:space:]]*$' "$freshclam_config"; then
    echo "The standalone Example line is still active in $freshclam_config." >&2
    echo "Comment or remove it before updating signatures." >&2
    exit 1
fi

if [[ "$update_signatures" == true ]]; then
    "$freshclam_binary" --config-file="$freshclam_config"
fi

echo "Environment ready:"
echo "  Xcode: $(xcodebuild -version | /usr/bin/head -n 1)"
echo "  ClamAV: $("$clamscan_binary" --version | /usr/bin/head -n 1)"
echo "  Config: $freshclam_config"
echo "Open ClamAV-GUI.xcodeproj and run the ClamAV-GUI scheme."

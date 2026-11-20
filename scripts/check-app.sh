#!/bin/zsh
set -euo pipefail
if [[ $# -ne 1 || ! -d "$1/Contents/MacOS" ]]; then
    echo "Usage: $0 path/to/Scribe.app" >&2
    exit 1
fi
app_dir="${1:A}"
check_dir="$(mktemp -d "${TMPDIR:-/tmp}/scribe-installed-check.XXXXXX")"
trap 'rm -rf "$check_dir"' EXIT
ditto "$app_dir" "$check_dir/Scribe.app"
codesign --verify --deep --strict "$check_dir/Scribe.app"
(
    cd "$check_dir"
    # No working-directory or debug resource overrides may hide packaging mistakes.
    unset PACKAGE_RESOURCE_BUNDLE_PATH PACKAGE_RESOURCE_BUNDLE_URL
    ./Scribe.app/Contents/MacOS/Scribe --check-resources
)

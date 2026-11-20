#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

version_tag="${1:-}"
tag_pattern='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
if [[ $# -lt 1 || $# -gt 2 || ! "$version_tag" =~ $tag_pattern || ( $# -eq 2 && "$2" != --validate-only ) ]]; then
    echo "Usage: $0 vMAJOR.MINOR.PATCH [--validate-only]" >&2
    exit 1
fi
if [[ "${2:-}" == --validate-only ]]; then
    exit 0
fi
if [[ "$(uname -m)" != arm64 ]]; then
    echo "Build the Apple Silicon release on an arm64 Mac." >&2
    exit 1
fi

app_version="${version_tag#v}"
export SCRIBE_BUILD_DIR="$PWD/build/release"
./scripts/build-app.sh release "$app_version"
app_dir="$SCRIBE_BUILD_DIR/Scribe.app"
codesign --verify --deep --strict "$app_dir"

staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/scribe-dmg.XXXXXX")"
trap 'rm -rf "$staging_dir"' EXIT
ditto "$app_dir" "$staging_dir/Scribe.app"
ln -s /Applications "$staging_dir/Applications"
dmg_name="Scribe-$version_tag-arm64.dmg"
hdiutil create -volname "Scribe $app_version" -srcfolder "$staging_dir" \
    -format UDZO -ov "$PWD/build/$dmg_name"
hdiutil verify "$PWD/build/$dmg_name"
(
    cd build
    shasum -a 256 "$dmg_name" > "$dmg_name.sha256"
)
echo "Packaged build/$dmg_name and build/$dmg_name.sha256"

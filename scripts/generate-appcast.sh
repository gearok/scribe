#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

version_tag="${1:-}"
./scripts/package-dmg.sh "$version_tag" --validate-only
if [[ -z "${SPARKLE_PRIVATE_KEY:-}" ]]; then
    echo "SPARKLE_PRIVATE_KEY must contain the exported Sparkle signing key." >&2
    exit 1
fi
dmg="$PWD/build/Scribe-$version_tag-arm64.dmg"
if [[ ! -f "$dmg" ]]; then
    echo "Package the DMG before generating its appcast." >&2
    exit 1
fi

# Only the current release belongs in this feed. Older local DMGs must never be advertised.
feed_dir="$(mktemp -d "${TMPDIR:-/tmp}/scribe-appcast.XXXXXX")"
trap 'rm -rf "$feed_dir"' EXIT
cp "$dmg" "$feed_dir/"
release_url="https://github.com/gearok/scribe/releases/tag/$version_tag"
sparkle_bin="$PWD/.build/artifacts/sparkle/Sparkle/bin"
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$sparkle_bin/generate_appcast" \
    --ed-key-file - --maximum-deltas 0 \
    --download-url-prefix "https://github.com/gearok/scribe/releases/download/$version_tag/" \
    --link "$release_url" --full-release-notes-url "$release_url" "$feed_dir"
printf '%s' "$SPARKLE_PRIVATE_KEY" | "$sparkle_bin/sign_update" \
    --ed-key-file - --verify "$feed_dir/appcast.xml"
swift scripts/verify-update.swift "$feed_dir/appcast.xml" "$dmg" "$PWD/build/release/Scribe.app" "$version_tag"
cp "$feed_dir/appcast.xml" "$PWD/build/appcast.xml"
echo "Generated and verified signed build/appcast.xml"

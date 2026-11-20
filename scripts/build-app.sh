#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
configuration="${1:-debug}"
app_version="${2:-}"
version_pattern='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
if [[ -n "$app_version" && ! "$app_version" =~ $version_pattern ]]; then
    echo "Expected a numeric app version such as 1.2.3." >&2
    exit 1
fi
build_dir="${SCRIBE_BUILD_DIR:-$PWD/build}"
mkdir -p "$build_dir"
build_dir="${build_dir:A}"
sdk_version="$(xcrun --sdk macosx --show-sdk-version)"
# SwiftPM can otherwise emit the deployment target as the linked SDK version,
# which puts AppKit's automatic toolbar appearance into compatibility mode.
swift build -c "$configuration" -Xlinker -platform_version -Xlinker macos -Xlinker 15.0 -Xlinker "$sdk_version"
binary_dir="$(swift build -c "$configuration" --show-bin-path)"
app_dir="$build_dir/Scribe.app"
mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
cp "$binary_dir/Scribe" "$app_dir/Contents/MacOS/Scribe"
cp Resources/Info.plist "$app_dir/Contents/Info.plist"
if [[ -n "$app_version" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $app_version" "$app_dir/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $app_version" "$app_dir/Contents/Info.plist"
fi
for localization in Sources/Scribe/Resources/*.lproj(N); do
    mkdir -p "$app_dir/Contents/Resources/${localization:t}"
    cp "$localization/InfoPlist.strings" "$app_dir/Contents/Resources/${localization:t}/InfoPlist.strings"
done
xcrun actool Resources/Assets.xcassets --compile "$app_dir/Contents/Resources" --platform macosx \
    --minimum-deployment-target 15.0 --output-partial-info-plist "$build_dir/asset-info.plist"
swift scripts/make-icon.swift "$build_dir/Scribe.iconset"
iconutil -c icns "$build_dir/Scribe.iconset" -o "$app_dir/Contents/Resources/Scribe.icns"
for bundle in "$binary_dir"/*.bundle(N); do
    cp -R "$bundle" "$app_dir/Contents/Resources/"
done
codesign --force --sign - --entitlements Resources/Scribe.entitlements "$app_dir"
echo "Built $app_dir"

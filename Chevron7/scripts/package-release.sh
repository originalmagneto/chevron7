#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Marián Čuprík
# SPDX-License-Identifier: EUPL-1.2
# Packs the release build of Chevron7.app into a DMG and writes SHA256SUMS.txt
# next to it. A Developer ID build registers its Safari bridge agent itself
# (WebBridgeAgentService); a shell script in the DMG could not be notarized. Run build-engine.sh and
# CHEVRON7_VERSION=VERSION ../build_app.sh --release package first.
# `package` keeps the Safari extension; a plain --release build strips it.
#
# Usage: package-release.sh VERSION [OUTPUT_DIR]

set -euo pipefail

version="${1:?Usage: $0 VERSION [OUTPUT_DIR]}"
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
package_root="$(cd -- "${script_dir}/.." && pwd)"
output_dir="$(mkdir -p "${2:-${package_root}/.build/release-dist}" && cd -- "${2:-${package_root}/.build/release-dist}" && pwd)"

cd "$package_root"
app="$(swift build -c release --show-bin-path)/Chevron7.app"
[[ -d "$app" ]] || { echo "Missing $app: run build_app.sh --release package first" >&2; exit 1; }
bundled="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
[[ "$bundled" == "$version" ]] || { echo "App says $bundled, expected $version" >&2; exit 1; }
[[ -f "$app/Contents/app/autogram.jar" ]] || { echo "The app has no signing engine" >&2; exit 1; }
appex="$app/Contents/PlugIns/Chevron7WebExtension.appex"
[[ -d "$appex" ]] || { echo "Missing Safari extension in $app. Build with: ./build_app.sh --release package" >&2; exit 1; }
codesign --verify --strict "$appex"
extension_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$appex/Contents/Info.plist")"
[[ "$extension_id" == "app.slovensko.chevron7.WebExtension" ]] || { echo "Unexpected extension id: $extension_id" >&2; exit 1; }
codesign -d --entitlements - "$appex" 2>/dev/null | grep -q 'app.slovensko.chevron7.webbridge' \
    || { echo "Safari extension is missing the mach-lookup entitlement" >&2; exit 1; }

staging="$(mktemp -d "${TMPDIR:-/tmp}/chevron7-dmg.XXXXXX")"
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/Chevron7.app"
staged="$staging/Chevron7.app/Contents/PlugIns/Chevron7WebExtension.appex"
[[ -d "$staged" ]] || { echo "Staged app has no Safari extension" >&2; exit 1; }
[[ -f "$staging/Chevron7.app/Contents/Library/LaunchAgents/app.slovensko.chevron7.webbridge.plist" ]] \
    || { echo "Staged app has no bundled web bridge agent plist" >&2; exit 1; }
codesign --verify --strict "$staged"
ln -s /Applications "$staging/Applications"

dmg="$output_dir/Chevron7-v$version.dmg"
rm -f "$dmg"
# hdiutil sometimes reports "Resource busy" on hosted runners; a retry clears it.
for attempt in 1 2 3; do
    hdiutil create -quiet -volname "Chevron7 $version" -srcfolder "$staging" -fs HFS+ -format UDZO -ov "$dmg" && break
    [[ $attempt == 3 ]] && exit 1
    sleep 5
done

(cd "$output_dir" && shasum -a 256 "Chevron7-v$version.dmg" > SHA256SUMS.txt)
echo "✔ $dmg ($(du -h "$dmg" | cut -f1))"
cat "$output_dir/SHA256SUMS.txt"

#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Marián Čuprík
# SPDX-License-Identifier: EUPL-1.2
set -euo pipefail

app="${1:?Usage: $0 /path/to/Chevron7.app}"
identity="${CODE_SIGN_IDENTITY:-}"
[[ -d "$app" ]] || { echo "App not found: $app" >&2; exit 1; }
[[ -n "$identity" ]] || { echo "CODE_SIGN_IDENTITY is required" >&2; exit 2; }

sign_runtime() {
    codesign --force --timestamp --options runtime --sign "$identity" "$1"
}

# Sparkle's prebuilt framework contains nested updater code. Sparkle explicitly
# requires these components to be re-signed individually for custom release
# pipelines; do not replace this with codesign --deep.
sparkle="$app/Contents/Frameworks/Sparkle.framework"
if [[ -d "$sparkle" ]]; then
    version="$sparkle/Versions/B"
    [[ -d "$version" ]] || { echo "Unexpected Sparkle.framework layout" >&2; exit 1; }
    [[ ! -d "$version/XPCServices/Installer.xpc" ]] || sign_runtime "$version/XPCServices/Installer.xpc"
    if [[ -d "$version/XPCServices/Downloader.xpc" ]]; then
        codesign --force --timestamp --options runtime --preserve-metadata=entitlements \
            --sign "$identity" "$version/XPCServices/Downloader.xpc"
    fi
    [[ ! -e "$version/Autoupdate" ]] || sign_runtime "$version/Autoupdate"
    [[ ! -d "$version/Updater.app" ]] || sign_runtime "$version/Updater.app"
    sign_runtime "$sparkle"
fi

# Sign every other Mach-O payload, including the bundled Java runtime and native
# helpers. Bundle containers themselves are signed afterwards.
while IFS= read -r -d '' file_path; do
    case "$file_path" in
        "$sparkle"/*|"$app/Contents/PlugIns/Chevron7WebExtension.appex"/*) continue ;;
    esac
    if /usr/bin/file "$file_path" | grep -q 'Mach-O'; then
        sign_runtime "$file_path"
    fi
done < <(find "$app/Contents" -type f -print0)

appex="$app/Contents/PlugIns/Chevron7WebExtension.appex"
if [[ -d "$appex" ]]; then
    entitlements="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/Config/Chevron7WebExtension.entitlements"
    codesign --force --timestamp --options runtime --sign "$identity" \
        --entitlements "$entitlements" "$appex"
fi

codesign --force --timestamp --options runtime --sign "$identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
echo "✔ Developer ID signed: $app"

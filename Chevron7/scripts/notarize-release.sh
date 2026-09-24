#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Marián Čuprík
# SPDX-License-Identifier: EUPL-1.2
set -euo pipefail

target="${1:?Usage: $0 /path/to/Chevron7.app|Chevron7.dmg}"
: "${APPLE_API_KEY_FILE:?APPLE_API_KEY_FILE is required}"
: "${APPLE_API_KEY_ID:?APPLE_API_KEY_ID is required}"
: "${APPLE_API_ISSUER_ID:?APPLE_API_ISSUER_ID is required}"

submit() {
    xcrun notarytool submit "$1" \
        --key "$APPLE_API_KEY_FILE" \
        --key-id "$APPLE_API_KEY_ID" \
        --issuer "$APPLE_API_ISSUER_ID" \
        --wait
}

case "$target" in
    *.app)
        [[ -d "$target" ]] || { echo "App not found: $target" >&2; exit 1; }
        archive="$(mktemp "${TMPDIR:-/tmp}/chevron7-notary.XXXXXX.zip")"
        trap 'rm -f "$archive"' EXIT
        ditto -c -k --keepParent "$target" "$archive"
        submit "$archive"
        xcrun stapler staple "$target"
        xcrun stapler validate "$target"
        spctl --assess --type execute --verbose=2 "$target"
        ;;
    *.dmg)
        [[ -f "$target" ]] || { echo "DMG not found: $target" >&2; exit 1; }
        submit "$target"
        xcrun stapler staple "$target"
        xcrun stapler validate "$target"
        ;;
    *)
        echo "Unsupported notarization target: $target" >&2
        exit 2
        ;;
esac

echo "✔ Notarized and stapled: $target"

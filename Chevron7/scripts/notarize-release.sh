#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Marián Čuprík
# SPDX-License-Identifier: EUPL-1.2
# Submits a Developer ID signed Chevron7.app or DMG to Apple's notary service,
# waits for the verdict, prints the notary log when Apple refuses it, and
# staples the ticket.
#
# Credentials, either:
#   NOTARY_KEYCHAIN_PROFILE  a profile saved with `xcrun notarytool store-credentials`
#                            (local builds: Apple ID, team ID, app-specific password)
#   APPLE_API_KEY_FILE, APPLE_API_KEY_ID, APPLE_API_ISSUER_ID
#                            an App Store Connect API key (CI)
#
# Usage: notarize-release.sh /path/to/Chevron7.app|Chevron7.dmg
set -euo pipefail

target="${1:?Usage: $0 /path/to/Chevron7.app|Chevron7.dmg}"

if [[ -n "${NOTARY_KEYCHAIN_PROFILE:-}" ]]; then
    credentials=(--keychain-profile "$NOTARY_KEYCHAIN_PROFILE")
else
    : "${APPLE_API_KEY_FILE:?Set NOTARY_KEYCHAIN_PROFILE or APPLE_API_KEY_FILE}"
    : "${APPLE_API_KEY_ID:?APPLE_API_KEY_ID is required}"
    : "${APPLE_API_ISSUER_ID:?APPLE_API_ISSUER_ID is required}"
    credentials=(--key "$APPLE_API_KEY_FILE" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID")
fi

submit() {
    local result submission_id status
    result="$(xcrun notarytool submit "$1" "${credentials[@]}" --wait --output-format json)"
    submission_id="$(printf '%s' "$result" | plutil -extract id raw -o - -)"
    status="$(printf '%s' "$result" | plutil -extract status raw -o - -)"
    echo "▸ notary submission $submission_id: $status"
    if [[ "$status" != "Accepted" ]]; then
        xcrun notarytool log "$submission_id" "${credentials[@]}" >&2 || true
        exit 1
    fi
}

case "$target" in
    *.app)
        [[ -d "$target" ]] || { echo "App not found: $target" >&2; exit 1; }
        archive="$(mktemp -d "${TMPDIR:-/tmp}/chevron7-notary.XXXXXX")/Chevron7.zip"
        trap 'rm -rf "$(dirname "$archive")"' EXIT
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
        spctl --assess --type open --context context:primary-signature --verbose=2 "$target"
        ;;
    *)
        echo "Unsupported notarization target: $target" >&2
        exit 2
        ;;
esac

echo "✔ Notarized and stapled: $target"

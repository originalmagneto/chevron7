#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Marián Čuprík
# SPDX-License-Identifier: EUPL-1.2
# Writes the Sparkle appcast for a notarized release DMG: one item, signed with
# the Ed25519 key, with the release notes embedded, pointing at the versioned
# DMG of the native-vVERSION release. The app reads it from
# releases/latest/download/appcast.xml (SUFeedURL in build_app.sh).
#
# Usage: SPARKLE_PRIVATE_ED_KEY=... generate-appcast.sh VERSION DIST_DIR
set -euo pipefail

version="${1:?Usage: $0 VERSION DIST_DIR}"
dist="${2:?Usage: $0 VERSION DIST_DIR}"
: "${SPARKLE_PRIVATE_ED_KEY:?SPARKLE_PRIVATE_ED_KEY is required}"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
package_root="$(cd -- "$script_dir/.." && pwd)"
dmg="$dist/Chevron7-v$version.dmg"
[[ -f "$dmg" ]] || { echo "Missing update archive: $dmg" >&2; exit 1; }

generate_appcast="$(find "$package_root/.build/artifacts" -type f -name generate_appcast -perm -111 -print -quit 2>/dev/null || true)"
[[ -n "$generate_appcast" ]] || { echo "Sparkle generate_appcast not found under $package_root/.build/artifacts" >&2; exit 1; }

updates="$(mktemp -d "${TMPDIR:-/tmp}/chevron7-appcast.XXXXXX")"
trap 'rm -rf "$updates"' EXIT
cp "$dmg" "$updates/"
"$script_dir/release-notes.sh" "$version" > "$updates/Chevron7-v$version.md"

printf '%s' "$SPARKLE_PRIVATE_ED_KEY" | "$generate_appcast" \
    --ed-key-file - \
    --download-url-prefix "https://github.com/originalmagneto/chevron7/releases/download/native-v$version/" \
    --embed-release-notes \
    --full-release-notes-url "https://github.com/originalmagneto/chevron7/releases/tag/native-v$version" \
    --link "https://chevron7.slovensko.app" \
    -o "$dist/appcast.xml" \
    "$updates"

grep -q 'sparkle:edSignature=' "$dist/appcast.xml" || { echo "The appcast has no Ed25519 signature" >&2; exit 1; }
grep -q "Chevron7-v$version.dmg" "$dist/appcast.xml" || { echo "The appcast does not reference the release DMG" >&2; exit 1; }
echo "✔ Sparkle appcast: $dist/appcast.xml"

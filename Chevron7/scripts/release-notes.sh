#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Marián Čuprík
# SPDX-License-Identifier: EUPL-1.2
# Writes the release notes for VERSION to stdout. A hand-written
# docs/releases/vVERSION.md wins; otherwise the notes list the feat, fix and
# perf commits since the last native-v* tag and add the install section.
#
# Usage: release-notes.sh VERSION

set -euo pipefail

version="${1:?Usage: $0 VERSION}"
repo_root="$(git rev-parse --show-toplevel)"
curated="$repo_root/docs/releases/v$version.md"
if [[ -f "$curated" ]]; then
    cat "$curated"
    exit 0
fi

last_tag="$(git describe --tags --abbrev=0 --match 'native-v*' 2>/dev/null || true)"
range="HEAD"
[[ -n "$last_tag" ]] && range="$last_tag..HEAD"

section() {
    local title="$1" pattern="$2" lines
    lines="$(git log --format='%h' "$range" \
        | while read -r hash; do
            git log -1 --format=%B "$hash" | grep -q '\[skip release\]' && continue
            git log -1 --format='%s%x09%h' "$hash"
        done \
        | grep -E "$pattern" \
        | sed -E 's/^[a-z]+\(([^)]*)\)!?: (.*)\t(.*)$/- **\1:** \2 (\3)/; s/^[a-z]+!?: (.*)\t(.*)$/- \1 (\2)/' || true)"
    [[ -z "$lines" ]] && return 0
    printf '## %s\n\n%s\n\n' "$title" "$lines"
}

printf '# Chevron7 v%s\n\n' "$version"
section "Čo je nové" '^feat(\([^)]*\))?!?:'
section "Opravy" '^(fix|perf)(\([^)]*\))?!?:'
cat <<NOTES
## Požiadavky

- Apple Silicon (arm64), macOS 27 alebo novší.
- Pri podpisovaní kartou treba príslušný PKCS#11 ovládač, napríklad eID klient alebo I.CA SecureStore. Podpis mobilom vyžaduje Autogram v mobile a podporovaný NFC eID.
- Java engine a runtime sú v aplikácii, samostatnú Javu netreba.

## Inštalácia

1. Otvorte \`Chevron7-v$version.dmg\` a presuňte \`Chevron7.app\` do **Applications**.
2. Aplikácia je podpísaná Developer ID (the Software s.r.o., Q7AU96CW7H) a notarizovaná Apple. Pri prvom spustení macOS raz potvrdí otvorenie aplikácie stiahnutej z internetu.
3. Na podpisovanie zo Safari si aplikácia pri prvom spustení sama zaregistruje prepojenie (macOS ho ohlási ako položku na pozadí). Potom v Safari zapnite rozšírenie **Chevron7** v **Settings > Extensions**.

Najnovšia verzia je vždy na https://github.com/originalmagneto/chevron7/releases/latest/download/Chevron7.dmg

Kontrolné súčty sú v \`SHA256SUMS.txt\`. Web: https://chevron7.slovensko.app
NOTES

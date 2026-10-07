#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Marián Čuprík
# SPDX-License-Identifier: EUPL-1.2
# Writes the release notes for VERSION to stdout, in Slovak. A hand-written
# docs/releases/vVERSION.md wins. Otherwise the notes collect the change notes
# added since the last native-v* tag under docs/releases/changes/ (one Slovak
# paragraph per feat, fix or perf change, named feat-*.md, fix-*.md or
# perf-*.md, written in the change's own pull request), and only without any
# fall back to the commit subjects. The install section follows either way.
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

# Change notes added in the range, oldest first, still present at HEAD.
changes_dir="docs/releases/changes"
change_notes="$(git -C "$repo_root" log --reverse --diff-filter=A --format= --name-only "$range" -- "$changes_dir" \
    | grep -E '/(feat|fix|perf)-[^/]*\.md$' \
    | awk '!seen[$0]++' \
    | while read -r path; do [[ -f "$repo_root/$path" ]] && printf '%s\n' "$path"; done || true)"

notes_section() {
    local title="$1" pattern="$2" paths
    paths="$(printf '%s\n' "$change_notes" | grep -E "/($pattern)-[^/]*\.md$" || true)"
    [[ -z "$paths" ]] && return 0
    printf '## %s\n\n' "$title"
    while read -r path; do
        cat "$repo_root/$path"
        printf '\n'
    done <<< "$paths"
}

printf '# Chevron7 v%s\n\n' "$version"
if [[ -n "$change_notes" ]]; then
    notes_section "Čo je nové" 'feat'
    notes_section "Opravy" 'fix|perf'
else
    section "Čo je nové" '^feat(\([^)]*\))?!?:'
    section "Opravy" '^(fix|perf)(\([^)]*\))?!?:'
fi
cat <<NOTES
Požiadavky, inštalácia a trvalý odkaz na najnovšiu verziu: [README, časť Stiahnutie](https://github.com/originalmagneto/chevron7#stiahnutie).
NOTES

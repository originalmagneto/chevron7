#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Marián Čuprík
# SPDX-License-Identifier: EUPL-1.2
# Prints the next release version from the Conventional Commits since the last
# native-v* tag, or nothing when those commits hold no feat, fix or perf.
#
#   feat           -> minor
#   fix, perf      -> patch
#   type! or BREAKING CHANGE -> major (minor while the version is 0.x)
#
# A commit whose message contains [skip release] does not count.
# A "Release-As: X.Y.Z" footer sets the version outright (the highest one wins),
# for a milestone such as 1.0.0 that the rules above would not reach from 0.x.

set -euo pipefail

last_tag="$(git describe --tags --abbrev=0 --match 'native-v*' 2>/dev/null || true)"
last="${last_tag#native-v}"
last="${last:-0.0.0}"
IFS=. read -r major minor patch <<<"$last"

range="HEAD"
[[ -n "$last_tag" ]] && range="$last_tag..HEAD"

bump=""
release_as=""
newer() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)" == "$1" && "$1" != "$2" ]]; }
rank() { case "$1" in major) echo 3 ;; minor) echo 2 ;; patch) echo 1 ;; *) echo 0 ;; esac; }
raise() { [[ $(rank "$1") -gt $(rank "$bump") ]] && bump="$1" || true; }

while IFS= read -r -d $'\x1e' message; do
    message="${message#$'\n'}"
    [[ -z "$message" || "$message" == *"[skip release]"* ]] && continue
    subject="${message%%$'\n'*}"
    while IFS= read -r line; do
        if [[ "$line" =~ ^Release-As:\ *([0-9]+\.[0-9]+\.[0-9]+)\ *$ ]]; then
            candidate="${BASH_REMATCH[1]}"
            if [[ -z "$release_as" ]] || newer "$candidate" "$release_as"; then release_as="$candidate"; fi
        fi
    done <<<"$message"
    if [[ "$subject" =~ ^[a-z]+(\([^\)]*\))?!: || "$message" == *"BREAKING CHANGE"* ]]; then
        raise major
    elif [[ "$subject" =~ ^feat(\([^\)]*\))?: ]]; then
        raise minor
    elif [[ "$subject" =~ ^(fix|perf)(\([^\)]*\))?: ]]; then
        raise patch
    fi
done < <(git log --format='%B%x1e' "$range")

if [[ -n "$release_as" ]] && newer "$release_as" "$last"; then
    echo "$release_as"
    exit 0
fi

case "$bump" in
    major) if (( major == 0 )); then echo "0.$((minor + 1)).0"; else echo "$((major + 1)).0.0"; fi ;;
    minor) echo "$major.$((minor + 1)).0" ;;
    patch) echo "$major.$minor.$((patch + 1))" ;;
    *) ;;
esac

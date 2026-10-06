#!/bin/bash
# SPDX-FileCopyrightText: 2026 Marián Čuprík
# SPDX-FileCopyrightText: Slovensko.Digital and contributors to autogram-extension
# SPDX-License-Identifier: EUPL-1.2
#
# Reports when a state portal changes a signer script that ditec.js was written
# against, by comparing live downloads with scripts/portal-checksums.txt.
# Exit codes: 0 no drift, 1 drift, 2 a download failed.
# Ported from autogram-extension's check-portal-drift.sh.
set -u

cd "$(dirname "$0")/.."
MANIFEST="scripts/portal-checksums.txt"
STATUS=0

while read -r expected url fixture; do
    case "$expected" in ""|\#*) continue ;; esac

    # Download to a file first: hashing a piped curl would turn a failed
    # download into the hash of empty input and report it as drift.
    tmp=$(mktemp)
    if curl --fail --silent --show-error --location "$url" -o "$tmp"; then
        actual=$(shasum -a 256 "$tmp" | cut -d' ' -f1)
    else
        actual=""
    fi
    rm -f "$tmp"

    if [ -z "$actual" ]; then
        echo "ERROR: download failed: $url" >&2
        STATUS=2
        continue
    fi
    if [ "$actual" != "$expected" ]; then
        echo "DRIFT: $url"
        echo "  expected $expected"
        echo "  actual   $actual"
        if [ "$fixture" != "-" ]; then
            echo "  Run scripts/fetch-portal-fixtures.sh and node scripts/portal-contract.mjs, review the change, update the checksum."
        else
            echo "  Review the script's change against ditec.js, then update the checksum."
        fi
        [ "$STATUS" -eq 0 ] && STATUS=1
    else
        echo "ok: $url"
    fi
done < "$MANIFEST"

exit "$STATUS"

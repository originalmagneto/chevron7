#!/bin/bash
# SPDX-FileCopyrightText: 2026 Marián Čuprík
# SPDX-FileCopyrightText: Slovensko.Digital and contributors to autogram-extension
# SPDX-License-Identifier: EUPL-1.2
#
# Downloads the portal signer scripts scripts/portal-contract.mjs replays against
# ditec.js. They belong to the portal operators, so they are fetched on demand
# into Chevron7/.build/portal-fixtures and never committed.
#
# A checksum mismatch means the portal changed its signer since the contract
# scenarios were written: the file is kept (so the scenarios run against the
# live version), the drift is reported and the exit code is 1. Download
# failures exit 2. Ported from autogram-extension's fetch-portal-fixtures.sh.
set -u

cd "$(dirname "$0")/.."
MANIFEST="scripts/portal-checksums.txt"
FIXTURE_DIR=".build/portal-fixtures"
mkdir -p "$FIXTURE_DIR"
STATUS=0

while read -r expected url fixture; do
    case "$expected" in ""|\#*) continue ;; esac
    [ "$fixture" = "-" ] && continue

    target="$FIXTURE_DIR/$fixture"
    if ! curl --fail --silent --show-error --location -o "$target" "$url"; then
        echo "ERROR: download failed: $url" >&2
        STATUS=2
        continue
    fi

    actual=$(shasum -a 256 "$target" | cut -d' ' -f1)
    if [ "$actual" != "$expected" ]; then
        echo "DRIFT: $fixture differs from the version the contract scenarios were written against"
        echo "  url      $url"
        echo "  expected $expected"
        echo "  actual   $actual"
        echo "  The file was kept. Review the portal's change, update portal-contract.mjs if needed,"
        echo "  then update $MANIFEST."
        [ "$STATUS" -eq 0 ] && STATUS=1
    else
        echo "ok: $fixture"
    fi
done < "$MANIFEST"

exit "$STATUS"

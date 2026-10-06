#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Marián Čuprík
# SPDX-License-Identifier: EUPL-1.2
# Builds webbridge-probe, signs it as "webbridge-probe" and runs it with the
# given arguments (none for a status check, `--sign <file> [--attach <file>]...`
# for a signature; a `.xdcf` is sent as a finished XML Data Container).
#
# The agent and the app admit the probe only by that identifier, which the
# linker signature ("webbridge-probe-<hash>") does not carry, so a plain
# `swift run webbridge-probe` is refused. A Developer ID build of the app also
# requires the probe to be signed by the same team: the Developer ID
# Application identity in the keychain (or CODE_SIGN_IDENTITY) is used when
# present, ad hoc otherwise, which only an ad hoc build of the app accepts.
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

swift build --product webbridge-probe >/dev/null
probe="$(swift build --show-bin-path)/webbridge-probe"

identity="${CODE_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    identity="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | sort -u | head -n 1)"
fi
codesign --force --sign "${identity:--}" --identifier webbridge-probe "$probe"
echo "▸ webbridge-probe signed by: ${identity:-ad hoc}" >&2

exec "$probe" "$@"

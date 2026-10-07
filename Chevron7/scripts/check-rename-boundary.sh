#!/bin/bash
# SPDX-FileCopyrightText: 2026 Marián Čuprík
# SPDX-License-Identifier: EUPL-1.2
set -euo pipefail

# Guards the line the Chevron7 rename stops at: Autogram is a dependency and an
# ancestor, not our name. Run it without arguments after every change. With
# --strict it also fails on old product names left in product code and living
# docs, which holds only once the rename is complete. Historical specs, plans
# and findings keep their text and are not scanned.

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
package_root="$(cd -- "${script_dir}/.." && pwd)"
repo_root="$(cd -- "${package_root}/.." && pwd)"

strict=false
[[ "${1:-}" == "--strict" ]] && strict=true

failures=0
ok()   { printf '  \033[32m✔\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✘\033[0m %s\n' "$1"; failures=$((failures + 1)); }

source_file() {
    find "${package_root}/Sources" "${package_root}/WebExtension" -name "$1" -not -path '*/.build/*' -print -quit
}

must_keep() {
    local file="$1" literal="$2" label="$3"
    if [[ -z "$file" || ! -f "$file" ]]; then
        fail "${label:-source file} not found, looking for ${literal}"
    elif grep -qF -- "$literal" "$file"; then
        ok "${file#"${repo_root}/"} keeps ${literal}"
    else
        fail "${file#"${repo_root}/"} lost ${literal}"
    fi
}

echo "▸ Nothing of ours inside the upstream engine"
if [[ ! -d "${repo_root}/engine" ]]; then
    fail "engine/ not found"
elif leaks="$(grep -rIil 'chevron7' "${repo_root}/engine" --exclude-dir=target 2>/dev/null)"; then
    fail "chevron7 in engine/: ${leaks//$'\n'/, }"
else
    ok "engine/ carries no chevron7"
fi

echo "▸ Autogram names we depend on"
avm_client="$(source_file AVMClient.swift)"
must_keep "$avm_client" 'URL(string: "https://autogram.slovensko.digital/api/v1")' 'AVMClient.swift'
must_keep "$avm_client" '/qr-code?guid=' 'AVMClient.swift'
must_keep "$avm_client" 'forHTTPHeaderField: "X-Encryption-Key"' 'AVMClient.swift'
if [[ -z "$avm_client" ]]; then
    fail "AVMClient.swift not found"
elif grep -rIil 'chevron7' "$(dirname "$avm_client")" >/dev/null 2>&1; then
    fail "chevron7 in the AVM sources"
else
    ok "AVM sources carry no chevron7"
fi
must_keep "${package_root}/build_app.sh" '<string>org.autogram.asice</string>' 'build_app.sh'
must_keep "$(source_file ExternalDocumentOpen.swift)" 'UTType(importedAs: "org.autogram.asice"' 'ExternalDocumentOpen.swift'
must_keep "$(source_file ditec.js)" 'lock("isAutogram", true)' 'ditec.js'
must_keep "$(source_file FormPack.swift)" 'autogram-p2e-legacy-swift-1.0' 'FormPack.swift'
must_keep "$(source_file UserPreferences.swift)" 'digital.slovensko.autogram.timestamp-provider' 'UserPreferences.swift'
# Autogram macOS, this app before the rename, is another app now: the Finder Quick
# Action cleanup looks it up by its bundle identifier and trashes its old workflow
# only when it is gone (FinderQuickActionService.legacyAppIsInstalled).
must_keep "$(source_file ServicesProvider.swift)" 'legacyBundleIdentifier = "sk.autogram.Autogram"' 'ServicesProvider.swift'

if $strict; then
    echo "▸ No old product names left (strict)"
    scanned=(
        "${package_root}/Sources" "${package_root}/Tests" "${package_root}/scripts"
        "${package_root}/build_app.sh" "${package_root}/WebExtension" "${package_root}/Assets"
        "${package_root}/docs/EZZK-INTEGRATION.md" "${package_root}/docs/security-element-training.md"
        "${repo_root}/README.md" "${repo_root}/AGENTS.md" "${repo_root}/CLAUDE.md" "${repo_root}/.gitignore"
    )
    # A missing path would make grep exit 2, which pipefail would report instead
    # of the hits, so scan only what exists.
    existing=()
    for path in "${scanned[@]}"; do [[ -e "$path" ]] && existing+=("$path"); done
    pattern='sk\.autogram|autogram://|Autogram macOS\.app|Autogram(Kit|App|WebBridge|WebExtension)|autogram-webbridge-agent|autogram-macos-|autogramMacOS|AUTOGRAM_(CLI_HELPER|JAVA_ENGINE_ROOT|ENGINE_LIVE_TEST|DIAG_PDF|LEGACY_APP_ROOT)|Application Support/Autogram'
    # Old names kept on purpose, matched by file and exact text (never by line
    # number, which drifts), so any other old name in the same file still fails.
    # Each one is also a must_keep above.
    allowed=(
        # The old Autogram macOS bundle identifier the Finder Quick Action cleanup
        # looks for before trashing that app's workflow.
        'Sources/Chevron7App/ServicesProvider\.swift:[0-9]+:.*static let legacyBundleIdentifier = "sk\.autogram\.Autogram"$'
    )
    allowed_pattern="$(IFS='|'; printf '%s' "${allowed[*]}")"
    # grep -v exits 1 once it has filtered every hit away, which takes the ok branch.
    if hits="$(grep -rIEn --exclude-dir=.build -- "$pattern" "${existing[@]}" \
        | grep -v 'scripts/check-rename-boundary.sh' | grep -vE -- "$allowed_pattern")"; then
        fail "old names remain:"
        printf '%s\n' "$hits" | sed 's/^/      /'
    else
        ok "no old product names in product code or living docs"
    fi
fi

if (( failures > 0 )); then
    echo "✘ ${failures} boundary check(s) failed"
    exit 1
fi
echo "✔ Boundary holds"

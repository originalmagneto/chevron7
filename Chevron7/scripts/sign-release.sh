#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Marián Čuprík
# SPDX-License-Identifier: EUPL-1.2
# Signs a release build of Chevron7.app with a Developer ID Application identity
# and the hardened runtime, inside out, so that Apple's notary service accepts it.
#
# Usage: CODE_SIGN_IDENTITY="Developer ID Application: ..." sign-release.sh /path/to/Chevron7.app
# Without CODE_SIGN_IDENTITY the only Developer ID Application identity in the
# keychain search list is used.
set -euo pipefail

app="${1:?Usage: $0 /path/to/Chevron7.app}"
[[ -d "$app" ]] || { echo "App not found: $app" >&2; exit 1; }
app="$(cd -- "$app" && pwd)"
config="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/Config"

identity="${CODE_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
    identities="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application:.*\)"/\1/p' | sort -u)"
    [[ "$(printf '%s' "$identities" | grep -c .)" == 1 ]] \
        || { echo "Set CODE_SIGN_IDENTITY: found $(printf '%s' "$identities" | grep -c .) Developer ID Application identities" >&2; exit 2; }
    identity="$identities"
fi
echo "▸ identity: $identity"

sign() {
    codesign --force --timestamp --options runtime --sign "$identity" "$@"
}

is_macho() {
    /usr/bin/file -b "$1" | grep -q '^Mach-O'
}

appex="$app/Contents/PlugIns/Chevron7WebExtension.appex"
main_executable="$app/Contents/MacOS/Chevron7"

# 1. Native libraries inside JARs. The notary service opens the archives and
#    rejects any Mach-O in them without a Developer ID signature. A signed JAR
#    (META-INF/*.SF) would break when rewritten, so refuse instead of guessing.
while IFS= read -r -d '' jar; do
    entries="$(unzip -Z1 "$jar" | grep -E '\.(dylib|jnilib)$' || true)"
    [[ -n "$entries" ]] || continue
    if unzip -Z1 "$jar" | grep -qE '^META-INF/[^/]+\.(SF|RSA|DSA|EC)$'; then
        echo "Signed JAR with native code, cannot rewrite: $jar" >&2
        exit 1
    fi
    work="$(mktemp -d "${TMPDIR:-/tmp}/chevron7-jar.XXXXXX")"
    signed=0
    while IFS= read -r entry; do
        unzip -q -o "$jar" "$entry" -d "$work"
        if is_macho "$work/$entry"; then
            sign "$work/$entry" >/dev/null
            (cd "$work" && zip -q "$jar" "$entry")
            signed=$((signed + 1))
        fi
    done <<< "$entries"
    rm -rf "$work"
    echo "▸ $(basename "$jar"): $signed native libraries signed"
done < <(find "$app/Contents" -type f -name '*.jar' -print0)

# 2. Every loose Mach-O except the appex and the main executable, which their
#    bundles sign. The JVM and pkcs11-helper load card drivers signed by other
#    teams, and the JVM needs JIT, so they get their own entitlements.
while IFS= read -r -d '' file_path; do
    case "$file_path" in
        "$appex"/*|"$main_executable") continue ;;
    esac
    is_macho "$file_path" || continue
    case "$file_path" in
        "$app/Contents/runtime/bin/java")
            sign --entitlements "$config/Chevron7Java.entitlements" "$file_path" ;;
        "$app/Contents/MacOS/pkcs11-helper")
            sign --entitlements "$config/Chevron7PKCS11Helper.entitlements" "$file_path" ;;
        *)
            sign "$file_path" ;;
    esac
done < <(find "$app/Contents" -type f -print0)

# 3. The Safari extension keeps its sandbox and Mach lookup exception.
if [[ -d "$appex" ]]; then
    sign --entitlements "$config/Chevron7WebExtension.entitlements" "$appex"
fi

# 4. The app bundle last; do not use --deep, it would drop the entitlements above.
sign "$app"
codesign --verify --deep --strict --verbose=2 "$app"
echo "✔ Developer ID signed: $app"

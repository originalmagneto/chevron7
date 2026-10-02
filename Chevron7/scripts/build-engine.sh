#!/usr/bin/env bash
# SPDX-FileCopyrightText: 2026 Marián Čuprík
# SPDX-License-Identifier: EUPL-1.2
# Builds the bundled signing engine that AutogramCLI-arm64 and the Finder Quick
# Action run: the Java fork in ../engine (machine protocol v1/v2 over DSS), an
# arm64 jlink runtime, the C launcher and the Swift Quick Action runner.
#
# Output: Chevron7/.build/engine/Contents/{Helpers,app,runtime}, which
# build_app.sh bundles into Chevron7.app.
#
# Requirements: an arm64 JDK 25 that ships JavaFX jmods (Azul Zulu FX 25).
# Set AUTOGRAM_JAVA_HOME or JAVA_HOME, or install it under ~/Library/Java.

set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
package_root="$(cd -- "${script_dir}/.." && pwd)"
engine_root="$(cd -- "${package_root}/../engine" && pwd)"
output_root="${package_root}/.build/engine/Contents"
dependency_dir="${engine_root}/target/native-dependency-jars"
runtime_dir="${engine_root}/target/native-runtime"

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

resolve_java_home() {
    local candidate
    local -a candidates=()
    [[ -n "${AUTOGRAM_JAVA_HOME:-}" ]] && candidates+=("${AUTOGRAM_JAVA_HOME}")
    [[ -n "${JAVA_HOME:-}" ]] && candidates+=("${JAVA_HOME}")
    for candidate in "${HOME}"/Library/Java/zulu25*/zulu-25.jdk/Contents/Home \
                     "${HOME}"/Library/Java/zulu25*/Contents/Home \
                     "${HOME}"/Library/Java/*/Contents/Home \
                     /Library/Java/JavaVirtualMachines/*/Contents/Home; do
        [[ -d "${candidate}" ]] && candidates+=("${candidate}")
    done
    for candidate in "${candidates[@]}"; do
        [[ -x "${candidate}/bin/java" && -x "${candidate}/bin/jlink" && -d "${candidate}/jmods" ]] || continue
        "${candidate}/bin/java" -version 2>&1 | grep -q 'version "25\.' || continue
        file "${candidate}/bin/java" | grep -q 'arm64' || continue
        [[ -f "${candidate}/jmods/javafx.base.jmod" && -f "${candidate}/jmods/jdk.crypto.cryptoki.jmod" ]] || continue
        printf '%s\n' "${candidate}"
        return 0
    done
    fail "An arm64 JDK 25 with JavaFX jmods is required (Azul Zulu FX 25). Set AUTOGRAM_JAVA_HOME or unpack it under ~/Library/Java."
}

java_home="$(resolve_java_home)"
export JAVA_HOME="${java_home}"
echo "▸ engine JDK: ${java_home}"

rm -rf "${output_root}" "${dependency_dir}" "${runtime_dir}"
mkdir -p "${output_root}/Helpers" "${output_root}/app/dependency-jars" "${dependency_dir}"

echo "▸ mvnw: compile + jar + copy-dependencies"
(
    cd "${engine_root}"
    ./mvnw -q \
        -Djlink.jdk.path="${java_home}" \
        -DskipTests \
        -DincludeScope=runtime \
        -DoutputDirectory="${dependency_dir}" \
        resources:resources compiler:compile jar:jar dependency:copy-dependencies
)
jar_file="$(find "${engine_root}/target" -maxdepth 1 -name 'autogram-*.jar' ! -name '*sources*' ! -name '*javadoc*' -print -quit)"
[[ -n "${jar_file}" ]] || fail "Engine JAR was not built"
[[ -n "$(find "${dependency_dir}" -maxdepth 1 -name '*.jar' -print -quit)" ]] || fail "No runtime dependency JARs were copied"
find "${dependency_dir}" -maxdepth 1 -iname '*test*.jar' -delete

echo "▸ jlink arm64 runtime"
runtime_modules="java.compiler,java.base,java.xml,java.desktop,java.naming,java.datatransfer,java.net.http,jdk.net,java.logging,java.sql,java.scripting,javafx.base,javafx.controls,javafx.fxml,javafx.graphics,javafx.web,jdk.unsupported,jdk.httpserver,jdk.crypto.cryptoki"
"${java_home}/bin/jlink" \
    --module-path "${java_home}/jmods" \
    --add-modules "${runtime_modules}" \
    --output "${runtime_dir}" \
    --compress=2 \
    --no-header-files \
    --no-man-pages \
    --strip-debug

cp "${jar_file}" "${output_root}/app/autogram.jar"
ditto "${dependency_dir}" "${output_root}/app/dependency-jars"
ditto "${runtime_dir}" "${output_root}/runtime"

echo "▸ helpers"
clang -arch arm64 -O2 -Wall -Wextra -Werror \
    "${engine_root}/scripts/native-macos/autogram-cli-launcher.c" \
    -o "${output_root}/Helpers/AutogramCLI-arm64"
module_cache="$(mktemp -d "${TMPDIR:-/tmp}/autogram-engine-modules.XXXXXX")"
CLANG_MODULE_CACHE_PATH="${module_cache}" swiftc -parse-as-library -target arm64-apple-macosx27.0 -O \
    "${engine_root}/scripts/native-macos/autogram-quick-action-runner.swift" \
    -o "${output_root}/Helpers/AutogramQuickActionRunner-arm64"
rm -rf "${module_cache}"
chmod 755 "${output_root}/Helpers/"*

for helper in AutogramCLI-arm64 AutogramQuickActionRunner-arm64; do
    file "${output_root}/Helpers/${helper}" | grep -q 'arm64' || fail "${helper} is not arm64"
done
[[ -x "${output_root}/runtime/bin/java" ]] || fail "jlink runtime has no java executable"

echo "▸ smoke: the helper refuses a launch without --cli (GUI and its HTTP API)"
set +e
"${output_root}/Helpers/AutogramCLI-arm64" --url http://localhost:37200 >/dev/null 2>&1
gui_status=$?
set -e
[[ "${gui_status}" == 64 ]] || fail "AutogramCLI-arm64 did not refuse a non-CLI launch (status ${gui_status})"

echo "▸ smoke: CAPABILITIES over machine protocol v1"
# Machine mode SIGKILLs its own process after flushing (PKCS#11 teardown can hang),
# so the exit status is always 137; the terminal event is the success signal.
smoke_output="$(mktemp "${TMPDIR:-/tmp}/autogram-engine-smoke.XXXXXX")"
printf '{"protocolVersion":1,"requestId":"build-smoke","operation":"CAPABILITIES","payload":{}}\n' \
    | "${output_root}/Helpers/AutogramCLI-arm64" --cli --machine-readable --protocol-version 1 --operation CAPABILITIES \
    > "${smoke_output}" 2>/dev/null || true
grep -q '"session.completed"' "${smoke_output}" || { cat "${smoke_output}" >&2; rm -f "${smoke_output}"; fail "Engine CAPABILITIES smoke failed"; }
rm -f "${smoke_output}"

echo "✔ Engine: ${output_root} ($(du -sh "${output_root}" | cut -f1))"

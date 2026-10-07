# Chevron7 Streamlined (bundle size) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Status:** plan only, nothing implemented. Written 2026-10-07 on branch `chevron7-streamlined` (from `main` at `e1220374`) so the work can start in a fresh session on another Mac.

**Goal:** Shrink the shipped app from 285 MB installed (183 MB DMG, v1.3.3) to about 125 MB installed (about 110 MB DMG) by removing the JavaFX desktop UI stack and other engine parts Chevron7 never runs, without changing any signing behaviour.

**Architecture:** Chevron7 starts the forked Autogram engine only through the C launcher in machine protocol mode (`AutogramCLI-arm64 --cli --machine-readable --protocol-version 1|2`: app, browser signing, ZaKo, Finder Quick Action) and through `java -cp ... digital.slovensko.autogram.core.PdfaNormalize` (`PDFAConverter.swift`). It never runs the engine's JavaFX GUI, its HTTP server (the launcher refuses anything but `--cli`) or its human CLI. The only reason JavaFX loads at all off the GUI is one debug log line. Fix that line, then trim the jlink runtime module list and the copied dependency jars in `Chevron7/scripts/build-engine.sh`.

**Tech Stack:** Java 25 (Azul Zulu FX 25 JDK for jlink), Maven (`engine/`), bash build scripts, C launcher, Swift 6.

**Evidence:** `Chevron7/docs/research/2026-10-07-bundle-size-audit/` (`static-entrypoints.md`: every engine entry point and a module-by-module verdict with file:line; `jar-attribution.md`: all 96 jars, who pulls them, removal trials). Both were produced read-only in the session of 2026-10-07; paths there pointing at a `scratchpad/` folder are from that session and no longer exist.

## Global Constraints

- Never use em dashes in code, strings, comments or docs. Use hyphens, colons or parentheses.
- English for code, identifiers and comments; Slovak for user-facing strings and release notes.
- `CLAUDE.md` and `AGENTS.md` at the repo root stay byte-identical (`cmp CLAUDE.md AGENTS.md` silent).
- Rename boundary: nothing named Chevron7 goes into `engine/` (`Chevron7/scripts/check-rename-boundary.sh` must pass).
- No signing behaviour change: same formats, levels, timestamps, outputs. Verification compares outputs before and after (Task 6).
- Keep these runtime modules (each is proven needed): `java.base`, `java.xml`, `java.desktop` (PDFBox draws the visible PAdES stamp with AWT; pulls `java.datatransfer`, `java.prefs`), `java.naming` (`SigningKey.java:37` LdapName on every SIGN; pulls `java.security.sasl`), `java.logging`, `java.sql` (DSS/BouncyCastle references, 82 KB, cheap insurance), `jdk.net` (httpclient5 static init calls `jdk.net.Sockets`; first TSA/trusted-list request would fail without it), `jdk.unsupported` (Guava fallbacks), `jdk.crypto.cryptoki` (PKCS#11 cards).
- Keep these jars: Saxon-HE (it registers itself as the default XSLT `TransformerFactory`; removing it silently changes the engine that builds XDC/eForm output, which is signed content), DSS, BouncyCastle, PDFBox/fontbox, httpclient5 stack, JAXB, guava, gson, jna (`MacNativeFileSystem` in machine SIGN), woodstox/stax2 (service-loaded), xmlresolver(-data) (DOCTYPE inputs).
- Releases: any `feat`/`fix`/`perf` commit pushed to `main` publishes a release (`.github/workflows/release.yml`). Work on this branch, merge only after Task 6 passes on a real card.

## Measured baseline (2026-10-07, v1.3.3 / main e1220374)

| Part | Size | Note |
|---|---|---|
| `Contents/runtime` (jlink) | 169 MB | `lib/libjfxwebkit.dylib` alone 105 MB (JavaFX WebView) |
| `Contents/app/dependency-jars` (96 jars) | 85 MB | JavaFX 23.0.1 jars about 41 MB (`javafx-web` 31 MB) |
| `Contents/MacOS` | 26 MB | Swift binary 19.5 MB, `pkcs11-helper` 7.4 MB (release): not bloat |
| Other | about 5 MB | Sparkle, icon, helpers |

Class-load logs (`-Xlog:class+load`) over every card-free operation Chevron7 uses showed: zero JavaFX classes except when signing (through `Logging.log`); the 12 `javafx-*-23.0.1` jars never loaded (the runtime's JavaFX 25 modules win); veraPDF/rhino only for the human CLI `--pdfa`. A scratch engine with the trimmed runtime below, without the JavaFX and other listed jars, and with the patched `Logging.class`, passed every operation with identical outputs (only signing times and signature ids differ). Runtime 170 to 52 MB, jars 84 to 43 MB (xz estimate: 138 to 67 MB).

## File map

| File | Change |
|---|---|
| `engine/src/main/java/digital/slovensko/autogram/util/Logging.java` | drop the JavaFX call (Task 1) |
| `Chevron7/scripts/build-engine.sh` | trimmed `runtime_modules`, delete unused jars after `copy-dependencies`, size guard (Tasks 2, 3) |
| `engine/scripts/native-macos/autogram-cli-launcher.c` | `--enable-native-access=ALL-UNNAMED` (Task 4) |
| `Chevron7/Sources/Chevron7Kit/Signing/JavaEngine/JavaEngineLocator.swift` | delete dead `launchArguments` (Task 5) |
| `CLAUDE.md`, `AGENTS.md`, `docs/releases/changes/perf-mensia-aplikacia.md` | docs and release note (Task 7) |

Not touched: `engine/pom.xml` (the JavaFX and httpclient 4 Maven dependencies stay so the fork still compiles and upstream merges stay easy; its own jlink module list is upstream packaging that Chevron7 does not use).

---

### Task 1: Logging without JavaFX

**Files:**
- Modify: `engine/src/main/java/digital/slovensko/autogram/util/Logging.java:9,17`

Today `Logging.log` evaluates `Platform.isFxApplicationThread()` for every debug line; `SigningJob.signWithKeyAndRespond` (reached by `MachineSigningService.java:808` for every v1 and v2 SIGN, and by the CLI) calls it, which boots the JavaFX toolkit (`Toolkit.getToolkit()`). Without the JavaFX modules this throws `NoClassDefFoundError: javafx/application/Platform` (reproduced).

- [ ] **Step 1:** Remove `import javafx.application.Platform;` and replace the log call with:

```java
        logger.debug("{} ({}) {}", date, Thread.currentThread().getName(), message);
```

- [ ] **Step 2:** `grep -rn javafx engine/src/main/java | grep -v /ui/gui/` must list only `core/AppStarter.java` (GUI launch branch, lazily resolved) and `core/LaunchParameters.java` (GUI only). Both stay.
- [ ] **Step 3:** Build the engine (`Chevron7/scripts/build-engine.sh`) and run the engine's own tests if the session has time (`cd engine && ./mvnw -q test`); the engine smoke in `build-engine.sh` must pass.
- [ ] **Step 4:** Commit `fix(engine): log without asking JavaFX for the thread` (no user-visible change, so `[skip release]` is not needed but no release note either).

### Task 2: Trim the jlink runtime

**Files:**
- Modify: `Chevron7/scripts/build-engine.sh:73`

- [ ] **Step 1:** Replace `runtime_modules` with:

```bash
runtime_modules="java.base,java.xml,java.desktop,java.naming,java.logging,java.sql,jdk.net,jdk.unsupported,jdk.crypto.cryptoki"
```

Dropped: `javafx.base`, `javafx.controls`, `javafx.fxml`, `javafx.graphics`, `javafx.web` (with them `javafx.media`, `jdk.jsobject`, `jdk.xml.dom`, `libjfxwebkit.dylib`), `java.net.http` (only the GUI `Updater`), `java.scripting` (only `javafx.fxml` requires it), `java.compiler` (JAXB `NameConverter` edge never executed; trimmed run passed INSPECT/VALIDATE/signing), `jdk.httpserver` (only the GUI-created `AutogramServer`; also removes `bin/jwebserver`). `java.datatransfer`, `java.prefs`, `java.security.sasl`, `java.transaction.xa` come in transitively.
- [ ] **Step 2:** Keep requiring the Zulu FX JDK for now (the jmods check at `build-engine.sh:43` and the CI `setup-java` stay valid). Relaxing it to any arm64 JDK 25 with `jdk.crypto.cryptoki` is optional; if done, update the message at `build-engine.sh:11,47` and CLAUDE.md "Build the signing engine first".
- [ ] **Step 3:** Add a guard after jlink so a regression is loud:

```bash
[[ ! -e "${runtime_dir}/lib/libjfxwebkit.dylib" ]] || fail "jlink runtime still contains JavaFX WebKit"
```

- [ ] **Step 4:** Commit together with Task 3 (they must ship together, see Task 3).

### Task 3: Drop unused dependency jars

**Files:**
- Modify: `Chevron7/scripts/build-engine.sh` (next to `find "${dependency_dir}" -maxdepth 1 -iname '*test*.jar' -delete`, around line 70)

Must land in the same commit as Task 2: if the runtime loses JavaFX but the `javafx-*` jars stay on `-cp`, JavaFX silently loads from the classpath jars and extracts natives into `~/.openjfx`.

- [ ] **Step 1:** After the test-jar delete, add:

```bash
# Chevron7 never runs the engine's JavaFX GUI, its HTTP server or its human CLI
# (see docs/research/2026-10-07-bundle-size-audit). These jars serve only those.
find "${dependency_dir}" -maxdepth 1 \( \
    -name 'javafx-*.jar' \
    -o -name 'httpclient-4.*.jar' -o -name 'httpcore-4.*.jar' -o -name 'commons-codec-*.jar' \
    -o -name 'jul-to-slf4j-*.jar' \
    \) -delete
```

`commons-codec` is also referenced by xmlsec's StAX classes, which are unreachable; if Task 6 shows any `NoClassDefFoundError` for `org.apache.commons.codec`, put it back.

- [ ] **Step 2 (owner decision, default: do it):** also drop the veraPDF stack, which only the human CLI `--pdfa` reaches (machine mode passes `checkPDFACompliance=false`; no Swift caller passes `--pdfa`). 5.3 MB. Re-add if ZaKo ever validates PDF/A inside the engine.

```bash
find "${dependency_dir}" -maxdepth 1 \( \
    -name 'validation-model-*.jar' -o -name 'parser-1.*.jar' -o -name 'pdf-model-*.jar' \
    -o -name 'core-jakarta-*.jar' -o -name 'feature-reporting-*.jar' -o -name 'metadata-fixer-*.jar' \
    -o -name 'verapdf-xmp-core-*.jar' -o -name 'rhino-*.jar' -o -name 'stax-utils-*.jar' \
    -o -name 'dss-pdfa-*.jar' \
    \) -delete
```

Verify each pattern matches exactly the intended jar names first (`ls` the dependency folder; `parser-1.*` must not hit another jar). Remove `dss-pdfa` together with veraPDF: it registers service factories whose implementation jars would be gone.
- [ ] **Step 3:** Commit `perf(engine): bundle only the runtime and libraries Chevron7 runs` with the release note from Task 7 Step 3.

### Task 4: Launcher flag

**Files:**
- Modify: `engine/scripts/native-macos/autogram-cli-launcher.c:71`

- [ ] **Step 1:** `"--enable-native-access=ALL-UNNAMED,javafx.graphics"` becomes `"--enable-native-access=ALL-UNNAMED"`. Without it every engine start prints `WARNING: Unknown module: javafx.graphics specified to --enable-native-access` (seen in the trial).
- [ ] **Step 2:** Same commit as Task 2/3, or its own `fix(engine): ...` commit.

### Task 5: Dead Swift code

**Files:**
- Modify: `Chevron7/Sources/Chevron7Kit/Signing/JavaEngine/JavaEngineLocator.swift:23-25`

- [ ] **Step 1:** `grep -rn '\.launchArguments' Chevron7/Sources Chevron7/Tests` must print nothing (it did on 2026-10-07); then delete the `launchArguments` property (`-jar ... --protocol-version 2`, never called).
- [ ] **Step 2:** `swift build` and `swift test` green; commit `refactor: drop unused engine launch arguments`.

### Task 6: Verification (gate before merge)

- [ ] **Step 1: Class-load comparison.** Run the operation script in the appendix twice: against the old engine (build `main` once, or keep a copy of `.build/engine/Contents` from before Task 2) and against the new one. Expect: every operation passes in both; the new logs contain 0 classes matching `javafx\.|com\.sun\.javafx|com\.sun\.glass|com\.sun\.prism|com\.sun\.webkit`; inspection and capabilities payloads are identical (strip `emittedAt`/`sessionId`); signed outputs differ only in signing time and signature id; no `WARNING: Unknown module`.
- [ ] **Step 2: Sizes.** `du -sh .build/engine/Contents/runtime .build/engine/Contents/app/dependency-jars` should be about 52 MB and 38 to 43 MB.
- [ ] **Step 3: Suites and checks.** `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test` green; `Chevron7/scripts/check-rename-boundary.sh` passes; `cmp CLAUDE.md AGENTS.md` silent; no em dash in changed files.
- [ ] **Step 4: Real card, in the built app (these paths no card-free run covers):**
  1. Sign a PDF with a card, PAdES with a visible stamp and the qualified timestamp switch on (TSA over httpclient5, trusted lists, visible PNG stamp).
  2. Sign a PDF to ASiC-E with a card.
  3. ZaKo in Skúšobný režim end to end with the mandate card (PDF/A normalize, clause XDC with Saxon, record XDC, both signatures with timestamps).
  4. Finder Quick Action on one PDF.
  5. Browser signing on a test portal page (machine v1 sign with eForm attributes), if available.
  6. Open "Overiť znova" on a signed document (v2 VALIDATE with online lists).
  Any `NoClassDefFoundError` or "Unknown module" in the helper output stops the merge; put the named module or jar back and rerun.
- [ ] **Step 5: Release build.** `./build_app.sh --release package` and `scripts/package-release.sh` locally; compare DMG size with 183 MB (expect about 110 MB). If Developer ID signing is set up, run `scripts/sign-release.sh` too: it signs native libraries inside jars, and the removed JavaFX jars carried some.

### Task 7: Docs and release note

- [ ] **Step 1:** CLAUDE.md and AGENTS.md (identically), bullet "Signing engine": add one sentence: the jlink runtime holds only the modules the machine protocol and `PdfaNormalize` use (no JavaFX, no HTTP server), `build-engine.sh` deletes the GUI-only jars after `copy-dependencies`, and `Logging` never touches JavaFX; evidence `Chevron7/docs/research/2026-10-07-bundle-size-audit/`.
- [ ] **Step 2:** If Task 2 Step 2 relaxed the JDK requirement, update "Build the signing engine first" in both files.
- [ ] **Step 3:** `docs/releases/changes/perf-mensia-aplikacia.md`, one Slovak paragraph for the advocate (format in `docs/releases/changes/README.md`), for example: "Aplikácia je výrazne menšia: inštalácia zaberá približne 125 MB namiesto 285 MB a stiahnutie je o tretinu rýchlejšie. Podpisovanie, zaručená konverzia ani overovanie sa nemenia." Adjust the numbers to Task 6 Step 5.

## Appendix: operation script used for the measurement

Run from any folder; `C` is an engine `Contents` folder (for example `Chevron7/.build/engine/Contents`), `TAG` names the run. It needs a throwaway PKCS#12 key, created once with the engine's own keytool:

```bash
"$C/runtime/bin/keytool" -genkeypair -alias test -keyalg EC -groupname secp256r1 \
  -dname "CN=Test Podpisovatel, O=Synthetic, C=SK" -validity 30 -storetype PKCS12 \
  -keystore "$WORK/test.p12" -storepass testpass -keypass testpass
```

```bash
#!/bin/zsh
# usage: run.sh <Contents dir> <tag>   (WORK = folder of this script; logs in $WORK/logs/<tag>)
C=$1; T=$2; WORK=${0:a:h}; R=<repo>/engine/src/test/resources/digital/slovensko/autogram
L=$WORK/logs/$T; O=$WORK/out/$T; rm -rf $L $O; mkdir -p $L $O
cp $R/sample.pdf $O/plain.pdf; cp $R/general_agenda.xml $O/ga.xml
op() { local n=$1; shift
  JDK_JAVA_OPTIONS="-Xlog:class+load=info:file=$L/$n.classes" "$@" > $L/$n.out 2> $L/$n.err
  echo "$n exit=$? $(grep -o -m1 -e '"session.completed"' -e '"session.failed"' $L/$n.out)"; }
cli=$C/Helpers/AutogramCLI-arm64
m() { printf '%s\n' "$2" | op $1 $cli --cli --machine-readable --protocol-version 1 --operation $3; }
m capabilities '{"protocolVersion":1,"requestId":"r1","operation":"CAPABILITIES","payload":{}}' CAPABILITIES
m drivers '{"protocolVersion":1,"requestId":"r2","operation":"DRIVERS","payload":{}}' DRIVERS
m inspect_asice "{\"protocolVersion\":1,\"requestId\":\"r3\",\"operation\":\"INSPECT\",\"payload\":{\"files\":[{\"id\":\"f1\",\"source\":\"$R/sample_pdf_xades.asice\",\"target\":\"$O/t1.asice\"}]}}" INSPECT
m inspect_pades "{\"protocolVersion\":1,\"requestId\":\"r4\",\"operation\":\"INSPECT\",\"payload\":{\"files\":[{\"id\":\"f1\",\"source\":\"$R/sample_signed.pdf\",\"target\":\"$O/t2.pdf\"}]}}" INSPECT
m inspect_plain "{\"protocolVersion\":1,\"requestId\":\"r5\",\"operation\":\"INSPECT\",\"payload\":{\"files\":[{\"id\":\"f1\",\"source\":\"$O/plain.pdf\",\"target\":\"$O/t3.pdf\"}]}}" INSPECT
# Signing core through the engine CLI with the synthetic key (machine SIGN needs a card)
printf 'testpass\n' | op cli_sign_pdf $cli --cli --driver keystore --keystore $WORK/test.p12 --pin-stdin --key "Test Podpisovatel" --pdf-level PAdES_BASELINE_B -s $O/plain.pdf -t $O/plain_signed.pdf -f
printf 'testpass\n' | op cli_sign_xml $cli --cli --driver keystore --keystore $WORK/test.p12 --pin-stdin --key "Test Podpisovatel" -s $O/ga.xml -t $O/ga_signed.asice -f
v2req() { echo "{\"protocolVersion\":2,\"requestId\":\"$1\",\"operation\":\"$2\",\"payload\":$3}"; }
{ v2req a CAPABILITIES '{}'
  v2req b INSPECT "{\"files\":[{\"id\":\"f1\",\"source\":\"$R/sample_pdf_xades.asice\",\"target\":\"$O/v2a.asice\"},{\"id\":\"f2\",\"source\":\"$R/sample_signed.pdf\",\"target\":\"$O/v2b.pdf\"}]}"
  v2req c PREVIEW "{\"source\":\"$R/sample_pdf_xades.asice\",\"document\":\"sample.pdf\"}"
  v2req d VALIDATE "{\"files\":[{\"id\":\"f1\",\"source\":\"$R/sample_pdf_xades.asice\",\"target\":\"$O/v2c.asice\"},{\"id\":\"f2\",\"source\":\"$O/plain_signed.pdf\",\"target\":\"$O/v2d.pdf\"}]}"
} | op v2_session $cli --cli --machine-readable --protocol-version 2
op pdfa_normalize $C/runtime/bin/java -cp "$C/app/autogram.jar:$C/app/dependency-jars/*" digital.slovensko.autogram.core.PdfaNormalize $O/plain.pdf $O/plain_pdfa.pdf "/System/Library/ColorSync/Profiles/sRGB Profile.icc" Dokument
```

Machine mode SIGKILLs itself after its terminal event, so `exit=137` with `session.completed` is success. VALIDATE downloads the EU trusted lists (network). The human CLI `--pdfa` check (veraPDF) is intentionally not in the list: Chevron7 never runs it, and it fails once Task 3 Step 2 lands.

Summarise a log folder with:

```bash
cat $L/*.classes | grep -c -E ' (javafx\.|com\.sun\.javafx|com\.sun\.glass|com\.sun\.prism|com\.sun\.webkit)'
cat $L/*.classes | grep -o 'source: jrt:/[a-z.]*' | sort | uniq -c | sort -rn
cat $L/*.classes | grep -o 'source: file:[^ ]*' | sed 's#.*/##' | sort -u
```

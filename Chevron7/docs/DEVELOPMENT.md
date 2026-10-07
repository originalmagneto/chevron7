# Developing Chevron7

Building, testing and releasing Chevron7 from source. The user-facing overview is the [README](../../README.md), the detailed Slovak manual is [docs/PRIRUCKA.md](../../docs/PRIRUCKA.md). Project conventions and the full architecture notes live in [CLAUDE.md](../../CLAUDE.md) (kept identical to `AGENTS.md`).

## Requirements

| Requirement | Note |
|---|---|
| Apple Silicon Mac, macOS 27 or later | The bundled engine runtime is arm64; Foundation Models and Vision segmentation need macOS 27. |
| Xcode 27.0 (release) at `/Applications/Xcode.app`, Swift 6 | Command Line Tools alone are not enough (the SwiftUI macro plugin is missing). Do not build with a beta Xcode: a beta SDK build crashed at launch on a missing FoundationModels symbol. |
| arm64 JDK 25 with JavaFX jmods | Only for the signing engine. [Azul Zulu FX 25](https://www.azul.com/downloads/?version=java-25-lts&os=macos&architecture=arm-64-bit&package=jdk-fx) unpacked under `~/Library/Java`, or a path in `AUTOGRAM_JAVA_HOME`. Liberica 25 FX from sdkman works too, for example `AUTOGRAM_JAVA_HOME="$HOME/.sdkman/candidates/java/25.0.4.fx-librca"`. |

## Build and install

The signing engine (the Java fork of Autogram with DSS, machine protocol v1/v2 and the Finder Quick Action runner) lives in `engine/` and is built once, before the app:

```bash
cd Chevron7
scripts/build-engine.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./build_app.sh --release install
```

`build-engine.sh` builds `autogram.jar` and its dependencies with Maven, creates the jlink runtime, compiles the `AutogramCLI-arm64` launcher and the `AutogramQuickActionRunner-arm64` runner and checks the engine through `CAPABILITIES` (output `.build/engine/Contents`). `build_app.sh` bundles all of it into `Contents/{Helpers,app,runtime}`. Without the engine the app still runs, but signing falls back to Keychain or DEMO and the Finder Quick Action cannot sign. `install` puts the app at `/Applications/Chevron7.app`.

### Safari extension on a local build

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./build_app.sh --release install
./scripts/install-webbridge-agent.sh
./scripts/safari-spike.sh
```

`build_app.sh install` registers the extension and reminds you to restart Safari if it is running. Safari lists it (as **Chevron7**, with the app icon) only after the app has run at least once, because the appex is enumerated through its host app. A Developer ID build registers its Safari bridge agent itself through `SMAppService`; `install-webbridge-agent.sh` is only for ad hoc builds and re-signs them. `safari-spike.sh` checks everything that does not need Safari (the appex, its entitlement, the agent registration and the connection to the app) and then prints the three steps to do in Safari by hand. Safari loads an ad hoc build only with **Develop > Allow Unsigned Extensions**.

A signature without Safari exercises the whole app-side path:

```bash
Chevron7/scripts/webbridge-probe.sh --sign document.pdf [--attach other.pdf]...
```

The agent and the app accept only Chevron7's own components (`WebBridgeCodeRequirement`), so a plain `swift run webbridge-probe` is refused: the script signs the probe as `webbridge-probe`, with the team's Developer ID identity when the keychain has it.

## Tests

```bash
cd Chevron7
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

On some machines `SecurityElementsDetectorTests` exceeds the 60 second limit and takes the rest of the run down; `--skip SecurityElementsDetectorTests` helps. Run the engine's machine mode tests from a path without spaces, otherwise some of them do not find their resources (`%20` in the path). Tests never touch the real `~/Library/Application Support/Chevron7`, `~/Library/Caches/Chevron7` or named `UserDefaults` suites; `RealStorageGuard` fails a test that does (see CLAUDE.md).

Optional live tests:

```bash
# Java DSS engine (needs the built engine)
CHEVRON7_ENGINE_LIVE_TEST=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter JavaEngineLiveProcessTests

# On-device Foundation Model (runs when the model is available, skips otherwise)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter FoundationModelClassifierTests

# Pinned certificate of the EZZK test environment (sends only an unauthenticated GetOptions to ezzk-test.iomo.sk)
EZZK_LIVE=1 DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --filter EZZKSOAPTransportTests
```

## Command line probes

```bash
# EZZK over SOAP
swift run ezzk-probe <login|time|numbers|consume|lookup|record|receive> [number] [--env test|production] [--name N] [--ico I] [--at ISO] [--purpose original|xml] [--out FILE] [--file ASICE]

# Autogram v mobile relay, end to end (prints the QR link, opens the QR PNG, waits for the phone)
swift run avm-probe <file.pdf|file.asice> [--level PAdES_BASELINE_T] [--container ASiC-E] [--out <dir>] [--timeout <s>]

# Security element detection on an exported dataset
swift run vision-eval <dataset> [--builtin-only] [--no-fm] [--bank <dir>] [--iou 0.4] [--json] [--model <Detector.mlmodel>]
```

`ezzk-probe` takes credentials from `EZZK_LOGIN` and `EZZK_PASSWORD`, else from the Keychain item Settings saved. `numbers`, `consume` and `receive` refuse `--env production`; `record` reads one of your own records with `GetConversionRecord` and changes nothing; `receive <number> --file <asice>` sends a signed record to Test. The password and the token are never printed.

`vision-eval` prints precision, recall and F1 per kind of element, the average time per page and the number of on-device model calls. Without `--bank` it uses a fresh empty temporary bank, not the user's, so numbers stay comparable between commits. Keep datasets outside the repository and measure every detector change on real scans, not synthetic fixtures. Dataset semantics: [security-element-training.md](security-element-training.md).

## Releases

[`.github/workflows/release.yml`](../../.github/workflows/release.yml) runs on every push to `main` on the `xcode-27` runner. It derives the version from [Conventional Commits](https://www.conventionalcommits.org/) since the last `native-v*` tag (`feat` raises the minor, `fix` and `perf` the patch, `!` or `BREAKING CHANGE` the major; a `Release-As: X.Y.Z` footer sets it outright). Commits with only `docs`, `test`, `chore` or `refactor` create no release, and `[skip release]` keeps a commit out. The workflow builds the engine and the app, signs and notarizes them when the Developer ID secrets are set ([RELEASING.md](RELEASING.md)), and publishes a GitHub release with exactly two assets: `Chevron7.dmg` (the permanent link `releases/latest/download/Chevron7.dmg`, also what Sparkle downloads) and `appcast.xml`. Nothing is committed back; the app gets its version through `CHEVRON7_VERSION`, a local build takes it from the last tag.

Release notes are Slovak, written for the advocate using the app. Every `feat`, `fix` or `perf` pull request adds one paragraph under [`docs/releases/changes/`](../../docs/releases/changes/README.md); a hand-written `docs/releases/vX.Y.Z.md` wins over them. `scripts/release-notes.sh` ends every release note with a link to the README's `#stiahnutie` section, so keep that heading.

The same steps locally:

```bash
cd Chevron7
scripts/next-version.sh
CHEVRON7_VERSION=1.5.0 ./build_app.sh --release package
scripts/package-release.sh 1.5.0
```

Every release since v0.22.2 is signed with the Developer ID of the Software s.r.o. (Q7AU96CW7H) and notarized; older releases were signed ad hoc, and releases up to v0.4.0 were published as Autogram macOS.

## Architecture

| Layer | Responsibility |
|---|---|
| **Chevron7App** | SwiftUI views, menu commands, Settings, drag and drop, Finder routing and lifecycle. |
| **Session stores** | `SigningSessionStore`, `ZakoSessionStore`, `RecentDocumentStore` and `SignedDocumentStore` drive the workflows, their state and the signing history. |
| **Chevron7Kit** | PDF analysis, `LayeredDetectionProvider` (candidates, classification, learning, segmentation), XML clause, PDF/A, signing, ASiC-E and the evidence register. |
| **EngineBridge** | Persistent machine session helper for Java/DSS, PDFBox and PKCS#11. |
| **Signing/AVM, Signing/AGP** | Mobile signing through the Autogram v mobile relay (`AVMClient`, `AVMSigningSession`, `MobileSigningCoordinator`) and through eIDENTITA on the Autogram Portal (`AGPClient`, `EidentitaSigningSession`). |
| **WebBridge** | `Chevron7WebBridge` carries the contract between extension and app, `chevron7-webbridge-agent` is the launchd rendezvous owning the Mach service name, `Chevron7WebExtensionHandler` is the appex in `Contents/PlugIns` and `WebExtension/` the extension itself. |
| **EZZK** | `EZZK/SOAP/` holds all communication with the register (requests validated against the stored WSDL and XSD snapshot, response parser, transport with the pinned test certificate, password in the Keychain, adapter for ZaKo). `EZZKSubmissionCoordinator` decides every state transition of a record, `EvidenceNumberPool` remembers allocated unused numbers and `EZZKStatusChecker` sends and checks register rows every five minutes, one at a time. |
| **vision-eval, vision-train** | Standalone CLI targets for measuring and training detection; not part of the app. |

Design documents and findings:

- mobile signing: [2026-09-11-avm-mobile-signing-design.md](superpowers/specs/2026-09-11-avm-mobile-signing-design.md)
- signing on state portals: [2026-09-11-safari-extension-design.md](superpowers/specs/2026-09-11-safari-extension-design.md), background launch [2026-09-16-web-signing-background-design.md](superpowers/specs/2026-09-16-web-signing-background-design.md), findings [WEB-SIGNING-FINDINGS-2026-09-16.md](WEB-SIGNING-FINDINGS-2026-09-16.md)
- EZZK: [EZZK-INTEGRATION.md](EZZK-INTEGRATION.md), [P2E-EZZK-FINDINGS.md](P2E-EZZK-FINDINGS.md), part A [2026-09-17-ezzk-soap-design.md](superpowers/specs/2026-09-17-ezzk-soap-design.md), part B [2026-09-23-ezzk-part-b-design.md](superpowers/specs/2026-09-23-ezzk-part-b-design.md)
- layered detection: [2026-09-05-layered-security-element-detection-design.md](superpowers/specs/2026-09-05-layered-security-element-detection-design.md)
- Settings: [2026-10-06-settings-redesign-design.md](superpowers/specs/2026-10-06-settings-redesign-design.md)
- signing and notarization: [RELEASING.md](RELEASING.md)
- implementation history up to August 2026: [PHASES.md](../../docs/archive/2026-08-sessions/PHASES.md)

Diagrams (in `docs/diagrams/`): [architecture](../../docs/diagrams/architecture.svg) ([HTML](../../docs/diagrams/architecture.html)), [visual guide](../../docs/diagrams/visual-guide.html), [gallery](../../docs/gallery.html), [ZaKo process](../../docs/diagrams/process-zako.svg), [mobile signing](../../docs/diagrams/mobile-signing.svg), [AI Vision](../../docs/diagrams/ai-vision.svg), [learning](../../docs/diagrams/ai-learning.svg), [PDF/A pipeline](../../docs/diagrams/pdfa-pipeline.svg), [Finder Quick Action](../../docs/diagrams/finder-quick-action.svg), [register state machine](../../docs/diagrams/state-machine.svg).

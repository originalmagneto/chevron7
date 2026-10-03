# Session Handoff: Autogram macOS 27 UX and ZaKo Preflight

## Session goal

The session started as a complete UX and UI review of the native Autogram macOS app. The review covered the app shell, sidebar, signing journey, ZaKo journey, PDF analysis canvas, tables, settings, forms, dialogs, buttons, state feedback, accessibility, and high-stakes legal interactions.

The user then clarified the required platform direction:

- Design for macOS 27, not macOS 26.
- Use macOS 27 only as the deployment target.
- Prioritize legal preflight first.
- Then prioritize accessibility and keyboard interaction.
- Then prioritize native macOS 27 Liquid Glass and adaptive layout.
- Execute the implementation through isolated subagent-driven tasks.
- Merge the reviewed branch locally into `main`.
- Preserve unrelated uncommitted user changes.

## Starting state and review result

The app had a strong domain model but a generic interaction layer. It used `NavigationSplitView`, custom material cards, custom sticky action bars, custom Canvas gestures, and a five-step ZaKo stepper. The source and specs showed several gaps for a high-stakes legal workflow.

Initial source review score: **18/40** on Nielsen heuristics.

Main findings:

1. Authorization was not a reliable legal preflight gate.
2. CEZZK submission failure could still lead to a full success message.
3. Queue, identity, and element selection relied on `onTapGesture`.
4. Canvas markup had no keyboard or VoiceOver equivalent.
5. AI element descriptions were displayed but not editable.
6. Confidence and overdue status relied too heavily on color or tooltips.
7. Evidence table selection opened a modal immediately.
8. Empty and no-results states were missing.
9. Settings were embedded as a main sidebar route instead of a native Settings surface.
10. Fixed widths created risk at small windows and larger text sizes.
11. Signing copy advertised image input while the open panel accepted only PDF.
12. Several destructive actions had no confirmation.
13. Several file and network errors were swallowed by `try?` or not rendered near the source.

## macOS 27 clarification

The earlier plan used macOS 26 Liquid Glass assumptions. The corrected baseline is macOS 27.

The official macOS 27 SDK guidance relevant to this app is:

- Target and test against the macOS 27 SDK when macOS 27 only is intended.
- Standard SwiftUI and AppKit controls automatically receive the current system appearance.
- Reduce custom backgrounds in navigation, toolbars, controls, and content containers.
- Use `.glassEffect` and `GlassEffectContainer` sparingly for custom functional groups.
- Avoid layering multiple glass effects over ordinary content cards.
- Use split views, safe areas, and flexible sizing for arbitrary window sizes.
- Provide explicit accessibility labels and Full Keyboard Access paths.
- macOS 27 changes default menu-item image visibility. Text labels must remain sufficient without icons.
- macOS 27 adds semantic toolbar and segmented-control roles in AppKit; native controls should be preferred over custom equivalents.

There is no separate official macOS 27 color palette that justifies decorative neon effects. The correct visual direction is system-native macOS 27 hierarchy, restrained Liquid Glass, semantic color, clear content layering, and adaptive layout.

Official references:

- https://developer.apple.com/documentation/macos-release-notes/macos-27-release-notes
- https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass
- https://developer.apple.com/documentation/swiftui/applying-liquid-glass-to-custom-views
- https://developer.apple.com/design/human-interface-guidelines/toolbars
- https://developer.apple.com/design/human-interface-guidelines/sidebars
- https://developer.apple.com/design/human-interface-guidelines/buttons
- https://developer.apple.com/design/human-interface-guidelines/sheets
- https://developer.apple.com/design/human-interface-guidelines/accessibility

## User-approved implementation scope

The implementation scope was limited to three areas:

1. macOS 27 native baseline
2. truthful ZaKo legal preflight
3. accessibility, keyboard interaction, and native adaptive layout

No unrelated engine refactor was authorized.

## Implemented changes

### 1. macOS 27 native baseline

Files and behavior:

- `Autogram/Package.swift`
  - package platform floor is now `.macOS("27.0")`.

- `Autogram/build_app.sh`
  - package build uses macOS 27 deployment settings.
  - generated bundle writes `LSMinimumSystemVersion=27.0`.

- `Autogram/Sources/AutogramApp/AutogramApp.swift`
  - introduced shared `AutogramAppModel`.
  - main `WindowGroup` and native `Settings` scene share app state.
  - added macOS menu commands for Open, Add Files, Sidebar, and Settings.

- `Autogram/Sources/AutogramApp/Views/RootView.swift`
  - injects shared app state.
  - Settings is exposed as a native settings link instead of another workflow route.
  - removed custom navigation bar treatment.
  - exposed focused actions for commands.

- `Autogram/Sources/AutogramApp/Theme/DesignSystem.swift`
  - `glassCard` uses semantic material.
  - native Liquid Glass is limited to the functional markup toolbar.
  - removed custom sticky action-bar background treatment.

- `Autogram/Sources/AutogramApp/Views/AnalysisCanvasView.swift`
  - markup, detection, sheet-count, and page navigation controls are organized into native toolbar groups.
  - inspector can collapse.
  - document canvas remains the content layer.

- `Autogram/Sources/AutogramKit/MacOS27Layout.swift`
  - shared production layout constants are used by the app and contract tests.

- `Autogram/Tests/AutogramKitTests/MacOS27UXContractTests.swift`
  - verifies macOS 27 package contract, deadline constant, and production-backed layout values.

### 2. ZaKo legal preflight

Files and behavior:

- `Autogram/Sources/AutogramKit/Models/AttestationData.swift`
  - added Codable `originConfirmed` field.
  - legacy templates decode the missing field as `false`.

- `Autogram/Sources/AutogramKit/Models/AttestationPreflight.swift`
  - added pure preflight result and readiness evaluation.
  - local validation happens before server-time and cryptographic work.

- `Autogram/Sources/AutogramApp/ZakoSessionStore.swift`
  - added explicit preflight state.
  - added visible evidence-number error state.
  - added explicit authorization in-flight state.
  - automatically obtains an evidence number when the attestation flow starts.
  - protects evidence-number requests with session identity and request-token checks.
  - stale or canceled document requests cannot attach a consumed number to a new document.
  - resolves pending synthetic `engine:eid` identities before the final mandate gate.
  - permits a resolved mandate certificate.
  - blocks a resolved non-mandate certificate unless the user explicitly enables override.
  - clears origin confirmation when loading a reusable template.
  - performs local preflight before server time, PDF/A conversion, or signing.
  - prevents authorization re-entry.
  - distinguishes signed-file completion from queued CEZZK submission.

- `Autogram/Sources/AutogramApp/Views/AttestationFormView.swift`
  - added origin confirmation toggle.
  - added inline validation feedback.
  - added visible evidence-number progress, error, and retry state.
  - keeps the live clause preview.

- `Autogram/Sources/AutogramApp/Views/AuthorizeDoneViews.swift`
  - authorization checklist reflects actual preflight conditions.
  - pending synthetic card identities remain usable until certificate resolution.
  - completion state distinguishes successful CEZZK submission from queued submission.
  - queued completion exposes deadline and retry behavior.

- `Autogram/Sources/AutogramApp/Views/ZakoFlowViews.swift`
  - starts visible preflight preparation when the attestation step becomes active.
  - no longer conflicts with global signing Open shortcut after final fix.

- `Autogram/Tests/AutogramKitTests/AttestationValidatorTests.swift`
  - origin confirmation required.
  - legacy data defaults to unconfirmed.
  - invalid local preflight is rejected.
  - mandate identity passes.
  - resolved non-mandate identity is blocked.
  - reusable templates require fresh origin confirmation.

- `Autogram/Tests/AutogramKitTests/AccessibilityContractTests.swift`
  - queued and submitted evidence states have explicit text semantics.
  - confidence has a numeric label.

### 3. Accessibility and native adaptive layout

Files and behavior:

- `Autogram/Sources/AutogramApp/Views/RootView.swift`
  - queue rows are focusable selection controls with explicit accessibility state.
  - destructive queue actions use confirmation.

- `Autogram/Sources/AutogramApp/Views/AuthorizeDoneViews.swift`
  - identity rows are focusable controls with selected and unselected values.
  - mandate and qualification information remain visible.

- `Autogram/Sources/AutogramApp/Views/AnalysisCanvasView.swift`
  - element rows have independent selection and type picker focus.
  - element descriptions are editable.
  - confidence is shown numerically.
  - AI or manual provenance is visible.
  - duplicate and delete actions have text labels and confirmation.
  - selected-element inspector provides normalized position and size controls.
  - mouse dragging remains available as an accelerator.
  - page navigation and element movement have keyboard paths.

- `Autogram/Sources/AutogramApp/Views/EvidenceDashboardView.swift`
  - table selection no longer opens the detail sheet automatically.
  - detail can be opened explicitly through toolbar, Return, double-click, or context action.
  - empty register and no-results states are shown.
  - pending and overdue states have textual labels.
  - delete confirmation remains native and destructive.

- `Autogram/Sources/AutogramApp/Views/SettingsView.swift`
  - destructive actions use confirmation.
  - hidden picker controls receive explicit accessibility labels.
  - settings content uses the macOS 27 shared layout constants.

- `Autogram/Sources/AutogramKit/Models/UXLabels.swift`
  - centralizes testable confidence, evidence status, provenance, and accessibility text.

- `Autogram/Sources/AutogramKit/EngineBridge/PDF/PDFPlacementOverlayView.swift`
  - retains existing mouse placement behavior.
  - existing accessibility child labels remain.
  - full native keyboard operation for this AppKit overlay is still an open item.

- `Autogram/Sources/AutogramKit/EngineBridge/Signing/VisibleAppearanceInspector.swift`
  - icon-only and destructive controls were made more explicit and confirmation-backed.

## Problems encountered and resolutions

### Wrong source path during initial exploration

The first attempt read `Autogram/Sources/AutogramApp/RootView.swift`, but the file is under `Autogram/Sources/AutogramApp/Views/RootView.swift`. The correct source paths were then used.

### Malformed renderer edit

An early anchored edit inserted `RenderedPage.render` inside the wrong structure in `BuiltInVisionProvider.swift`, leaving duplicate `renderPixels` declarations and an invalid optional binding for `PDFPage.thumbnail`.

Resolution:

- re-read the damaged region
- restored the `RenderedPage` structure
- removed the duplicate wrapper
- used the actual non-optional `NSImage` return from `thumbnail`
- rebuilt the package

### Bitmap orientation confusion

Changing from manual PDF drawing to `PDFPage.thumbnail` changed the bitmap row orientation. The detector initially failed the expected lower-page stamp position.

Resolution:

- added a temporary diagnostic test
- printed thumbnail size and blue stamp pixel rows
- established that the CGImage-derived PixelMap rows were top-origin
- restored the normalized PDF bottom-origin mapping with `y = 1 - (minY + height) / imageHeight`
- adapted signature vertical-position confidence logic
- removed the temporary diagnostic test after the focused detector test passed

### Stale pipeline configuration

`ZakoSessionStore` cached the detection pipeline at initialization, so later AI-mode changes were not necessarily reflected in a new analysis.

Resolution:

- rebuild the pipeline from current settings inside `runAnalysis()`
- remove unused cached engine and pipeline properties

### Synthetic certificate identity regression

The first legal-preflight fix allowed `engine:eid` through the mandate preflight so users could reach PIN/BOK resolution. Review then found that the final mandate gate still ran while the identity was synthetic, allowing a possible non-mandate bypass.

Resolution:

- resolve the real certificate before the final mandate check
- replace the synthetic selection with resolved `engine-cert:` identity data
- block non-mandate certificates unless explicit override is active
- add mandate and non-mandate focused tests

### Evidence-number session race

A number request could finish after the user replaced the document and attach the consumed number to the new document.

Resolution:

- associate requests with `currentRecordID`
- add request-token and cancellation checks
- invalidate session state on reset
- ignore stale responses and stale errors

### Reusable-template legal state leak

Persisting `originConfirmed` in a reusable template could carry confirmation from document A to document B.

Resolution:

- keep the field Codable for normal state persistence
- explicitly clear it when loading a reusable template
- add regression coverage

### Nested Picker focus regression

`ElementRow` initially placed `Picker("Typ prvku")` inside the row-selection Button. That prevented reliable independent keyboard and VoiceOver focus.

Resolution:

- make the selection Button and type Picker siblings
- retain selection state, confidence, provenance, and explicit picker labels

### Global shortcut collision

After adding global macOS commands, global signing Open used `⌘O` while ZaKo intake also used `⌘O`.

Resolution:

- retain signing Open as `⌘O`
- retain Add Files as `⌘⇧O`
- move ZaKo intake to `⌘⌥O`

### macOS toolchain and SDK mismatch during smoke launch

A supervised `swift run` used CommandLineTools Swift 6.3.3 with the macOS 27 SDK built by Swift 6.4 and failed with missing `SwiftUIMacros` or SDK/compiler mismatch errors.

Resolution:

- use the repository `build_app.sh` with the configured Xcode developer directory
- build the package successfully
- launch the already-built app bundle directly for smoke testing

### Native screenshot limitation

`screencapture` failed with `could not create image from display` because the execution session has no available display. The app bundle process did remain alive during direct launch smoke verification.

### Reviewer backend failure

The `code-reviewer` backend returned a Cloud Code Assist 404 twice. The available `reviewer` agent was used instead. Task reviews and scoped re-reviews completed successfully with that fallback.

## Verification completed

Fresh verification was run after the local merge:

```bash
cd "/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/Autogram"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./build_app.sh
plutil -extract LSMinimumSystemVersion raw -o - ".build/arm64-apple-macosx/debug/Autogram.app/Contents/Info.plist"
ditto --rsrc --extattr --acl \
  ".build/arm64-apple-macosx/debug/Autogram.app" \
  "/Applications/Autogram macOS.app"
plutil -extract LSMinimumSystemVersion raw -o - "/Applications/Autogram macOS.app/Contents/Info.plist"
```

Results:

- full test suite: **107 tests executed, 0 failures**
- live engine tests: **3 skipped** because they require `AUTOGRAM_ENGINE_LIVE_TEST=1`
- packaged build: **passed**
- bundle minimum version: **27.0**
- installed debug bundle: `/Applications/Autogram macOS.app`
- installed app bundle direct launch: process stayed running during smoke verification

Existing warnings remain in unrelated or previously existing code, including:

- `PDFPlacementOverlayView.swift` public modifier inside a private extension
- deprecated `String(cString:)` usage in `EnginePaths.swift`
- unused mutability in `PDFAConverter.swift`
- redundant ignored `Void` result in `EZZKService.swift`
- forced `SecKey` cast warning
- existing CoreGraphics PDF log during a PAdES test

These warnings did not fail the suite.

## Review process and accepted commits

The feature branch was created from `main` in:

`/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/.worktrees/macos27-ux`

Reviewed implementation commits:

- `2fd06146` `feat(macOS): establish macOS 27 native app baseline`
- `c5508333` `fix(macOS): scope native glass and layout contracts`
- `1dace243` `feat(macOS): enforce truthful ZaKo preflight`
- `86cfdbc6` `fix(macOS): preserve ZaKo preflight state`
- `de84ec52` `fix(macOS): resolve pending ZaKo certificate`
- `8cfb0ec8` `Improve macOS 27 accessibility surfaces`
- `29c16cf5` `Separate element type picker accessibility focus`
- `bfc92672` `fix(macOS): avoid ZaKo shortcut collision`

The reviewed branch was merged locally into `main` as:

- `6830b276` `Merge branch 'feature/macos27-ux'`
Documentation and README updates were committed on `main` as:

- `d90a8c37` `docs: update macOS 27 UX handoff`
The final local-installation handoff update was committed on `main` as:

- `804019c1` `docs: record local macOS 27 installation`
- `24990d08` `docs: record merged branch cleanup`

After the local merge, the feature branch `feature/macos27-ux` was deleted and its worktree was removed. The active branch is `main`.

The implementation plan is:

`/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/Autogram/docs/superpowers/plans/2026-08-28-macos27-ux-preflight-accessibility.md`

## Current working tree state

The implementation branch was merged, but the following uncommitted changes were intentionally preserved as user work and must not be discarded or reset:

- `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/Autogram/Sources/AutogramApp/Views/AnalysisCanvasView.swift`
- `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/Autogram/Sources/AutogramApp/ZakoSessionStore.swift`
- `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/Autogram/Sources/AutogramKit/Analysis/PDFAnalysisEngine.swift`
- `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/Autogram/Sources/AutogramKit/Evidence/ASiCEVerifier.swift`
- `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/Autogram/Sources/AutogramKit/VisionAI/BuiltInVisionProvider.swift`
- `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/Autogram/Tests/AutogramKitTests/EvidenceAndPackagingTests.swift`
- `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/Autogram/Tests/AutogramKitTests/SecurityElementsDetectorTests.swift`

The two files specifically identified as unrelated user changes are:

- `ASiCEVerifier.swift`
- `EvidenceAndPackagingTests.swift`

The other uncommitted changes are inherited rotation, detector, and pipeline work from before the macOS 27 UX branch. They were preserved and verified by the full test suite, but were not rewritten into the reviewed UX commits.

## What remains open

1. Run the app manually on a real macOS 27 desktop with:
   - Full Keyboard Access
   - VoiceOver
   - Increase Contrast
   - Reduce Transparency
   - Reduce Motion
   - small, default, and large window sizes
2. Verify actual toolbar command routing in the active main WindowGroup.
3. Verify actual focus order and whether hidden SwiftUI Picker labels are announced correctly.
4. Add a fully keyboard-operable AppKit visible-signature placement overlay if required. The current SwiftUI inspector is the accessible movement and resize path.
5. Review whether the ZaKo stepper should stay at five stages including completion or return to the four-stage specification.
6. Replace the remaining `try?` user-visible file/export operations with actionable error UI.
7. Add explicit 20-hour warning behavior to the CEZZK evidence dashboard if it is still required by the product specification.
8. Decide whether the uncommitted inherited rotation/pipeline changes should be committed separately.
9. Update any release or distribution automation that assumes macOS 26 or an older Xcode toolchain.

## Next-session instructions

Start in:

`/Users/Magneto/PROJECTS/AUTOGRAM macOS UI`

Read this handoff first, then read:

- `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/README.md`
- `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/Autogram/docs/superpowers/plans/2026-08-28-macos27-ux-preflight-accessibility.md`
- `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/AUTOGRAM_ZAKO_MODULE_SPEC.md`
- `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/AUTOGRAM_MASTER_UI_UX_SPEC.md`
- `/Users/Magneto/PROJECTS/AUTOGRAM macOS UI/AUTOGRAM_UI_UX_CONCEPTS.md`

Do not reset the seven uncommitted files listed above. Run the full suite before touching the inherited changes. The implementation is already merged into `main`; the remaining work is runtime macOS 27 verification and any explicitly approved follow-up fixes.

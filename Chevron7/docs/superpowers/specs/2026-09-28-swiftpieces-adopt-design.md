# SwiftPieces Adoption (Adapted Patterns Only)

## Goal

Adopt at most two SwiftPieces interaction patterns as hand-ported macOS code in `Chevron7App`, without adding a dependency. No glass system rework, no resend flow change, no new package.

Context: SwiftPieces (`Saivion/SwiftPieces`, 147 stars, MIT + Commons Clause) ships single-file SwiftUI pieces (iOS 17 baseline, iOS 26 Liquid Glass with Material fallback). Every sampled piece carries UIKit-only color code in `Style.House.adaptive` (`Color(uiColor: UIColor { ... })`), including the controls recommended below. Nothing is drop-in on macOS. Value is the choreography (phase machine, hold physics, morph), not the file as-is.

## Advisor corrections applied

- `if #available(iOS 26, *)` is true on unlisted platforms (trailing `*` covers macOS). The glass branch is attempted on macOS 27, not skipped. Prior "dead path" claim withdrawn.
- Real glass blocker is UIKit: `GlassSurface.swift:138` (`Color(.secondarySystemBackground)`), `GlassSegments`, `GlassActionMenu`, `FloatingDock` (`Color(UIColor ...)`), plus iOS-only availability guards missing `macOS 26`. Finding is by source inspection, not compilation.
- `CommitButton`, `HoldToConfirm`, `StatusMorph`, `OutcomeScreen`, `SecureEntry`, `FormField` all embed `UIColor` in `House.adaptive` despite `import SwiftUI` only. Import check alone missed it. All recommendations below are patterns to adapt (color helper deleted on arrival), not drop-in controls.
- EZZK resend keeps its existing confirmation: `EvidenceDashboardView.swift:652-668` shows `actions.resendConfirmation` (code + description + `lateWarning` when the number is no longer usable, built in `EZZKRecordPresentation.resendConfirmation(for:)`) and `EZZKSubmissionCoordinator.canResend` gates eligibility. A hold gesture must not replace it; a hold can complete without reading the warning.
- Lifecycle: `SigningSessionStore.sign()` sets `isSigning = true` then `step = .done` on success, and `SigningFlowView.stepContent` (`SigningFlowViews.swift:41-47`) removes `SigningPrepareView` on `.done`. A 900ms success bloom in Prepare cannot run without changing navigation, so slice 1 drops the success hold and keeps immediate Done navigation. Phase is a read-only derivation, never a store write; upstream's delayed `self.phase = .idle` write is not copied.

## Approved behavior (slice 1 only)

Add one adapted component, `AsyncActionButton` (CommitButton pattern), for the signing primary action:

- States: `idle / loading / error(String) / disabled` as a read-only derivation at the call site: `isSigning ? .loading : (lastError != nil ? .error(lastError!) : (canSign ? .idle : .disabled))`. Loading wins over `canSign == false` (expected: `canSign` includes `!isSigning`); error wins over ineligibility so failures stay visible with or without eligibility. No `.success` at this call site: success is the immediate navigation to `SigningDoneView` (existing `EIDASBadge` summary), not a button hold.
- Idle label in Slovak via parameter (`Podpisat KEP`, `Pridat podpis` contextual rule from the 2026-08-31 nomenclature spec stays in the caller).
- Loading swaps the icon to a ring and the label to the current stage text (`statusText`, fallback title); error swaps the icon to a warning triangle, shakes once (finite keyframes, skipped under Reduce Motion), and doubles as retry (tap re-invokes the existing `sign()` which resets `lastError` and sets `isSigning`). Deliberate deviation from upstream: no collapse-to-circle or re-expansion. A full-width native `.borderedProminent` button keeps macOS layout stable (no width jump in the action bar, no truncation of Slovak stage strings like "Konvertujem do PDF/A…"). No success bloom, no timed return to idle.
- Disabled follows existing gates only (`batchCanStart`, `batchOptionsError`, provider checks, card flow). No gate logic moves into the component.
- Style: no `House` palette, no tint params. Native `.borderedProminent` + `.large` with AppKit-safe colors only (no `UIColor`, no `secondarySystemBackground`).
- Accessibility: respects Reduce Motion and Reduce Transparency, Dynamic Type, Full Keyboard Access focus ring, VoiceOver label in Slovak.

Explicitly out of slice 1: `HoldToConfirm` on any EZZK path, `StatusMorph`, `OutcomeScreen`, any `glass/*` piece, `FormField`/`SecureEntry`, `StatusTimeline` (has `import UIKit`), CLI install, SPM dependency, anything under `engine/`.

## Data flow

`SigningSessionStore` remains source of truth with zero new state. The call site computes phase from existing `isSigning`, `lastError`, `canSign` on every render. `AsyncActionButton` takes phase as a plain value (not a binding) plus the existing action closure. No store logic, no provider API, no ASiC-E parsing changes, no navigation change.

## Porting rules (apply to any future slice)

1. Copy the choreography, delete `Style.House.adaptive` and any `UIColor`/`secondarySystemBackground` site. Replace with AppKit-safe colors.
2. Widen availability guards to include `macOS 26` where Apple glass APIs are used. No new `#available(iOS ...)`-only guards.
3. Keep the SwiftPieces copyright + license notice in the copied file header. Do not relicense under EUPL-1.2. Do not place under `engine/` (rename boundary).
4. Slovak user strings via init parameters, never hardcoded English in the component.
5. Component is presentation only: no eligibility, warning text, or state machine moves out of the existing store/presenter.

## Scope

- Add: one file `Chevron7/Sources/Chevron7App/Theme/AsyncActionButton.swift` (name may adjust to existing theme naming on review) + use at one call site (`SigningPrepareView` primary action).
- Touch: that call site only. No `EvidenceDashboardView` resend path, no `DesignSystem.glassCard`, no batch planning, no card flow, no engine.
- Delete: nothing (additive slice; old button removed at the call site only if the new one covers all its states).

## Implementation plan

1. Port `CommitButton.swift` to `AsyncActionButton.swift`: strip `House`, keep loading/error choreography only (no success hold, no internal delayed idle write), AppKit-safe style defaults, Slovak-ready params, `#Preview` for idle/loading/error/disabled.
2. Wire one call site: replace the primary button in `SigningPrepareView` with the derived phase value (not a binding), preserving `⌘⏎` shortcut, disabled gates, and contextual label.
3. Verify: `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test`, `build_app.sh` bundle check, Demo signing run (unsigned + signed PDF per nomenclature spec), Reduce Motion on/off, VoiceOver label check. Tests use `makeSettingsStore()` temp root; `RealStorageGuard` must stay green.
4. Advisor re-review before slice 2 (`HoldToConfirm` for non-EZZK consequential action, or `StatusMorph` inline polling). Slice 2 needs its own gate/warning analysis first.

## Verification

- Manual proof: Demo sign navigates to Done immediately (no bloom wait); failing provider shows error + retry; disabled gates unchanged; resend dialog text byte-identical (no resend file touched; assert via unchanged diff).
- Mapping tests for the derivation (pure function, no store write): loading despite `canSign == false`; error with eligibility; error without eligibility (still error, not disabled); retry path re-invokes `sign()`. No wiring tests, no snapshot tests.
- Slice 1 completed 2026-09-28: full `swift test` green (259 AppTests, all suites pass), `swift build` + `build_app.sh` bundle green (0.14.2). Follow-up: `SigningBatchTests` 41/41 (incl. new `testSingleSignFailureRetrySuccessDrivesButtonPhases`: real `sign()` fail, retry, success with derived idle, loading, error phases and 2 provider calls), `AsyncActionButtonTests` 5/5 mapping, `EvidenceSubmissionFlowTests` + `EZZKRecordPresentationTests` 43/43 (resend gates + confirmation text unchanged). No view test added. Explicitly unperformed here (no GUI session): Demo sign of an unsigned PDF in the app, Demo sign of a signed PDF (nomenclature labels), failing-provider error + retry visual run, keyframe shake visual check, VoiceOver pass.

## Slice 2 outcome: declined, no code

Advisor lifecycle check killed the candidate with evidence: `MobileSigningCoordinator.sign()` presents the sheet then clears `isPresented` and `session` in a `defer` the moment `session.run` returns or throws, and `AVMSigningSession` sets the terminal state immediately before that return/throw. Success/failure morphs would render for zero frames unless dismissal is delayed, which is explicitly out (no terminal animation hold to make a candidate fit).

Remaining in-flight benefit was also empty: uploading/waitingForScan/downloading all map to the same loading phase, so the morph changes nothing distinguishable versus the current spinner + Slovak captions. The persistent surfaces (Register rows, Done views with `EIDASBadge`) do not need terminal choreography either: rows redraw on polls (replaying animations would lie about fresh activity) and Done screens already summarize the legal result.

`HoldToConfirm` stays rejected per the proposal (deletion and authorize both carry confirmations a hold would weaken). Adoption closes at slice 1: no second component, no new file.

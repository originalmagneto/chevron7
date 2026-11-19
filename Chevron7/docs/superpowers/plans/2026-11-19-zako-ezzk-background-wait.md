# ZaKo: EZZK wait in the background - Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After a record-first authorization the advocate goes back to work at once; a background watcher polls EZZK, notifies on processed or rejected, and the advocate finishes the clause signature from ZaKo with their own confirmation.

**Architecture:** `RecordFirstPending` becomes `Codable` and is persisted per record by `RecordFirstPendingStore` (`Evidence/pending/<id>.plist`), owned by `AppSettingsStore`. `ZakoSessionStore` keeps only the attached pending id and reads the pending value from that store. `RecordFirstWatcher` (beside `EZZKStatusChecker`) polls awaiting conversions through the checker's `submit(id:)`/`verify(id:)` and reports through a `RecordFirstNotifying` seam (`UNUserNotificationCenter` in the app).

**Tech Stack:** Swift 6, SwiftUI, Observation, UserNotifications, XCTest.

**Spec:** `docs/superpowers/specs/2026-11-19-zako-ezzk-background-wait-design.md`

## Global Constraints

- User-facing strings in Slovak, code and comments in English, never an em dash anywhere.
- No automatic client signature after EZZK processed the record outside the authorization the advocate is holding (owner, 2026-11-19).
- Tests never touch real Application Support, Caches, UserDefaults or Keychain: `makeSettingsStore()`, `MemoryUserDefaults`, `MemoryCredentialStore`.
- Never switch to Ostrá evidencia; no production policy changes.
- Poll schedule: every 30 s until 30 minutes after `recordSignedAt`, then every 120 s until 24 hours; after that the hourly `EZZKStatusChecker` takes over.
- The watcher runs only where `EZZKStatusChecker.shouldRun(launchMode:isRegularApp:)` allows it.
- `CLAUDE.md` and `AGENTS.md` stay identical.

## Review Focus

- A pending file that cannot be decoded (older format, truncated): it is skipped and logged, never crashes launch, never deletes the register row. Test in Task 1.
- The register row deleted while a conversion waits: the watcher drops the pending file at its next pass and posts nothing. Test in Task 2.
- EZZK mode switched while a conversion waits: lookups go on in the row's mode; a refused `submit` (other mode) is retried later, no notification. Test in Task 2.
- A new document in ZaKo while a conversion waits: the pending conversion stays on disk and keeps being watched. Test in Task 3.
- Opening a pending conversion while ZaKo holds other unfinished work asks first; while ZaKo is authorizing it refuses. Test in Task 3.

---

### Task 1: Persisted pending conversions

**Files:**
- Modify: `Sources/Chevron7Kit/Signing/AppendedClause.swift` (add `Codable`)
- Modify: `Sources/Chevron7Kit/Evidence/ASiCEPackager.swift` (`Entry: Codable`)
- Modify: `Sources/Chevron7App/ZakoRecordFirstFlow.swift` (`RecordFirstPending: Codable, Equatable`, `Stage: Codable`, new `let recordSignedAt: Date`)
- Create: `Sources/Chevron7App/RecordFirstPendingStore.swift`
- Modify: `Sources/Chevron7App/AppSettingsStore.swift` (`let recordFirstPendingStore: RecordFirstPendingStore`, directory `storageRoot/Evidence/pending`)
- Test: `Tests/Chevron7AppTests/RecordFirstPendingStoreTests.swift`

**Interfaces:**
- Produces:
  - `@MainActor @Observable final class RecordFirstPendingStore { init(directory: URL); private(set) var all: [RecordFirstPending] /* sorted by recordSignedAt */; func pending(id: UUID) -> RecordFirstPending?; func save(_ pending: RecordFirstPending) throws; func remove(id: UUID); func reload() }`
  - `RecordFirstPending.recordSignedAt: Date` (set in `startRecordFirst` right after the record signature).
  - Files are binary property lists (`PropertyListEncoder`, `.binary`), written `.atomic`, named `<recordID>.plist`.

- [ ] **Step 1: Write failing tests** `testSavedPendingSurvivesReload` (save, new store on same directory, `pending(id:)` equals the saved value including `finalPDF`, `containerFiles`, `appendedClause`, `attestation`), `testRemoveDeletesFile`, `testUndecodableFileIsSkipped` (write garbage `<uuid>.plist`; `all` is empty, file left in place), `testAllIsSortedBySignedTime`.
- [ ] **Step 2: Run** `swift test --filter RecordFirstPendingStoreTests`; expect compile failure.
- [ ] **Step 3: Implement** the conformances and the store; undecodable files are logged under the `EZZK` logger category, not deleted.
- [ ] **Step 4: Run** the filter again; PASS. Existing record-first tests still compile (add `recordSignedAt` where `RecordFirstPending` is built).
- [ ] **Step 5: Commit** `feat(zako): persist record-first conversions waiting for EZZK`.

### Task 2: Background watcher

**Files:**
- Create: `Sources/Chevron7App/EZZK/RecordFirstWatcher.swift`
- Test: `Tests/Chevron7AppTests/RecordFirstWatcherTests.swift`

**Interfaces:**
- Consumes: `RecordFirstPendingStore` (Task 1), `EZZKStatusChecker.RowResult`, `LocalEvidenceStore.record(id:)`.
- Produces:
  - `@MainActor protocol RecordFirstNotifying: AnyObject { func requestAuthorizationIfNeeded(); func recordProcessed(_ pending: RecordFirstPending); func recordRejected(_ pending: RecordFirstPending, code: Int?, description: String?) }`
  - `@MainActor @Observable final class RecordFirstWatcher { init(pendingStore:, evidenceStore:, submit: @escaping (UUID) async -> EZZKStatusChecker.RowResult, verify: @escaping (UUID) async -> EZZKStatusChecker.RowResult, notifier: RecordFirstNotifying, now: @escaping () -> Date = Date.init); static func checkInterval(signedAt: Date, now: Date) -> TimeInterval? /* 30, 120, nil after 24 h */; func runOnce() async; func start(); func stop(); var isRunning: Bool }`
  - `start()` loops `runOnce()` then sleeps 10 s; `runOnce()` acts only on `.awaitingEZZK` pendings whose interval has passed since their last check (kept in memory per id; first check is due at once).
  - Per pending: row missing → `remove(id:)`, no notification. `.signed/.queuedForSubmission/.submissionFailed/.late` → `submit`. `.acceptedForProcessing/.outcomeUnknown` → `verify`. Then read the row again: `.processed` → save with stage `.signingClientContainer`, `recordProcessed`. `.rejected` or `.recordUnsigned` → `recordRejected(code: row.ezzkResultCode, description: row.ezzkResultDescription)`, `remove(id:)`. Any `.refused` result → nothing, retried next interval.
  - The app wires `submit`/`verify` to `settingsStore.statusChecker.submit(id:)`/`verify(id:)`.

- [ ] **Step 1: Write failing tests:** `testIntervalSchedule` (`checkInterval` at 0 s → 30, at 29 min → 30, at 31 min → 120, at 23 h → 120, at 25 h → nil); `testProcessedMovesStageAndNotifiesOnce` (two passes, one `recordProcessed`); `testRejectedNotifiesWithCodeAndDropsPending` (code 12, "Neznámy obsah"); `testSignedRowIsSubmittedFirst`; `testMissingRowDropsPendingSilently`; `testRefusedSubmitIsRetriedWithoutNotification`; `testNotDueAgainBeforeInterval` (fixed `now`, second `runOnce` makes no call); `testReadyPendingIsNotPolled`.
- [ ] **Step 2: Run** `swift test --filter RecordFirstWatcherTests`; FAIL.
- [ ] **Step 3: Implement** the watcher.
- [ ] **Step 4: Run** the filter; PASS.
- [ ] **Step 5: Commit** `feat(zako): watch record-first conversions in the background`.

### Task 3: ZaKo hands the wait over and loads a pending conversion

**Files:**
- Modify: `Sources/Chevron7App/ZakoRecordFirstFlow.swift`, `Sources/Chevron7App/ZakoSessionStore.swift`, `Sources/Chevron7App/ZakoMandateCardFlow.swift` (only if it reads the removed members)
- Modify tests: `Tests/Chevron7AppTests/ZakoRecordFirstFlowTests.swift`, `Tests/Chevron7AppTests/ZakoE2ERecordFirstTests.swift`

**Interfaces:**
- Consumes: Task 1 store (`settingsStore.recordFirstPendingStore`), Task 2 `RecordFirstNotifying` (optional `recordFirstNotifier` on the session store, called with `requestAuthorizationIfNeeded()` on hand-over).
- Produces:
  - `recordFirstPending: RecordFirstPending?` becomes computed over `attachedPendingID: UUID?` and the pending store (get reads the store; no setter). Mutations: `attachRecordFirstPending(_:) throws` (save + attach), `detachRecordFirstPending()` (forget the id, file stays), `discardRecordFirstPending()` (remove file + detach).
  - `var isLoadedPendingConversion: Bool` (true after `openPendingConversion`).
  - `var awaitsEZZKInBackground: Bool` (attached pending in `.awaitingEZZK` and `step == .done`).
  - `enum PendingOpenResult: Equatable { case opened, needsDiscardConfirmation, busy, missing }`; `func openPendingConversion(id: UUID, discardingCurrentWork: Bool = false) -> PendingOpenResult`. `.busy` while `isAuthorizing || isResolvingCertificate`; `.needsDiscardConfirmation` when not discarding and `step` is past intake and before `.done`; `.opened` resets the session (`reset` path, which now detaches), sets `attestation = pending.attestation`, `direction = pending.direction`, `currentRecordID = pending.recordID`, attaches, sets `isLoadedPendingConversion`, `step = .authorize`.
  - `static let recordFirstSentInBackgroundMessage` (Slovak, says the record is sent, Chevron7 checks EZZK in the background and will notify; finish then with "Dokončiť konverziu").
  - Removed: `isWaitingForEZZK`, `stopWaitingRequested`, `stopWaitingForEZZK()`, `recordFirstWaitLimit`, `recordFirstPollInterval`, `recordFirstWaitStoppedMessage`, `recordFirstTimedOutMessage`. `recordFirstLookup` stays as the test seam.
- Behaviour:
  - `continueRecordFirst` at `.awaitingEZZK`: submit when sendable (as today), then one lookup (`recordFirstLookup ?? statusChecker.verify`). `.processed` → stage `.signingClientContainer` (saved) and the client signature follows in the same authorization. `.rejected`/`.recordUnsigned`/missing row → today's messages, `discardRecordFirstPending()` plus `startNewRecordAttempt()`. Otherwise → `step = .done`, `lastError = nil`, notifier asked for permission; nothing is signed.
  - `signClientContainer` success → `discardRecordFirstPending()`.
  - `resumeRecordFirst`: mode check always; original and form checks only when `!isLoadedPendingConversion`.
  - `reset` (new document) → `detachRecordFirstPending()`, `isLoadedPendingConversion = false`; `startNewRecordAttempt` → `discardRecordFirstPending()`.

- [ ] **Step 1: Rewrite/add tests.** Replace `testTimedOutWaitResumesWithoutSigningTheRecordAgain` and `testStoppedWaitKeepsTheSentRecordForLater` with `testUnprocessedRecordGoesToTheBackground` (lookup keeps `.acceptedForProcessing`: `step == .done`, `awaitsEZZKInBackground`, pending file exists with stage `.awaitingEZZK`, `provider.kinds == [.record]`, `lastError == nil`) and `testLoadedPendingFinishesWithoutSecondRecord` (then mark the row processed and the pending stage ready, `store.reset…`/new document, `openPendingConversion(id:)` → `.opened`, `authorizeAndSign()` → `.done`, kinds `[.record, .client]`, one submitted record, same number, pending file gone). Adjust `testE2EResumeAtWaitAndAtClientSignature` the same way (E→E loaded conversion finishes with `electronicOriginal == nil`). Add `testNewDocumentKeepsThePendingConversionOnDisk` (replaces `testNewDocumentDropsThePendingConversion`), `testOpenPendingAsksBeforeDiscardingWork`, `testOpenPendingRefusedWhileAuthorizing`, `testRejectedOnFirstCheckRemovesPendingFile`. Demo tests that expect `.done` with both signatures keep passing (Demo lookup answers processed).
- [ ] **Step 2: Run** `swift test --filter 'ZakoRecordFirstFlowTests|ZakoE2ERecordFirstTests'`; FAIL.
- [ ] **Step 3: Implement** the behaviour above.
- [ ] **Step 4: Run** the filter; PASS.
- [ ] **Step 5: Commit** `feat(zako): hand the EZZK wait to the background and finish from a stored conversion`.

### Task 4: Notifications, app wiring, presentation and views

**Files:**
- Create: `Sources/Chevron7App/EZZK/RecordFirstNotifier.swift` (`UNUserNotificationCenter`, delegate shows banners while active; category id `record-first`, `userInfo["recordID"]`)
- Create: `Sources/Chevron7App/RecordFirstPendingPresentation.swift`
- Modify: `Sources/Chevron7App/Chevron7App.swift` (watcher on the app model, started with the checker under the same rule, also in `onBecomeRegular`; `requestedPendingConversion: UUID?` on the model, set by a notification click, the sidebar and the Register)
- Modify: `Sources/Chevron7App/SidebarConversionRows.swift`, `Sources/Chevron7App/Views/RootView.swift`, `Sources/Chevron7App/Views/EvidenceDashboardView.swift`, `Sources/Chevron7App/Views/AuthorizeDoneViews.swift`
- Test: `Tests/Chevron7AppTests/RecordFirstPendingPresentationTests.swift`, existing sidebar tests

**Interfaces:**
- Consumes: Tasks 1 to 3.
- Produces:
  - `enum RecordFirstPendingPresentation { static func label(for: RecordFirstPending.Stage) -> String /* "Čaká na EZZK", "Čaká na podpis doložky" */; static func symbol(for:) -> String /* "hourglass", "signature" */; static func tone(for:) -> EZZKRecordPresentation.Tone; static func processedNotification(_:) -> (title: String, body: String); static func rejectedNotification(_:code:description:) -> (title: String, body: String) }` (texts name the evidence number and the document name).
  - `SidebarConversionRows.section(from:limit:now:pendingStages: [UUID: RecordFirstPending.Stage] = [:])` and `row(for:now:pendingStage:)`: a pending stage overrides label, symbol and tone; the row's `accessibilityLabel` carries it.
- Views:
  - Sidebar row with a pending stage: tap sets `requestedPendingConversion` (other rows keep opening the Register).
  - Register: list state and detail show the pending label; detail of a ready conversion has "Dokončiť konverziu" setting `requestedPendingConversion`; deleting a row also calls `recordFirstPendingStore.remove(id:)`.
  - RootView observes `requestedPendingConversion`: switches to ZaKo, calls `openPendingConversion`; `.needsDiscardConfirmation` raises a confirmation ("Zahodiť rozpracovanú konverziu?"), `.busy` and `.missing` show an alert.
  - DoneView: when `awaitsEZZKInBackground`, a card "Záznam č. X je odoslaný do EZZK" with `recordFirstSentInBackgroundMessage` and "Nová konverzia" instead of the folder card.
  - AuthorizeView: "Zastaviť čakanie" removed; "Späť na doložku" hidden when `isLoadedPendingConversion`; hint for a loaded conversion says it signs the stored clause and document.

- [ ] **Step 1: Write failing tests** for `RecordFirstPendingPresentation` (labels, symbols, notification texts contain the number, no em dash) and `testPendingStageOverridesSidebarState`.
- [ ] **Step 2: Run** the filters; FAIL.
- [ ] **Step 3: Implement** presentation, notifier, wiring and views.
- [ ] **Step 4: Run** the filters; PASS. `swift build` clean.
- [ ] **Step 5: Commit** `feat(zako): notify when EZZK processed a record and finish it from the sidebar or the Register`.

### Task 5: Docs and full verification

**Files:**
- Modify: `../CLAUDE.md` and `../AGENTS.md` (repo root; the record-first bullet: the background wait, the store, the watcher schedule, notifications, finishing), identical afterwards (`cmp`).
- Create: `docs/releases/changes/feat-zako-ezzk-background-wait.md` (one Slovak paragraph for the advocate).

- [ ] **Step 1:** Update docs and the change note; a search for the em dash character (U+2014) over changed files finds nothing.
- [ ] **Step 2:** `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" swift test` (background, full suite) PASS.
- [ ] **Step 3:** `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer" ./build_app.sh` succeeds.
- [ ] **Step 4: Commit** `docs: EZZK wait in the background`.

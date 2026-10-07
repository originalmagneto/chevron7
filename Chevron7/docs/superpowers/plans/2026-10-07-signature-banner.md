# Signature Banner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a document's existing signatures as one status banner above the document, expandable inline, in signing (prepare and done), the Safari signing panel and ZaKo authorization.

**Architecture:** A pure `SignatureBannerModel` turns either a `SignatureTreeState` (signing, Safari) or an `InputSignatureInspectionResult` (ZaKo) into tone, headline, rows and a note; one SwiftUI `SignatureBanner` renders it everywhere. The structural-then-validation pipeline moves out of `SigningSessionStore` into a reusable `SignatureTreeLoader`, which the Safari panel also uses through `WebSigningSignatureCheck`.

**Tech Stack:** Swift 6, SwiftUI (macOS 27), Observation, XCTest; Chevron7App and Chevron7Kit targets.

**Spec:** `Chevron7/docs/superpowers/specs/2026-10-07-signature-banner-design.md`

## Global Constraints

- Never use em dashes in code, strings, comments or docs. Use hyphens, colons or parentheses.
- English for code, identifiers and comments; Slovak for every user-facing string.
- `CLAUDE.md` and `AGENTS.md` at the repo root stay byte-identical (`cmp CLAUDE.md AGENTS.md` silent).
- No change to engine inspection or validation, to `SignatureTree`, or to `AttestationPreflight`'s use of the input signature state.
- Tests never touch the real `~/Library/Application Support/Chevron7` or named `UserDefaults` suites (`makeSettingsStore()`, `MemoryUserDefaults()`; `RealStorageGuard` enforces it).
- Build and test with `DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"`; run from `Chevron7/`.
- Expanded state key: `@AppStorage("signatures.bannerExpanded")`, default `false`.
- Every `feat`/`fix` commit to `main` publishes a release; this branch merges only after the owner's check of a test build (Task 6).

## Review Focus

1. The same person signed twice: the names summary must list them once ("Marián Čuprík" not "Marián Čuprík, Marián Čuprík"). Test in Task 2.
2. A signature with an empty signer name or no signing time: the row shows "Neznámy podpisovateľ" and no date, nothing crashes. Test in Task 2.
3. The done screen of a queue item that was signed earlier (its source tree never inspected, phase `.idle`): no row may be marked "nový". Test in Task 2 (`newSignatureIDs` is only applied when the existing tree was inspected; Task 3 wires that condition).
4. A Safari request for an unsigned PDF or a form: no inspection, no temporary file left behind. Test in Task 4.
5. A Safari request closed while validation still runs: the validation task is cancelled and the temporary file removed. Test in Task 4.

---

### Task 1: Extract `SignatureTreeLoader`

**Files:**
- Create: `Chevron7/Sources/Chevron7App/SignatureTreeLoader.swift`
- Modify: `Chevron7/Sources/Chevron7App/SigningSessionStore.swift` (properties at lines 62-71; `selectQueueItem`, `removeQueueItem`, `inspectExistingSignatures`, `revalidateExistingSignatures`, `revalidateResultSignatures`, `runSignatureTree`, `revalidate`, `validate`, `treeRun`, `setTreeRun`, `treeState`, `setTreeState`, `setValidationTask`, `resetSignatureTrees`, and every other assignment to `existingSignatureState`, `resultSignatureState`, `existingTreeRun`, `resultTreeRun`)
- Modify: `Chevron7/Tests/Chevron7AppTests/SignatureTreeStoreTests.swift:274` (`private final class TreeProvider` becomes `final class TreeProvider` so Task 4 can reuse it)
- Test: `Chevron7/Tests/Chevron7AppTests/SignatureTreeLoaderTests.swift`

**Interfaces:**
- Produces:
  ```swift
  @MainActor @Observable final class SignatureTreeLoader {
      init(provider: any QualifiedSigningProviding)
      private(set) var state: SignatureTreeState
      private(set) var validationTask: Task<Void, Never>?
      func load(_ url: URL) async          // structural, then validation in the background
      func revalidate(_ url: URL) async    // keeps the tree, validates again, awaits it
      func reset()                         // drops late results, cancels validation, idle state
  }
  ```
  `SigningSessionStore` keeps `existingSignatureState`, `resultSignatureState`, `existingValidationTask`, `resultValidationTask` as read-only computed properties forwarding to `existingTrees` and `resultTrees`.

- [ ] **Step 1: Write the failing test**

```swift
// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
@testable import Chevron7App
import Chevron7Kit

@MainActor
final class SignatureTreeLoaderTests: XCTestCase {
    private static let structural = SignatureTree(signatures: [
        DocumentSignatureInfo(id: "S-1", signerDisplayName: "A", state: .indeterminate)])
    private static let validated = SignatureTree(signatures: [
        DocumentSignatureInfo(id: "S-1", signerDisplayName: "A", state: .valid)])

    private func file() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("loader-\(UUID().uuidString).pdf")
        try Data("%PDF-1.7\n%%EOF".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testLoadShowsStructuralThenValidated() async throws {
        let provider = TreeProvider(inspect: .tree(Self.structural), validate: .tree(Self.validated))
        let loader = SignatureTreeLoader(provider: provider)
        await loader.load(try file())
        XCTAssertEqual(loader.state.phase, .structural)
        await provider.releaseValidation()
        await loader.validationTask?.value
        XCTAssertEqual(loader.state, SignatureTreeState(tree: Self.validated, phase: .validated))
    }

    func testResetDropsALateValidation() async throws {
        let provider = TreeProvider(inspect: .tree(Self.structural), validate: .tree(Self.validated))
        let loader = SignatureTreeLoader(provider: provider)
        await loader.load(try file())
        let task = try XCTUnwrap(loader.validationTask)
        loader.reset()
        XCTAssertTrue(task.isCancelled)
        await provider.releaseValidation()
        await task.value
        XCTAssertEqual(loader.state, SignatureTreeState())
        XCTAssertNil(loader.validationTask)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter SignatureTreeLoaderTests`
Expected: FAIL to compile, "cannot find 'SignatureTreeLoader' in scope" (and "'TreeProvider' is inaccessible" until Step 3 drops `private`).

- [ ] **Step 3: Write the implementation**

`SignatureTreeLoader.swift`, moving the store's private pipeline verbatim into one owner:

```swift
// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import Observation
import Chevron7Kit

/// A file's signature tree: the structural tree first (awaited), then full validation in
/// the background, so signing and document switches never wait for the trusted lists.
/// A run token drops results that arrive after `reset` or a newer `load`.
@MainActor
@Observable
final class SignatureTreeLoader {
    private(set) var state = SignatureTreeState()
    private(set) var validationTask: Task<Void, Never>?
    private var run = UUID()
    private let provider: any QualifiedSigningProviding

    init(provider: any QualifiedSigningProviding) {
        self.provider = provider
    }

    func load(_ url: URL) async {
        let run = UUID()
        self.run = run
        state = SignatureTreeState(tree: SignatureTree(), phase: .inspecting)
        let inspected = await provider.inspectSignatureTree(in: url)
        guard self.run == run else { return }
        switch inspected {
        case .failed(let reason):
            state = SignatureTreeState(tree: SignatureTree(), phase: .failed(reason))
            setValidationTask(nil)
        case .tree(let tree):
            let summary = SignatureTreeSummary(tree: tree)
            guard summary.total > 0 || summary.unverifiedDocuments > 0 else {
                // No signatures and nothing unverified: there is nothing to validate.
                state = SignatureTreeState(tree: tree, phase: .validated)
                setValidationTask(nil)
                return
            }
            state = SignatureTreeState(tree: tree, phase: .structural)
            setValidationTask(Task { [weak self] in
                await self?.validate(url, run: run, keptTreeWasValidated: false)
            })
        }
    }

    func revalidate(_ url: URL) async {
        let run = UUID()
        self.run = run
        let wasValidated = state.phase == .validated
        state.phase = .structural
        let task = Task<Void, Never> { [weak self] in
            await self?.validate(url, run: run, keptTreeWasValidated: wasValidated)
        }
        setValidationTask(task)
        await task.value
    }

    func reset() {
        run = UUID()
        state = SignatureTreeState()
        setValidationTask(nil)
    }

    /// `keptTreeWasValidated`: the tree shown while this runs came from an earlier validation,
    /// so a failure must not leave its verdicts (green) under "the result is only structural".
    private func validate(_ url: URL, run: UUID, keptTreeWasValidated: Bool) async {
        let validated = await provider.validateSignatureTree(in: url)
        guard self.run == run else { return }
        switch validated {
        case .tree(let tree):
            state = SignatureTreeState(tree: tree, phase: .validated)
        case .failed(let reason):
            if keptTreeWasValidated {
                state.tree = state.tree.withoutValidationVerdicts()
            }
            state.phase = .validationUnavailable(reason)
        }
    }

    /// Cancels the validation being replaced, which also ends its engine request.
    private func setValidationTask(_ task: Task<Void, Never>?) {
        if validationTask != task { validationTask?.cancel() }
        validationTask = task
    }
}
```

In `SigningSessionStore`:
- Replace lines 62-71 (`existingSignatureState` through `resultTreeRun`) with:
  ```swift
  @ObservationIgnored private(set) lazy var existingTrees = SignatureTreeLoader(provider: signingProvider)
  @ObservationIgnored private(set) lazy var resultTrees = SignatureTreeLoader(provider: signingProvider)
  var existingSignatureState: SignatureTreeState { existingTrees.state }
  var resultSignatureState: SignatureTreeState { resultTrees.state }
  /// Top-level signatures, for callers that predate the tree.
  var existingSignatures: [DocumentSignatureInfo] { existingSignatureState.tree.signatures }
  var resultSignatures: [DocumentSignatureInfo] { resultSignatureState.tree.signatures }
  var isInspectingSignatures: Bool { existingSignatureState.phase == .inspecting }
  var existingValidationTask: Task<Void, Never>? { existingTrees.validationTask }
  var resultValidationTask: Task<Void, Never>? { resultTrees.validationTask }
  ```
  (`lazy` because `signingProvider` is set in `init`; the loaders are `@Observable` themselves, so views reading the computed state still update.)
- Each block that resets one side (`existingTreeRun = UUID(); existingSignatureState = SignatureTreeState(); setValidationTask(nil, result: false)`) becomes `existingTrees.reset()`; the result side becomes `resultTrees.reset()`; `resetSignatureTrees()` calls both.
- `runSignatureTree(for: url, result: false)` becomes `await existingTrees.load(url)`; `result: true` becomes `await resultTrees.load(url)`.
- `revalidateExistingSignatures()` keeps its guard and calls `await existingTrees.revalidate(sourceURL)`; `revalidateResultSignatures()` calls `await resultTrees.revalidate(signedOutputURL)`.
- Delete `runSignatureTree`, `revalidate(url:result:)`, `validate(url:run:result:keptTreeWasValidated:)`, `treeRun`, `setTreeRun`, `treeState`, `setTreeState`, `setValidationTask`.
- `grep -n 'existingTreeRun\|resultTreeRun\|setTreeState\|setValidationTask' Sources/Chevron7App/SigningSessionStore.swift` must print nothing.

In `SignatureTreeStoreTests.swift:274`: `private final class TreeProvider` becomes `final class TreeProvider`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter 'SignatureTreeLoaderTests|SignatureTreeStoreTests|SigningBatchTests'`
Expected: PASS, with `SignatureTreeStoreTests` unchanged apart from `TreeProvider`'s access level.

- [ ] **Step 5: Commit**

```bash
git add Chevron7/Sources/Chevron7App/SignatureTreeLoader.swift Chevron7/Sources/Chevron7App/SigningSessionStore.swift Chevron7/Tests/Chevron7AppTests/SignatureTreeLoaderTests.swift Chevron7/Tests/Chevron7AppTests/SignatureTreeStoreTests.swift
git commit -m "refactor(signing): one signature tree loader for every screen"
```

### Task 2: `SignatureBannerModel`

**Files:**
- Create: `Chevron7/Sources/Chevron7App/SignatureBannerModel.swift`
- Test: `Chevron7/Tests/Chevron7AppTests/SignatureBannerModelTests.swift`

**Interfaces:**
- Consumes: `SignatureTreeState` (Task 1 unchanged type), `SignatureTreeSummary`, `SignatureTreePresentation.qualificationLabel(_:)`, `.signatureCount(_:)`, `.phaseText(_:)`, `InputSignatureInspectionResult`.
- Produces:
  ```swift
  struct SignatureBannerModel: Equatable {
      enum Tone: Equatable { case checking, valid, warning, invalid }
      struct Row: Equatable, Identifiable {
          let id: String
          let title: String               // signer, or a document name for a group row
          let verdict: DocumentSignatureInfo.State?  // nil for a document row
          let badges: [String]
          let detail: String              // "7. 10. 2026 11:25 · pokrýva a.pdf", may be empty
          let warning: String?            // a document that could not be verified
          let depth: Int                  // 0 top level, 1 inside a data object
          let isNew: Bool
      }
      let tone: Tone
      let headline: String
      let rows: [Row]
      let note: String?
      static func make(from state: SignatureTreeState, newSignatureIDs: Set<String> = []) -> SignatureBannerModel?
      static func make(from inspection: InputSignatureInspectionResult) -> SignatureBannerModel?
      static func newSignatureIDs(existing: SignatureTree, result: SignatureTree) -> Set<String>
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
@testable import Chevron7App
import Chevron7Kit

final class SignatureBannerModelTests: XCTestCase {
    private func sig(_ id: String, _ name: String, _ state: DocumentSignatureInfo.State = .valid,
                     time: Date? = nil, qualification: String? = nil, qts: Bool = false,
                     covers: [String] = []) -> DocumentSignatureInfo {
        DocumentSignatureInfo(id: id, signerDisplayName: name, signingTime: time, hasQualifiedTimestamp: qts,
                              state: state, coveredDocuments: covers, certificateQualification: qualification)
    }

    private func state(_ signatures: [DocumentSignatureInfo], _ phase: SignatureTreeState.Phase = .validated,
                       documents: [SignedDataObject] = []) -> SignatureTreeState {
        SignatureTreeState(tree: SignatureTree(signatures: signatures, documents: documents), phase: phase)
    }

    func testNoBannerWithoutSignaturesOrWhileInspecting() {
        XCTAssertNil(SignatureBannerModel.make(from: SignatureTreeState()))
        XCTAssertNil(SignatureBannerModel.make(from: state([], .inspecting)))
        XCTAssertNil(SignatureBannerModel.make(from: state([], .validated)))
    }

    func testStructuralPhaseIsChecking() throws {
        let model = try XCTUnwrap(SignatureBannerModel.make(from: state([sig("1", "A", .indeterminate), sig("2", "B", .indeterminate)], .structural)))
        XCTAssertEqual(model.tone, .checking)
        XCTAssertEqual(model.headline, "Overujem 2 podpisy voči dôveryhodným zoznamom…")
    }

    func testAllValidHeadlinesUseSlovakForms() throws {
        let one = try XCTUnwrap(SignatureBannerModel.make(from: state([sig("1", "Marián Čuprík")])))
        XCTAssertEqual(one.tone, .valid)
        XCTAssertEqual(one.headline, "Podpísané 1 podpisom, platný · Marián Čuprík")
        let two = try XCTUnwrap(SignatureBannerModel.make(from: state([sig("1", "Marián Čuprík"), sig("2", "Ján Novák")])))
        XCTAssertEqual(two.headline, "Podpísané 2 podpismi, oba platné · Marián Čuprík, Ján Novák")
        let five = try XCTUnwrap(SignatureBannerModel.make(from: state((1...5).map { sig("\($0)", "P\($0)") })))
        XCTAssertEqual(five.headline, "Podpísané 5 podpismi, všetky platné · P1, P2 a 3 ďalší")
    }

    func testSameSignerTwiceIsNamedOnce() throws {
        let model = try XCTUnwrap(SignatureBannerModel.make(from: state([sig("1", "Marián Čuprík"), sig("2", "Marián Čuprík")])))
        XCTAssertEqual(model.headline, "Podpísané 2 podpismi, oba platné · Marián Čuprík")
    }

    func testIndeterminateIsWarningAndInvalidWins() throws {
        let warning = try XCTUnwrap(SignatureBannerModel.make(from: state([sig("1", "A"), sig("2", "B", .indeterminate)])))
        XCTAssertEqual(warning.tone, .warning)
        XCTAssertEqual(warning.headline, "1 z 2 podpisov sa nedalo overiť · A, B")
        let invalid = try XCTUnwrap(SignatureBannerModel.make(from: state([sig("1", "A", .invalid), sig("2", "B", .indeterminate)])))
        XCTAssertEqual(invalid.tone, .invalid)
        XCTAssertEqual(invalid.headline, "1 podpis je neplatný · A, B")
        let three = try XCTUnwrap(SignatureBannerModel.make(from: state((1...3).map { sig("\($0)", "P\($0)", .invalid) })))
        XCTAssertEqual(three.headline, "3 podpisy sú neplatné · P1, P2 a 1 ďalší")
    }

    func testValidationUnavailableAndFailureAreWarnings() throws {
        let unavailable = try XCTUnwrap(SignatureBannerModel.make(from: state([sig("1", "A", .indeterminate)], .validationUnavailable("Zoznam CZ sa nenačítal."))))
        XCTAssertEqual(unavailable.tone, .warning)
        XCTAssertEqual(unavailable.headline, "Podpisy sa nepodarilo overiť · A")
        XCTAssertEqual(unavailable.note, "Zoznam CZ sa nenačítal.")
        let failed = try XCTUnwrap(SignatureBannerModel.make(from: state([], .failed("Engine zlyhal."))))
        XCTAssertEqual(failed.tone, .warning)
        XCTAssertEqual(failed.headline, "Podpisy sa nepodarilo skontrolovať")
        XCTAssertEqual(failed.note, "Engine zlyhal.")
        XCTAssertTrue(failed.rows.isEmpty)
    }

    func testRowsCarryBadgesDetailAndUnknownSigner() throws {
        var components = DateComponents()
        components.year = 2026; components.month = 10; components.day = 7; components.hour = 11; components.minute = 25
        let time = try XCTUnwrap(Calendar.current.date(from: components))
        let model = try XCTUnwrap(SignatureBannerModel.make(from: state([
            sig("1", "Marián Čuprík", time: time, qualification: "QESIG", qts: true, covers: ["Uznesenie.pdf"]),
            sig("2", "", .valid)])))
        XCTAssertEqual(model.rows[0].badges, ["KEP", "QTS"])
        XCTAssertEqual(model.rows[0].detail, "7. 10. 2026 11:25 · pokrýva Uznesenie.pdf")
        XCTAssertEqual(model.rows[1].title, "Neznámy podpisovateľ")
        XCTAssertEqual(model.rows[1].detail, "")
        XCTAssertEqual(model.note, "Informatívne overenie voči dôveryhodným zoznamom EÚ")
    }

    func testNestedAndUnverifiedDocumentsBecomeRows() throws {
        let nested = SignatureTree(signatures: [sig("n1", "Ján Novák")])
        let model = try XCTUnwrap(SignatureBannerModel.make(from: state([sig("1", "A")], documents: [
            SignedDataObject(name: "zmluva.pdf", content: .signed(.pdf, nested)),
            SignedDataObject(name: "velky.asice", content: .skipped(.tooLarge)),
            SignedDataObject(name: "priloha.xml", content: .plain)])))
        XCTAssertEqual(model.tone, .warning)
        XCTAssertEqual(model.rows.map(\.title), ["A", "zmluva.pdf", "Ján Novák", "velky.asice"])
        XCTAssertEqual(model.rows.map(\.depth), [0, 0, 1, 0])
        XCTAssertNil(model.rows[1].verdict)
        XCTAssertEqual(model.rows[3].warning, "Podpisy v tomto súbore sa neoverovali (súbor je príliš veľký).")
    }

    func testNewSignatureIsFirstAndMarked() throws {
        let existing = SignatureTree(signatures: [sig("old", "Ján Novák")])
        let result = SignatureTree(signatures: [sig("old", "Ján Novák"), sig("new", "Marián Čuprík")])
        let ids = SignatureBannerModel.newSignatureIDs(existing: existing, result: result)
        XCTAssertEqual(ids, ["new"])
        let model = try XCTUnwrap(SignatureBannerModel.make(from: SignatureTreeState(tree: result, phase: .validated), newSignatureIDs: ids))
        XCTAssertEqual(model.rows.map(\.title), ["Marián Čuprík", "Ján Novák"])
        XCTAssertEqual(model.rows.map(\.isNew), [true, false])
    }

    func testNewSignatureFallsBackToTheLatestWhenIdsDiffer() {
        let existing = SignatureTree(signatures: [sig("a", "Ján Novák")])
        let result = SignatureTree(signatures: [
            sig("x", "Ján Novák", time: Date(timeIntervalSince1970: 100)),
            sig("y", "Marián Čuprík", time: Date(timeIntervalSince1970: 200))])
        XCTAssertEqual(SignatureBannerModel.newSignatureIDs(existing: existing, result: result), ["y"])
        XCTAssertEqual(SignatureBannerModel.newSignatureIDs(existing: result, result: result), [])
    }

    func testZakoInspectionMapsToTheSameTones() throws {
        XCTAssertNil(SignatureBannerModel.make(from: .unavailable(detail: "Bez podpisov.")))
        let valid = try XCTUnwrap(SignatureBannerModel.make(from: .completed(signatures: [sig("1", "A")])))
        XCTAssertEqual(valid.tone, .valid)
        XCTAssertEqual(valid.note, "Kontrola vstupných elektronických podpisov bola dokončená.")
        let unknown = try XCTUnwrap(SignatureBannerModel.make(from: .completed(signatures: [sig("1", "A", .unknown)])))
        XCTAssertEqual(unknown.tone, .warning)
        let invalid = try XCTUnwrap(SignatureBannerModel.make(from: .completed(signatures: [sig("1", "A", .invalid)])))
        XCTAssertEqual(invalid.tone, .invalid)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SignatureBannerModelTests`
Expected: FAIL to compile, "cannot find 'SignatureBannerModel' in scope".

- [ ] **Step 3: Write the implementation**

```swift
// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import Chevron7Kit

/// What the signature banner above a document says: one tone, a headline with the
/// signers, rows for the expansion and a note on how far validation got.
struct SignatureBannerModel: Equatable {
    enum Tone: Equatable { case checking, valid, warning, invalid }

    struct Row: Equatable, Identifiable {
        let id: String
        let title: String
        let verdict: DocumentSignatureInfo.State?
        let badges: [String]
        let detail: String
        let warning: String?
        let depth: Int
        let isNew: Bool
    }

    let tone: Tone
    let headline: String
    let rows: [Row]
    let note: String?

    static let unknownSigner = "Neznámy podpisovateľ"

    // MARK: Builders

    static func make(from state: SignatureTreeState, newSignatureIDs: Set<String> = []) -> SignatureBannerModel? {
        switch state.phase {
        case .idle, .inspecting:
            return nil
        case .failed(let reason):
            return SignatureBannerModel(tone: .warning, headline: "Podpisy sa nepodarilo skontrolovať",
                                        rows: [], note: reason)
        case .structural, .validated, .validationUnavailable:
            break
        }
        let summary = SignatureTreeSummary(tree: state.tree)
        guard summary.total > 0 || summary.unverifiedDocuments > 0 else { return nil }
        let signatures = allSignatures(in: state.tree)
        let names = namesSummary(signatures)
        let rows = treeRows(state.tree, newSignatureIDs: newSignatureIDs)
        let note = SignatureTreePresentation.phaseText(state.phase)
        switch state.phase {
        case .structural:
            return SignatureBannerModel(
                tone: .checking,
                headline: "Overujem \(SignatureTreePresentation.signatureCount(summary.total)) voči dôveryhodným zoznamom…",
                rows: rows, note: note)
        case .validationUnavailable:
            return SignatureBannerModel(tone: .warning, headline: join("Podpisy sa nepodarilo overiť", names),
                                        rows: rows, note: note)
        default:
            return verdictModel(summary: Counts(summary), names: names, rows: rows, note: note)
        }
    }

    static func make(from inspection: InputSignatureInspectionResult) -> SignatureBannerModel? {
        guard inspection.state != .unavailable, !inspection.signatures.isEmpty else { return nil }
        let rows = inspection.signatures.map { row(for: $0, depth: 0, isNew: false) }
        return verdictModel(summary: Counts(inspection.signatures), names: namesSummary(inspection.signatures),
                            rows: rows, note: inspection.detail)
    }

    /// The signatures this session added: those whose id the source did not have, or, when
    /// the engine gave the same signatures other ids, the most recent ones by signing time.
    static func newSignatureIDs(existing: SignatureTree, result: SignatureTree) -> Set<String> {
        let before = allSignatures(in: existing)
        let after = allSignatures(in: result)
        let added = after.count - before.count
        guard added > 0 else { return [] }
        let beforeIDs = Set(before.map(\.id))
        let unseen = after.filter { !beforeIDs.contains($0.id) }
        if unseen.count == added { return Set(unseen.map(\.id)) }
        let newest = after.sorted { ($0.signingTime ?? .distantPast) > ($1.signingTime ?? .distantPast) }
        return Set(newest.prefix(added).map(\.id))
    }

    // MARK: Headlines

    private struct Counts {
        let total: Int
        let valid: Int
        let invalid: Int
        let notVerified: Int
        let unverifiedDocuments: Int

        init(_ summary: SignatureTreeSummary) {
            total = summary.total
            valid = summary.valid
            invalid = summary.invalid
            notVerified = summary.indeterminateSignatures
            unverifiedDocuments = summary.unverifiedDocuments
        }

        init(_ signatures: [DocumentSignatureInfo]) {
            total = signatures.count
            valid = signatures.filter { $0.state == .valid }.count
            invalid = signatures.filter { $0.state == .invalid }.count
            notVerified = signatures.filter { $0.state == .indeterminate || $0.state == .unknown }.count
            unverifiedDocuments = 0
        }
    }

    private static func verdictModel(summary: Counts, names: String, rows: [Row], note: String?) -> SignatureBannerModel {
        if summary.invalid > 0 {
            return SignatureBannerModel(tone: .invalid, headline: join(invalidPhrase(summary.invalid), names),
                                        rows: rows, note: note)
        }
        if summary.notVerified > 0 {
            let phrase = "\(summary.notVerified) z \(summary.total) \(genitivePlural(summary.total)) sa nedalo overiť"
            return SignatureBannerModel(tone: .warning, headline: join(phrase, names), rows: rows, note: note)
        }
        if summary.unverifiedDocuments > 0 {
            return SignatureBannerModel(tone: .warning, headline: join("Niektoré súbory v kontajneri sa neoverili", names),
                                        rows: rows, note: note)
        }
        return SignatureBannerModel(tone: .valid, headline: join(validPhrase(summary.total), names),
                                    rows: rows, note: note)
    }

    private static func validPhrase(_ count: Int) -> String {
        switch count {
        case 1: "Podpísané 1 podpisom, platný"
        case 2: "Podpísané 2 podpismi, oba platné"
        default: "Podpísané \(count) podpismi, všetky platné"
        }
    }

    private static func invalidPhrase(_ count: Int) -> String {
        switch count {
        case 1: "1 podpis je neplatný"
        case 2...4: "\(count) podpisy sú neplatné"
        default: "\(count) podpisov je neplatných"
        }
    }

    /// "1 z 2 podpisov": after "z" the noun is genitive plural for every count but one.
    private static func genitivePlural(_ count: Int) -> String {
        count == 1 ? "podpisu" : "podpisov"
    }

    private static func join(_ phrase: String, _ names: String) -> String {
        names.isEmpty ? phrase : phrase + " · " + names
    }

    /// Up to two distinct signers, then "a N ďalší".
    static func namesSummary(_ signatures: [DocumentSignatureInfo]) -> String {
        var seen = Set<String>()
        let names = signatures.map(displayName).filter { seen.insert($0).inserted }
        guard names.count > 2 else { return names.joined(separator: ", ") }
        return names.prefix(2).joined(separator: ", ") + " a \(names.count - 2) ďalší"
    }

    // MARK: Rows

    private static func allSignatures(in tree: SignatureTree) -> [DocumentSignatureInfo] {
        tree.signatures + tree.documents.flatMap { document -> [DocumentSignatureInfo] in
            if case .signed(_, let nested) = document.content { return allSignatures(in: nested) }
            return []
        }
    }

    private static func treeRows(_ tree: SignatureTree, newSignatureIDs: Set<String>) -> [Row] {
        let own = tree.signatures
            .sorted { newSignatureIDs.contains($0.id) && !newSignatureIDs.contains($1.id) }
            .map { row(for: $0, depth: 0, isNew: newSignatureIDs.contains($0.id)) }
        let documents = tree.documents.flatMap { document -> [Row] in
            switch document.content {
            case .plain:
                return []
            case .signed(_, let nested):
                let header = Row(id: "doc-" + document.name, title: document.name, verdict: nil, badges: [],
                                 detail: SignatureTreePresentation.signatureCount(nested.signatures.count),
                                 warning: nil, depth: 0, isNew: false)
                return [header] + nested.signatures.map { row(for: $0, depth: 1, isNew: newSignatureIDs.contains($0.id)) }
            case .skipped(.depthLimit):
                return [warningRow(document, "Podpisy v tomto súbore sa neoverovali (ďalšie vnorenie).")]
            case .skipped(.tooLarge):
                return [warningRow(document, "Podpisy v tomto súbore sa neoverovali (súbor je príliš veľký).")]
            case .failed:
                return [warningRow(document, "Podpisy v tomto súbore sa nepodarilo overiť.")]
            }
        }
        return own + documents
    }

    private static func warningRow(_ document: SignedDataObject, _ text: String) -> Row {
        Row(id: "doc-" + document.name, title: document.name, verdict: nil, badges: [], detail: "",
            warning: text, depth: 0, isNew: false)
    }

    private static func row(for signature: DocumentSignatureInfo, depth: Int, isNew: Bool) -> Row {
        var badges: [String] = []
        if let label = SignatureTreePresentation.qualificationLabel(signature.certificateQualification) {
            badges.append(label)
        }
        if signature.hasQualifiedTimestamp {
            badges.append("QTS")
        } else if signature.hasTimestamp {
            badges.append("Časová pečiatka")
        }
        var parts: [String] = []
        if let time = signature.signingTime { parts.append(timeFormatter.string(from: time)) }
        if !signature.coveredDocuments.isEmpty {
            parts.append("pokrýva " + signature.coveredDocuments.joined(separator: ", "))
        }
        return Row(id: signature.id, title: displayName(signature), verdict: signature.state, badges: badges,
                   detail: parts.joined(separator: " · "), warning: nil, depth: depth, isNew: isNew)
    }

    private static func displayName(_ signature: DocumentSignatureInfo) -> String {
        let name = signature.signerDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? unknownSigner : name
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "sk_SK")
        formatter.dateFormat = "d. M. yyyy HH:mm"
        return formatter
    }()
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SignatureBannerModelTests`
Expected: PASS (11 tests). If the "1 z 2 podpisov" wording fails for a total of 1, it reads "1 z 1 podpisu", which is the intended form.

- [ ] **Step 5: Commit**

```bash
git add Chevron7/Sources/Chevron7App/SignatureBannerModel.swift Chevron7/Tests/Chevron7AppTests/SignatureBannerModelTests.swift
git commit -m "feat(signing): describe a document's signatures for one banner"
```

### Task 3: `SignatureBanner` view in signing (prepare and done)

**Files:**
- Create: `Chevron7/Sources/Chevron7App/Views/SignatureBanner.swift`
- Modify: `Chevron7/Sources/Chevron7App/Views/SigningFlowViews.swift` (`SigningPrepareView.previewColumn` at line 512; inspector "Section 4: Existujúce podpisy" at lines 846-854; `existingSignaturesSection` and `signatureSectionTitle` at lines 568-586; `SigningDoneView.previewColumn` at line 1054; GroupBox "Overenie podpisov v súbore" at lines 1113-1120; `SignatureInfoRow` at line 916)
- Modify: `Chevron7/Sources/Chevron7App/Views/SignatureTreeView.swift` (delete `SignatureTreeView` and `DataObjectGroup`; keep `SignatureTreePresentation`)

**Interfaces:**
- Consumes: `SignatureBannerModel` (Task 2), `SigningSessionStore.existingSignatureState`, `resultSignatureState`, `revalidateExistingSignatures()`, `revalidateResultSignatures()`, `isSigning` (Task 1).
- Produces:
  ```swift
  struct SignatureBanner: View {
      init(model: SignatureBannerModel, onRevalidate: (() -> Void)? = nil, revalidateDisabled: Bool = false)
  }
  ```

- [ ] **Step 1: Write the view**

```swift
// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import SwiftUI
import Chevron7Kit

/// A document's signatures at a glance, above the document: tone, headline with the
/// signers, and the rows inline once expanded. The same banner in signing, the Safari
/// panel and ZaKo; the expanded state is remembered for all of them.
struct SignatureBanner: View {
    let model: SignatureBannerModel
    var onRevalidate: (() -> Void)?
    var revalidateDisabled = false
    @AppStorage("signatures.bannerExpanded") private var isExpanded = false
    @Environment(\.openURL) private var openURL

    init(model: SignatureBannerModel, onRevalidate: (() -> Void)? = nil, revalidateDisabled: Bool = false) {
        self.model = model
        self.onRevalidate = onRevalidate
        self.revalidateDisabled = revalidateDisabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                // The symbol and the headline read as one element; the disclosure stays a button.
                HStack(spacing: 8) {
                    if model.tone == .checking {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: symbol).foregroundStyle(tint)
                    }
                    Text(model.headline)
                        .font(.callout)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .accessibilityElement(children: .combine)
                if !model.rows.isEmpty || model.note != nil {
                    Button(isExpanded ? "Skryť ▴" : "Podpisy ▾") { isExpanded.toggle() }
                        .buttonStyle(.link)
                        .accessibilityLabel(isExpanded ? "Skryť podpisy" : "Zobraziť podpisy")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            if isExpanded {
                Divider().overlay(tint.opacity(0.3))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.rows) { row in
                        SignatureBannerRow(row: row)
                    }
                    footer
                }
                .padding(10)
            }
        }
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(tint.opacity(0.35)))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let note = model.note {
                Text(note).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let onRevalidate {
                Button("Overiť znova", action: onRevalidate)
                    .buttonStyle(.link)
                    .font(.caption2)
                    .disabled(revalidateDisabled || model.tone == .checking)
            }
            Button("Overiť aj na slovensko.sk") { openURL(SignatureTreePresentation.officialValidationURL) }
                .buttonStyle(.link)
                .font(.caption2)
                .help("Otvorí informatívne overenie podpisov na slovensko.sk. Súbor tam nahráte sami.")
        }
    }

    private var tint: Color {
        switch model.tone {
        case .checking: .secondary
        case .valid: .green
        case .warning: .orange
        case .invalid: .red
        }
    }

    private var symbol: String {
        switch model.tone {
        case .checking: "hourglass"
        case .valid: "checkmark.seal.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .invalid: "xmark.seal.fill"
        }
    }
}

private struct SignatureBannerRow: View {
    let row: SignatureBannerModel.Row

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if let verdict = row.verdict {
                Image(systemName: SignatureTreePresentation.icon(verdict))
                    .foregroundStyle(SignatureTreePresentation.tint(verdict))
                    .frame(width: 16)
            } else {
                Image(systemName: row.warning == nil ? "doc.text" : "exclamationmark.triangle.fill")
                    .foregroundStyle(row.warning == nil ? Color.secondary : Color.orange)
                    .frame(width: 16)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(row.title).font(.caption.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    if row.isNew {
                        Text("nový").font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                    ForEach(row.badges, id: \.self) { badge in
                        Text(badge).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                if !row.detail.isEmpty {
                    Text(row.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                }
                if let warning = row.warning {
                    Text(warning).font(.caption2).foregroundStyle(.orange)
                }
            }
        }
        .padding(.leading, CGFloat(row.depth) * 18)
        .accessibilityElement(children: .combine)
    }
}
```

- [ ] **Step 2: Place it in `SigningPrepareView`**

In `previewColumn` (line 512), insert as the first child of the outer `VStack(spacing: 10)`:

```swift
            if let banner = SignatureBannerModel.make(from: store.existingSignatureState) {
                SignatureBanner(model: banner,
                                onRevalidate: { Task { await store.revalidateExistingSignatures() } },
                                revalidateDisabled: store.isSigning)
            }
```

Delete the inspector block "Section 4: Existujúce podpisy" (lines 846-854, the `VStack` with `Label(signatureSectionTitle, ...)` and `existingSignaturesSection` and its `.inspectorCard`), and delete `existingSignaturesSection` and `signatureSectionTitle` (lines 568-586). Keep `existingSignatureFormatNote`.

- [ ] **Step 3: Place it in `SigningDoneView`**

In `SigningDoneView.previewColumn` (line 1054), insert as the first child of the outer `VStack(spacing: 10)`:

```swift
            if let banner = SignatureBannerModel.make(
                from: store.resultSignatureState,
                // Only a source inspected in this session tells which signature is new;
                // a queue item signed earlier marks none.
                newSignatureIDs: store.existingSignatureState.phase == .idle ? [] :
                    SignatureBannerModel.newSignatureIDs(existing: store.existingSignatureState.tree,
                                                         result: store.resultSignatureState.tree)) {
                SignatureBanner(model: banner,
                                onRevalidate: { Task { await store.revalidateResultSignatures() } },
                                revalidateDisabled: store.isSigning)
            }
```

Delete the `GroupBox("Overenie podpisov v súbore") { SignatureTreeView(...) }` block (lines 1113-1120).

- [ ] **Step 4: Remove the dead tree views**

Delete `struct SignatureTreeView` and `private struct DataObjectGroup` from `SignatureTreeView.swift` (keep `enum SignatureTreePresentation`) and `struct SignatureInfoRow` from `SigningFlowViews.swift` (line 916 to its closing brace). Then:

Run: `grep -rn 'SignatureTreeView(\|SignatureInfoRow(\|DataObjectGroup(' Sources Tests`
Expected: no output.

- [ ] **Step 5: Build and run the signing tests**

Run: `swift build && swift test --filter 'SignatureTreeStoreTests|SignatureTreePresentationTests|SignatureBannerModelTests|SigningBatchTests'`
Expected: build succeeds without new warnings in these files; tests PASS.

- [ ] **Step 6: Commit**

```bash
git add Chevron7/Sources/Chevron7App/Views/SignatureBanner.swift Chevron7/Sources/Chevron7App/Views/SigningFlowViews.swift Chevron7/Sources/Chevron7App/Views/SignatureTreeView.swift
git commit -m "feat(signing): show existing signatures as a banner above the document"
```

### Task 4: Safari panel

**Files:**
- Create: `Chevron7/Sources/Chevron7App/WebSigningSignatureCheck.swift`
- Modify: `Chevron7/Sources/Chevron7App/WebSigningCoordinator.swift` (property next to `pending` at line 70; `handle(_:)` after `pending = Pending(...)` at line 276; `finish(_:token:)` at line 574)
- Modify: `Chevron7/Sources/Chevron7App/Views/WebSigningSheet.swift:16-26`
- Test: `Chevron7/Tests/Chevron7AppTests/WebSigningSignatureCheckTests.swift`

**Interfaces:**
- Consumes: `SignatureTreeLoader` (Task 1), `SignatureBannerModel` (Task 2), `SignatureBanner` (Task 3), `ExistingSignatureGuard.classify(fileName:data:)`, `TreeProvider` (test double from `SignatureTreeStoreTests.swift`, internal since Task 1).
- Produces:
  ```swift
  @MainActor @Observable final class WebSigningSignatureCheck {
      init(temporaryRoot: URL = FileManager.default.temporaryDirectory)
      private(set) var loader: SignatureTreeLoader?
      private(set) var loadTask: Task<Void, Never>?
      private(set) var fileURL: URL?
      var bannerModel: SignatureBannerModel? { get }
      static func inspects(fileName: String, data: Data) -> Bool
      func start(fileName: String, data: Data, provider: any QualifiedSigningProviding)  // synchronous setup, loads in loadTask
      func stop()
  }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
@testable import Chevron7App
import Chevron7Kit

@MainActor
final class WebSigningSignatureCheckTests: XCTestCase {
    private static let signed = SignatureTree(signatures: [
        DocumentSignatureInfo(id: "S-1", signerDisplayName: "Ján Novák", state: .indeterminate)])
    private static let signedPDF = Data("%PDF-1.7\n1 0 obj << /Type /Sig /ByteRange [0 10 20 30] >> endobj\n%%EOF".utf8)
    private static let unsignedPDF = Data("%PDF-1.7\n%%EOF".utf8)

    private func root() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("web-check-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func files(in root: URL) -> [String] {
        (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? [])
            .filter { $0.hasSuffix(".pdf") || $0.hasSuffix(".asice") }
    }

    func testOnlySignedPDFsAndContainersAreInspected() {
        XCTAssertTrue(WebSigningSignatureCheck.inspects(fileName: "a.pdf", data: Self.signedPDF))
        XCTAssertFalse(WebSigningSignatureCheck.inspects(fileName: "a.pdf", data: Self.unsignedPDF))
        XCTAssertFalse(WebSigningSignatureCheck.inspects(fileName: "form.xml", data: Data("<a/>".utf8)))
    }

    func testUnsignedDocumentStartsNothingAndLeavesNoFile() async {
        let provider = TreeProvider(inspect: .tree(Self.signed), validate: .tree(Self.signed))
        let root = root()
        let check = WebSigningSignatureCheck(temporaryRoot: root)
        check.start(fileName: "a.pdf", data: Self.unsignedPDF, provider: provider)
        XCTAssertNil(check.loader)
        XCTAssertNil(check.loadTask)
        XCTAssertNil(check.bannerModel)
        XCTAssertEqual(files(in: root), [])
    }

    func testSignedDocumentShowsCheckingBannerAndStopCleansUp() async throws {
        let provider = TreeProvider(inspect: .tree(Self.signed), validate: .tree(Self.signed))
        let root = root()
        let check = WebSigningSignatureCheck(temporaryRoot: root)
        check.start(fileName: "zmluva.pdf", data: Self.signedPDF, provider: provider)
        await check.loadTask?.value
        XCTAssertEqual(check.bannerModel?.tone, .checking)
        XCTAssertEqual(files(in: root).count, 1)
        let validation = try XCTUnwrap(check.loader?.validationTask)

        check.stop()

        XCTAssertTrue(validation.isCancelled)
        XCTAssertNil(check.bannerModel)
        XCTAssertEqual(files(in: root), [])
        await provider.releaseValidation()
    }

    /// A panel closed right after it opened: the load that had not run yet does nothing,
    /// and neither a loader nor a file is left behind.
    func testStopRightAfterStartLeavesNothing() async throws {
        let provider = TreeProvider(inspect: .tree(Self.signed), validate: .tree(Self.signed))
        let root = root()
        let check = WebSigningSignatureCheck(temporaryRoot: root)
        check.start(fileName: "zmluva.pdf", data: Self.signedPDF, provider: provider)
        let load = try XCTUnwrap(check.loadTask)
        check.stop()
        await load.value
        XCTAssertNil(check.loader)
        XCTAssertNil(check.bannerModel)
        XCTAssertEqual(files(in: root), [])
        XCTAssertEqual(provider.validateCalls, 0)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter WebSigningSignatureCheckTests`
Expected: FAIL to compile, "cannot find 'WebSigningSignatureCheck' in scope".

- [ ] **Step 3: Write `WebSigningSignatureCheck`**

```swift
// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import Observation
import Chevron7Kit

/// The signatures of a document a portal sent, for the banner in the signing panel.
/// Only bytes that are already signed (a PDF with a signature, a container) are
/// inspected, so the usual unsigned portal document costs no engine work. The document
/// arrives in memory; it is written to a private temporary file for the engine and
/// removed when the request ends. Validation never holds up the signature.
@MainActor
@Observable
final class WebSigningSignatureCheck {
    private(set) var loader: SignatureTreeLoader?
    private(set) var loadTask: Task<Void, Never>?
    private(set) var fileURL: URL?
    private let temporaryRoot: URL

    init(temporaryRoot: URL = FileManager.default.temporaryDirectory) {
        self.temporaryRoot = temporaryRoot
    }

    var bannerModel: SignatureBannerModel? {
        loader.flatMap { SignatureBannerModel.make(from: $0.state) }
    }

    static func inspects(fileName: String, data: Data) -> Bool {
        ExistingSignatureGuard.classify(fileName: fileName, data: data) != .unsignedPDF
            && (data.starts(with: Data("%PDF".utf8)) || data.starts(with: Data("PK".utf8)))
    }

    /// Sets everything up at once, so a `stop` that follows always finds it; only the
    /// engine work runs later, in `loadTask`, and a cancelled one never starts.
    func start(fileName: String, data: Data, provider: any QualifiedSigningProviding) {
        stop()
        guard Self.inspects(fileName: fileName, data: data) else { return }
        let directory = temporaryRoot.appendingPathComponent("chevron7-web-signatures-\(UUID().uuidString)")
        let lastComponent = (fileName as NSString).lastPathComponent
        let url = directory.appendingPathComponent(lastComponent.isEmpty ? "dokument" : lastComponent)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic])
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return
        }
        let loader = SignatureTreeLoader(provider: provider)
        self.loader = loader
        fileURL = url
        loadTask = Task {
            guard !Task.isCancelled else { return }
            await loader.load(url)
        }
    }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        loader?.reset()
        loader = nil
        if let fileURL {
            try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent())
        }
        fileURL = nil
    }
}
```

- [ ] **Step 4: Wire it into the coordinator and the sheet**

In `WebSigningCoordinator`, next to `private(set) var pending: Pending?` (line 70):

```swift
    /// Existing signatures of the document in the panel, for its banner.
    let signatureCheck = WebSigningSignatureCheck()
```

In `handle(_:)`, right after `startCardWatch()` (after line 291), before the continuation (synchronous, so `finish` always finds what it has to stop):

```swift
        signatureCheck.start(fileName: request.filename, data: bytes, provider: provider)
```

In `finish(_:token:)` (line 574), after `pending = nil`:

```swift
        signatureCheck.stop()
```

In `WebSigningSheet.body` (lines 16-26), insert between `header` and the `HStack`:

```swift
            if let banner = coordinator.signatureCheck.bannerModel {
                SignatureBanner(model: banner)
            }
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter 'WebSigningSignatureCheckTests|WebSignSessionGateTests|WebSigningPayloadTests'`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Chevron7/Sources/Chevron7App/WebSigningSignatureCheck.swift Chevron7/Sources/Chevron7App/WebSigningCoordinator.swift Chevron7/Sources/Chevron7App/Views/WebSigningSheet.swift Chevron7/Tests/Chevron7AppTests/WebSigningSignatureCheckTests.swift
git commit -m "feat(web-signing): show who already signed a portal's document"
```

### Task 5: ZaKo authorization

**Files:**
- Modify: `Chevron7/Sources/Chevron7App/Views/AuthorizeDoneViews.swift:177-182` (the detail `Text` in `checklistCard`)

**Interfaces:**
- Consumes: `SignatureBannerModel.make(from: InputSignatureInspectionResult)` (Task 2), `SignatureBanner` (Task 3), `store.inputSignatureInspection`.

- [ ] **Step 1: Replace the detail sentence**

Replace lines 177-182 (the `Text(store.inputSignatureInspection.detail)` with its modifiers) with:

```swift
            if let banner = SignatureBannerModel.make(from: store.inputSignatureInspection) {
                SignatureBanner(model: banner)
            } else {
                Text(store.inputSignatureInspection.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Detail overenia vstupných podpisov")
                    .accessibilityValue(store.inputSignatureInspection.detail)
            }
```

(The checklist line from `inputSignatureChecklistItem` stays; no "Overiť znova" in ZaKo, so no closure is passed.)

- [ ] **Step 2: Build and run the ZaKo tests**

Run: `swift build && swift test --filter 'Zako'`
Expected: build succeeds; every `Zako*` test PASSES.

- [ ] **Step 3: Commit**

```bash
git add Chevron7/Sources/Chevron7App/Views/AuthorizeDoneViews.swift
git commit -m "feat(zako): show the input document's signatures as the same banner"
```

### Task 6: Docs, release note, full suite, owner check

**Files:**
- Modify: `CLAUDE.md`, `AGENTS.md` (identically)
- Create: `docs/releases/changes/feat-podpisy-na-prvy-pohlad.md`
- Modify: `Chevron7/docs/superpowers/specs/2026-10-07-signature-banner-design.md` (Status line)

- [ ] **Step 1: Docs**

In `CLAUDE.md` and `AGENTS.md`, bullet "Signing an already signed document", replace the sentence beginning "The signing screens show the signature tree (`SignatureTreeView`, `SignatureTreeState`):" up to "the store shows the structural tree at once and replaces it with the trusted-list result in the background," with:

"The signing screens show a signature banner above the document (`SignatureBanner`, `SignatureBannerModel`, `SignatureTreeState`; also in the Safari panel for a signed portal document, `WebSigningSignatureCheck`, and in ZaKo authorization from `InputSignatureInspectionResult`): grey while validating, green when every signature is valid, orange when one could not be verified or validation failed, red for an invalid one, with up to two signer names and inline rows once expanded (remembered, `signatures.bannerExpanded`), the signature added on the done screen first and marked \"nový\"; the engine's INSPECT and VALIDATE payloads list each container data object with `nested` signatures (PDF or ASiC, one level deep, by bytes not name; deeper or over 100 MB marked `nestedSkipped`, a failure `nestedError`), `SignatureTreeLoader` shows the structural tree at once and replaces it with the trusted-list result in the background,"

Then `cmp CLAUDE.md AGENTS.md` must be silent.

Release note `docs/releases/changes/feat-podpisy-na-prvy-pohlad.md`:

```markdown
- **Podpisy dokumentu na prvý pohľad.** Keď otvoríte podpísané PDF alebo kontajner .asice, nad dokumentom sa ukáže pruh, kto ho podpísal a či sú podpisy platné: zelený, keď sú všetky platné, oranžový, keď sa niektorý nedal overiť, a červený pri neplatnom podpise. Kliknutím na „Podpisy“ sa pruh rozbalí s podrobnosťami ku každému podpisu (kvalifikácia, časová pečiatka, čas, ktoré súbory pokrýva) a s tlačidlami na nové overenie. Rovnaký pruh uvidíte po podpísaní (váš nový podpis je označený „nový“), v okne podpisovania zo Safari, keď stránka pošle už podpísaný dokument, a v zaručenej konverzii pri vstupnom dokumente. Pravý panel pri podpisovaní teraz obsahuje už len to, čo treba na nový podpis.
```

Spec Status line: `Status: implemented on branch claude/signature-banner (2026-10-07)`.

- [ ] **Step 2: Full checks**

Run, from `Chevron7/`:
```bash
swift test
scripts/check-rename-boundary.sh
grep -rn $'\u2014' Sources/Chevron7App/SignatureBannerModel.swift Sources/Chevron7App/SignatureTreeLoader.swift Sources/Chevron7App/WebSigningSignatureCheck.swift Sources/Chevron7App/Views/SignatureBanner.swift ../CLAUDE.md ../docs/releases/changes/feat-podpisy-na-prvy-pohlad.md
```
Expected: all tests PASS (a `RealStorageGuard` failure while Chevron7 itself writes its data during the run is environmental: quit Chevron7 and rerun that test); "Boundary holds"; the grep prints nothing.

- [ ] **Step 3: Commit and push**

```bash
git add CLAUDE.md AGENTS.md docs/releases/changes/feat-podpisy-na-prvy-pohlad.md Chevron7/docs/superpowers/specs/2026-10-07-signature-banner-design.md
git commit -m "docs: signature banner"
git push -u origin claude/signature-banner
```

- [ ] **Step 4: Owner check (gate before merge)**

Build a Developer ID test build named "Chevron7 TEST" (as on 2026-10-07: `scripts/build-engine.sh` if the engine is stale, `build_app.sh --release package`, set `CFBundleName` and `CFBundleDisplayName` to "Chevron7 TEST", `scripts/sign-release.sh`, and with the owner's yes `NOTARY_KEYCHAIN_PROFILE=chevron7 scripts/notarize-release.sh`), install it, and ask the owner to check: a signed ASiC-E with several signatures, a signed PDF, an unsigned PDF (no banner), adding a signature and the done screen ("nový"), a portal document from schranka or nove.slovensko.sk in Safari, and an electronic ZaKo input. Open the PR as a draft and merge only after the owner confirms.

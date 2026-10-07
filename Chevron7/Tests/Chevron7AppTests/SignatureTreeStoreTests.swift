// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
@testable import Chevron7App
import Chevron7Kit
import Chevron7TestSupport

@MainActor
final class SignatureTreeStoreTests: XCTestCase {
    private func makeStore(_ provider: TreeProvider) -> SigningSessionStore {
        let settings = makeSettingsStore()
        let recent = RecentDocumentStore(settingsStore: settings, defaults: MemoryUserDefaults())
        return SigningSessionStore(signingProvider: provider, settingsStore: settings, recentDocumentStore: recent)
    }

    private func file() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tree-\(UUID().uuidString).pdf")
        try Data("%PDF-1.7\n%%EOF".utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A real, openable PDF, for tests that go through `addDocuments` and `selectQueueItem`
    /// (`TestPDFBuilderApp`).
    private func pdfFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tree-\(UUID().uuidString).pdf")
        try TestPDFBuilderApp.typicalContractPDF().write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private static let validatedFirst = SignatureTree(signatures: [
        DocumentSignatureInfo(id: "S-first", signerDisplayName: "First", state: .valid)])
    private static let structural = SignatureTree(signatures: [
        DocumentSignatureInfo(id: "S-1", signerDisplayName: "A", state: .indeterminate)])
    private static let validated = SignatureTree(signatures: [
        DocumentSignatureInfo(id: "S-1", signerDisplayName: "A", state: .valid)])

    func testStructuralThenValidated() async throws {
        let provider = TreeProvider(inspect: .tree(Self.structural), validate: .tree(Self.validated))
        let store = makeStore(provider)
        store.sourceURL = try file()

        await store.inspectExistingSignatures()
        XCTAssertEqual(store.existingSignatureState.phase, .structural)
        XCTAssertEqual(store.existingSignatureState.tree, Self.structural)

        await provider.releaseValidation()
        await store.existingValidationTask?.value
        XCTAssertEqual(store.existingSignatureState.phase, .validated)
        XCTAssertEqual(store.existingSignatures.map(\.state), [.valid])
    }

    func testValidationUnavailableKeepsStructuralTree() async throws {
        let provider = TreeProvider(inspect: .tree(Self.structural), validate: .failed("offline"))
        let store = makeStore(provider)
        store.sourceURL = try file()

        await store.inspectExistingSignatures()
        await provider.releaseValidation()
        await store.existingValidationTask?.value

        XCTAssertEqual(store.existingSignatureState.phase, .validationUnavailable("offline"))
        XCTAssertEqual(store.existingSignatureState.tree, Self.structural)
    }

    func testFailedInspectionIsNotEmpty() async throws {
        let provider = TreeProvider(inspect: .failed("broken"), validate: .tree(Self.validated))
        let store = makeStore(provider)
        store.sourceURL = try file()

        await store.inspectExistingSignatures()

        XCTAssertEqual(store.existingSignatureState.phase, .failed("broken"))
        XCTAssertNil(store.existingValidationTask)
    }

    func testStaleValidationIsDropped() async throws {
        let provider = TreeProvider(inspect: .tree(Self.structural), validate: .tree(Self.validated))
        let store = makeStore(provider)
        let first = try file()
        let second = try file()
        provider.setValidation(.tree(Self.validatedFirst), for: first)
        provider.setValidation(.tree(Self.validated), for: second)

        store.sourceURL = first
        await store.inspectExistingSignatures()
        let stale = store.existingValidationTask

        store.sourceURL = second
        await store.inspectExistingSignatures()
        let current = store.existingValidationTask

        // The current validation finishes first, the stale one last.
        await provider.releaseValidation(for: second)
        await current?.value
        await provider.releaseValidation(for: first)
        await stale?.value

        XCTAssertEqual(provider.validateCalls, 2)
        XCTAssertEqual(store.existingSignatureState.tree, Self.validated)
        XCTAssertEqual(store.existingSignatureState.phase, .validated)
    }

    /// A validation of the previous document that lands while the next one is being opened
    /// (analysis and card refresh run before its own inspection) must not show up.
    func testPreviousDocumentValidationDoesNotLandWhileSwitchingDocuments() async throws {
        let provider = TreeProvider(inspect: .tree(Self.structural), validate: .tree(Self.validated))
        let store = makeStore(provider)
        let first = try pdfFile()
        let second = try pdfFile()
        provider.setValidation(.tree(Self.validatedFirst), for: first)
        provider.setValidation(.tree(Self.validated), for: second)

        await store.addDocuments(at: [first])
        let previous = try XCTUnwrap(store.existingValidationTask)
        var seenDuringSwitch: [SignatureTreeState] = []
        provider.onAvailableIdentities = { @MainActor in
            await provider.releaseValidation(for: first)
            await previous.value
            seenDuringSwitch.append(store.existingSignatureState)
        }

        await store.addDocuments(at: [second])
        provider.onAvailableIdentities = nil
        await provider.releaseValidation(for: second)
        await store.existingValidationTask?.value

        XCTAssertEqual(seenDuringSwitch.count, 1)
        XCTAssertNotEqual(seenDuringSwitch.first?.tree, Self.validatedFirst)
        XCTAssertNotEqual(seenDuringSwitch.first?.phase, .validated)
        XCTAssertEqual(store.existingSignatureState.tree, Self.validated)
    }

    func testRemovingTheSelectedDocumentDropsItsValidation() async throws {
        let provider = TreeProvider(inspect: .tree(Self.structural), validate: .tree(Self.validated))
        let store = makeStore(provider)
        let first = try pdfFile()
        await store.addDocuments(at: [first])
        let previous = try XCTUnwrap(store.existingValidationTask)

        store.removeQueueItem(try XCTUnwrap(store.selectedQueueID))
        await provider.releaseValidation(for: first)
        await previous.value

        XCTAssertEqual(store.existingSignatureState, SignatureTreeState())
        XCTAssertNil(store.existingValidationTask)
    }

    func testRevalidateRunsValidationAgain() async throws {
        let provider = TreeProvider(inspect: .tree(Self.structural), validate: .failed("offline"))
        let store = makeStore(provider)
        store.sourceURL = try file()
        await store.inspectExistingSignatures()
        await provider.releaseValidation()
        await store.existingValidationTask?.value

        provider.validateResult = .tree(Self.validated)
        let revalidation = Task { await store.revalidateExistingSignatures() }
        await provider.releaseValidation()
        await revalidation.value

        XCTAssertEqual(provider.validateCalls, 2)
        XCTAssertEqual(store.existingSignatureState.phase, .validated)
    }

    /// Nothing to validate: the trusted lists are never consulted for an unsigned document.
    func testEmptyStructuralTreeIsNeverValidated() async throws {
        let provider = TreeProvider(inspect: .tree(SignatureTree()), validate: .tree(Self.validated))
        let store = makeStore(provider)
        store.sourceURL = try file()

        await store.inspectExistingSignatures()

        XCTAssertEqual(provider.validateCalls, 0)
        XCTAssertNil(store.existingValidationTask)
        XCTAssertEqual(store.existingSignatureState, SignatureTreeState(tree: SignatureTree(), phase: .validated))
    }

    /// A data object that could not be verified still deserves a validation run.
    func testUnverifiedDocumentStillValidates() async throws {
        let unverified = SignatureTree(documents: [SignedDataObject(name: "deep.asice", content: .skipped(.depthLimit))])
        let provider = TreeProvider(inspect: .tree(unverified), validate: .tree(unverified))
        let store = makeStore(provider)
        store.sourceURL = try file()

        await store.inspectExistingSignatures()
        await provider.releaseValidation()
        await store.existingValidationTask?.value

        XCTAssertEqual(provider.validateCalls, 1)
        XCTAssertEqual(store.existingSignatureState.phase, .validated)
    }

    /// A new run cancels the validation it replaces, so the engine request behind it ends.
    func testANewRunCancelsTheValidationItReplaces() async throws {
        let provider = TreeProvider(inspect: .tree(Self.structural), validate: .tree(Self.validated))
        let store = makeStore(provider)
        store.sourceURL = try file()
        await store.inspectExistingSignatures()
        let replaced = try XCTUnwrap(store.existingValidationTask)

        await store.inspectExistingSignatures()
        let current = try XCTUnwrap(store.existingValidationTask)

        XCTAssertTrue(replaced.isCancelled)
        XCTAssertFalse(current.isCancelled)
        store.reset()
        XCTAssertTrue(current.isCancelled)
        await provider.releaseValidation()
        await replaced.value
        await current.value
    }

    /// Green must never show under a failed validation: a tree kept from an earlier validated
    /// result is downgraded at every level when revalidation fails.
    func testFailedRevalidationDowngradesTheEarlierValidatedTree() async throws {
        let nested = SignatureTree(
            signatures: [DocumentSignatureInfo(id: "S-top", signerDisplayName: "Top", hasQualifiedTimestamp: true,
                                               state: .valid, certificateQualification: "QESIG")],
            documents: [SignedDataObject(name: "report.pdf", content: .signed(.pdf, SignatureTree(signatures: [
                DocumentSignatureInfo(id: "S-inner", signerDisplayName: "Inner", state: .valid,
                                      certificateQualification: "QESIG"),
                DocumentSignatureInfo(id: "S-bad", signerDisplayName: "Bad", state: .invalid)
            ])))])
        let provider = TreeProvider(inspect: .tree(Self.structural), validate: .tree(nested))
        let store = makeStore(provider)
        store.sourceURL = try file()
        await store.inspectExistingSignatures()
        await provider.releaseValidation()
        await store.existingValidationTask?.value
        XCTAssertEqual(store.existingSignatureState.phase, .validated)

        provider.validateResult = .failed("offline")
        await store.revalidateExistingSignatures()

        let state = store.existingSignatureState
        XCTAssertEqual(state.phase, .validationUnavailable("offline"))
        let top = try XCTUnwrap(state.tree.signatures.first)
        XCTAssertEqual(top.state, .indeterminate)
        XCTAssertFalse(top.hasQualifiedTimestamp)
        XCTAssertTrue(top.hasTimestamp)
        XCTAssertNil(top.certificateQualification)
        guard case .signed(.pdf, let inner)? = state.tree.documents.first?.content else {
            return XCTFail("The nested document must be kept.")
        }
        XCTAssertEqual(inner.signatures.map(\.state), [.indeterminate, .indeterminate])
        XCTAssertEqual(inner.signatures.map(\.certificateQualification), [nil, nil])
        XCTAssertNotEqual(SignatureTreeSummary(tree: state.tree).overall, .valid)
    }

    /// A structural tree under a failed first validation stays as the engine reported it.
    func testFailedFirstValidationKeepsTheStructuralStates() async throws {
        let structural = SignatureTree(signatures: [
            DocumentSignatureInfo(id: "S-1", signerDisplayName: "A", state: .unknown)])
        let provider = TreeProvider(inspect: .tree(structural), validate: .failed("offline"))
        let store = makeStore(provider)
        store.sourceURL = try file()

        await store.inspectExistingSignatures()
        await provider.releaseValidation()
        await store.existingValidationTask?.value

        XCTAssertEqual(store.existingSignatureState.phase, .validationUnavailable("offline"))
        XCTAssertEqual(store.existingSignatureState.tree, structural)
    }
}

/// Validation waits until the test releases it, so phases can be observed in order.
/// Two validations may run on different threads at once, so all state sits behind a lock
/// and the gate check and the continuation hand-off happen atomically.
final class TreeProvider: QualifiedSigningProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _inspectResult: SignatureTreeResult
    private var _validateResult: SignatureTreeResult
    private var perURL: [URL: SignatureTreeResult] = [:]
    private var _validateCalls = 0
    private var waiting: [(url: URL, continuation: CheckedContinuation<Void, Never>)] = []
    private var openURLs: Set<URL> = []
    private var allOpen = false
    private var _onAvailableIdentities: (@MainActor @Sendable () async -> Void)?

    var inspectResult: SignatureTreeResult {
        get { lock.withLock { _inspectResult } }
        set { lock.withLock { _inspectResult = newValue } }
    }
    var validateResult: SignatureTreeResult {
        get { lock.withLock { _validateResult } }
        set { lock.withLock { _validateResult = newValue } }
    }
    var validateCalls: Int { lock.withLock { _validateCalls } }
    /// Runs inside the store's card refresh, so a test can act mid document switch.
    var onAvailableIdentities: (@MainActor @Sendable () async -> Void)? {
        get { lock.withLock { _onAvailableIdentities } }
        set { lock.withLock { _onAvailableIdentities = newValue } }
    }

    init(inspect: SignatureTreeResult, validate: SignatureTreeResult) {
        _inspectResult = inspect
        _validateResult = validate
    }

    /// The validation result for one file; other files get `validateResult`.
    func setValidation(_ result: SignatureTreeResult, for url: URL) {
        lock.withLock { perURL[url] = result }
    }

    /// Lets validation finish: for one file, or (without a URL) for every file, now and later.
    /// A continuation list instead of an AsyncStream: two validations may wait at once.
    func releaseValidation(for url: URL? = nil) async {
        let resumed: [CheckedContinuation<Void, Never>] = lock.withLock {
            if let url { openURLs.insert(url) } else { allOpen = true }
            let ready = waiting.filter { allOpen || openURLs.contains($0.url) }
            waiting.removeAll { entry in allOpen || openURLs.contains(entry.url) }
            return ready.map(\.continuation)
        }
        resumed.forEach { $0.resume() }
        for _ in 0..<5 { await Task.yield() }
    }

    func availableIdentities() async -> [SigningIdentityInfo] {
        if let hook = onAvailableIdentities { await hook() }
        return []
    }
    func resolveIdentities(pin: String) async -> [SigningIdentityInfo]? { nil }
    func sign(_ request: SigningRequest) async throws -> SignedConversionResult {
        SignedConversionResult(pdfData: Data(), asicData: nil, signedAt: Date(),
                               signatureLabel: "stub", isLegallyBinding: false)
    }
    func inspectInputSignatures(in fileURLs: [URL]) async -> [URL: InputSignatureInspectionResult] { [:] }
    func inspectSignatureTree(in fileURL: URL) async -> SignatureTreeResult { inspectResult }
    func validateSignatureTree(in fileURL: URL) async -> SignatureTreeResult {
        lock.withLock { _validateCalls += 1 }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let proceed: Bool = lock.withLock {
                if allOpen || openURLs.contains(fileURL) { return true }
                waiting.append((fileURL, continuation))
                return false
            }
            if proceed { continuation.resume() }
        }
        return lock.withLock { perURL[fileURL] ?? _validateResult }
    }
}

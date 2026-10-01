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
        store.sourceURL = try file()
        await store.inspectExistingSignatures()
        let stale = store.existingValidationTask

        provider.inspectResult = .tree(SignatureTree())
        store.sourceURL = try file()
        await store.inspectExistingSignatures()
        await provider.releaseValidation()
        await stale?.value
        await store.existingValidationTask?.value

        XCTAssertEqual(provider.validateCalls, 2)
        XCTAssertEqual(store.existingSignatureState.tree, Self.validated)
        XCTAssertEqual(store.existingSignatureState.phase, .validated)
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
}

/// Validation waits until the test releases it, so phases can be observed in order.
/// Two validations may run on different threads at once, so all state sits behind a lock
/// and the credit check and the continuation hand-off happen atomically.
private final class TreeProvider: QualifiedSigningProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var _inspectResult: SignatureTreeResult
    private var _validateResult: SignatureTreeResult
    private var _validateCalls = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var credits = 0

    var inspectResult: SignatureTreeResult {
        get { lock.withLock { _inspectResult } }
        set { lock.withLock { _inspectResult = newValue } }
    }
    var validateResult: SignatureTreeResult {
        get { lock.withLock { _validateResult } }
        set { lock.withLock { _validateResult = newValue } }
    }
    var validateCalls: Int { lock.withLock { _validateCalls } }

    init(inspect: SignatureTreeResult, validate: SignatureTreeResult) {
        _inspectResult = inspect
        _validateResult = validate
    }

    /// Lets up to two validations finish (waiting ones first, later ones on arrival).
    /// A continuation list instead of an AsyncStream: two validations may wait at once.
    func releaseValidation() async {
        let resumed: [CheckedContinuation<Void, Never>] = lock.withLock {
            credits += 2
            var out: [CheckedContinuation<Void, Never>] = []
            while credits > 0, !waiting.isEmpty {
                credits -= 1
                out.append(waiting.removeFirst())
            }
            return out
        }
        resumed.forEach { $0.resume() }
        for _ in 0..<5 { await Task.yield() }
    }

    func availableIdentities() async -> [SigningIdentityInfo] { [] }
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
                if credits > 0 {
                    credits -= 1
                    return true
                }
                waiting.append(continuation)
                return false
            }
            if proceed { continuation.resume() }
        }
        return validateResult
    }
}

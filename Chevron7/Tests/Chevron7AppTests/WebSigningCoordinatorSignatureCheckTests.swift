// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
@testable import Chevron7App
import Chevron7Kit
import Chevron7TestSupport
import Chevron7WebBridge

/// The signature banner of the Safari panel, driven through the coordinator: closing the
/// panel or signing while the check still runs ends the check and removes the portal's
/// temporary copy, and the signature never waits for the structural inspection.
@MainActor
final class WebSigningCoordinatorSignatureCheckTests: XCTestCase {
    private static let signedPDF = Data("%PDF-1.7\n1 0 obj << /Type /Sig /ByteRange [0 10 20 30] >> endobj\n%%EOF".utf8)

    private var temporaryRoot: URL!

    override func setUp() async throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("web-coordinator-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    private func makeCoordinator(provider: PanelCheckProvider,
                                 transport: (any AVMHTTPTransport)? = nil) -> WebSigningCoordinator {
        let settings = makeSettingsStore()
        settings.useRealSigningProvider(provider)
        let mobile = MobileSigningCoordinator(clientFactory: {
            AVMClient(baseURL: URL(string: "https://avm.test/api/v1")!,
                      transport: transport ?? FailingAVMTransport(provider: provider))
        }, pollInterval: .milliseconds(5))
        return WebSigningCoordinator(settingsStore: settings,
                                     signedDocumentStore: SignedDocumentStore(defaults: MemoryUserDefaults(),
                                                                              trash: { _ in }),
                                     prompt: SilentPrompt(),
                                     signatureCheck: WebSigningSignatureCheck(temporaryRoot: temporaryRoot),
                                     mobileSigning: mobile)
    }

    private func request() -> WebSignRequest {
        WebSignRequest(requestID: "Signature-1", filename: "zmluva.pdf",
                       content: Self.signedPDF.base64EncodedString(),
                       payloadMimeType: "application/pdf;base64", signatureLevel: "PAdES_BASELINE_B")
    }

    private func temporaryFiles() -> [String] {
        (FileManager.default.enumerator(atPath: temporaryRoot.path)?.allObjects as? [String] ?? [])
            .filter { $0.hasSuffix(".pdf") }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }

    /// Opens the panel for a signed PDF and waits until its inspection runs.
    private func openPanel(_ coordinator: WebSigningCoordinator, provider: PanelCheckProvider)
        async throws -> Task<WebSignResponse, Error> {
        let request = request()
        let handling = Task { try await coordinator.handle(request) }
        try await waitUntil { provider.isInspecting }
        XCTAssertEqual(temporaryFiles().count, 1)
        return handling
    }

    private func insertCard(_ coordinator: WebSigningCoordinator) async {
        await coordinator.refreshIdentities()
        coordinator.pin = "123456"
    }

    func testClosingThePanelWhileTheCheckRunsEndsItAndRemovesTheCopy() async throws {
        let provider = PanelCheckProvider(holdsInspection: true)
        let coordinator = makeCoordinator(provider: provider)
        let handling = try await openPanel(coordinator, provider: provider)

        coordinator.cancel()

        let result = await handling.result
        guard case .failure(let error) = result else { return XCTFail("expected a cancellation, got \(result)") }
        XCTAssertEqual(error.localizedDescription, WebSigningBridge.cancelledMessage)
        try await waitUntil { provider.inspectionCancelled }
        XCTAssertNil(coordinator.signatureCheck.loader)
        XCTAssertNil(coordinator.signatureCheck.bannerModel)
        XCTAssertEqual(temporaryFiles(), [])
    }

    /// INSPECT and SIGN share one helper in the engine, so a signature confirmed while a
    /// large container is still inspected would wait for that inspection to finish.
    func testConfirmingWithACardEndsARunningInspectionFirst() async throws {
        let provider = PanelCheckProvider(holdsInspection: true)
        let coordinator = makeCoordinator(provider: provider)
        let handling = try await openPanel(coordinator, provider: provider)
        await insertCard(coordinator)

        await coordinator.confirm()

        let response = try await handling.value
        XCTAssertEqual(response.signedBy, "Ján Novák")
        XCTAssertEqual(provider.inspectionCancelledWhenSigning, true)
        XCTAssertEqual(temporaryFiles(), [])
    }

    func testConfirmingWithAPhoneEndsARunningInspectionFirst() async throws {
        let provider = PanelCheckProvider(holdsInspection: true)
        let coordinator = makeCoordinator(provider: provider)
        let handling = try await openPanel(coordinator, provider: provider)

        await coordinator.confirmViaMobile(method: .autogramMobile)

        XCTAssertEqual(provider.inspectionCancelledWhenSigning, true)
        // The phone failed here (no relay), so the panel stays open with its banner gone
        // rather than the orange "could not check" of an inspection cut short.
        XCTAssertNotNil(coordinator.errorText)
        XCTAssertNil(coordinator.signatureCheck.bannerModel)
        coordinator.cancel()
        _ = await handling.result
        XCTAssertEqual(temporaryFiles(), [])
    }

    /// A finished inspection has handed over to validation, which runs on its own engine
    /// session; confirming leaves it alone, and the finished signature ends it.
    func testSignatureCompletingWhileValidationRunsEndsTheValidation() async throws {
        let provider = PanelCheckProvider(holdsInspection: false)
        let coordinator = makeCoordinator(provider: provider)
        let handling = Task { [request = request()] in try await coordinator.handle(request) }
        try await waitUntil { provider.isValidating }
        XCTAssertEqual(coordinator.signatureCheck.bannerModel?.tone, .checking)
        await insertCard(coordinator)

        await coordinator.confirm()

        let response = try await handling.value
        XCTAssertEqual(response.signedBy, "Ján Novák")
        XCTAssertEqual(provider.validationCancelledWhenSigning, false)
        try await waitUntil { provider.validationCancelled }
        XCTAssertNil(coordinator.signatureCheck.loader)
        XCTAssertEqual(temporaryFiles(), [])
    }
}

/// Records how the panel's check and the signature interleave. The inspection (when held)
/// and the validation run until they are cancelled, as on a large container.
private final class PanelCheckProvider: QualifiedSigningProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let holdsInspection: Bool
    private var waiters: [String: CheckedContinuation<Void, Never>] = [:]
    private var cancelled: Set<String> = []
    private var running: Set<String> = []
    private var inspectionAtSign: Bool?
    private var validationAtSign: Bool?

    init(holdsInspection: Bool) {
        self.holdsInspection = holdsInspection
    }

    var isInspecting: Bool { lock.withLock { running.contains("inspect") } }
    var isValidating: Bool { lock.withLock { running.contains("validate") } }
    var inspectionCancelled: Bool { lock.withLock { cancelled.contains("inspect") } }
    var validationCancelled: Bool { lock.withLock { cancelled.contains("validate") } }
    var inspectionCancelledWhenSigning: Bool? { lock.withLock { inspectionAtSign } }
    var validationCancelledWhenSigning: Bool? { lock.withLock { validationAtSign } }

    /// The phone path has no `sign` here; its relay call marks the moment instead.
    func noteSigning() {
        lock.withLock {
            inspectionAtSign = cancelled.contains("inspect")
            validationAtSign = cancelled.contains("validate")
        }
    }

    private func hold(_ key: String) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow: Bool = lock.withLock {
                    running.insert(key)
                    if cancelled.contains(key) { return true }
                    waiters[key] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let waiter: CheckedContinuation<Void, Never>? = lock.withLock {
                cancelled.insert(key)
                return waiters.removeValue(forKey: key)
            }
            waiter?.resume()
        }
        lock.withLock { _ = running.remove(key) }
    }

    func availableIdentities() async -> [SigningIdentityInfo] {
        [SigningIdentityInfo(id: "card-1", label: "Ján Novák", issuerSummary: "Testovacia CA",
                             isQualified: true, requiresPIN: true)]
    }
    func resolveIdentities(pin: String) async -> [SigningIdentityInfo]? { nil }
    func sign(_ request: SigningRequest) async throws -> SignedConversionResult {
        noteSigning()
        return SignedConversionResult(pdfData: Data("%PDF-1.7 signed".utf8), asicData: nil, signedAt: Date(),
                                      signatureLabel: "Ján Novák", isLegallyBinding: true)
    }
    func inspectInputSignatures(in fileURL: URL) async -> InputSignatureInspectionResult {
        .unavailable(detail: "")
    }
    func inspectInputSignatures(in fileURLs: [URL]) async -> [URL: InputSignatureInspectionResult] { [:] }
    func inspectSignatureTree(in fileURL: URL) async -> SignatureTreeResult {
        guard holdsInspection else {
            return .tree(SignatureTree(signatures: [
                DocumentSignatureInfo(id: "S-1", signerDisplayName: "Ján Novák", state: .indeterminate)]))
        }
        await hold("inspect")
        return .failed("Kontrola podpisov bola prerušená.")
    }
    func validateSignatureTree(in fileURL: URL) async -> SignatureTreeResult {
        await hold("validate")
        return .failed("Overenie bolo prerušené.")
    }
}

/// The relay is unreachable; the call itself marks when the phone signature began.
private struct FailingAVMTransport: AVMHTTPTransport {
    let provider: PanelCheckProvider

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        provider.noteSigning()
        throw URLError(.notConnectedToInternet)
    }
}

@MainActor
private final class SilentPrompt: WebSigningPromptPresenting {
    func show(coordinator: WebSigningCoordinator) {}
    func hide() {}
    func focus() {}
    func beginMiddlewareInput() {}
    func endMiddlewareInput() {}
}

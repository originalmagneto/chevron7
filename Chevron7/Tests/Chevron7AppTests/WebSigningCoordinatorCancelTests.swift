// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
@testable import Chevron7App
import Chevron7Kit
import Chevron7TestSupport
import Chevron7WebBridge

/// pfseform.financnasprava.sk, 2026-10-15: an eID signature waited minutes for a BOK window
/// that never appeared, Zrušiť closed the panel while the engine kept waiting, and every
/// request in the meantime was refused as "Chevron7 už spracúva inú požiadavku na podpis",
/// shown by the portal beneath the floating panel.
@MainActor
final class WebSigningCoordinatorCancelTests: XCTestCase {
    private func makeCoordinator(provider: HangingCardProvider, prompt: CountingPrompt) -> WebSigningCoordinator {
        let settings = makeSettingsStore()
        settings.useRealSigningProvider(provider)
        return WebSigningCoordinator(settingsStore: settings,
                                     signedDocumentStore: SignedDocumentStore(defaults: MemoryUserDefaults(),
                                                                              trash: { _ in }),
                                     prompt: prompt)
    }

    private func request() -> WebSignRequest {
        WebSignRequest(requestID: "Signature-1", filename: "zmluva.pdf",
                       content: Data("%PDF-1.7\n%%EOF".utf8).base64EncodedString(),
                       payloadMimeType: "application/pdf;base64", signatureLevel: "PAdES_BASELINE_B")
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition())
    }

    private func open(_ coordinator: WebSigningCoordinator) async throws -> Task<WebSignResponse, Error> {
        let handling = Task { [request = request()] in try await coordinator.handle(request) }
        try await waitUntil { coordinator.pending != nil }
        await coordinator.refreshIdentities()
        coordinator.pin = "123456"
        return handling
    }

    func testClosingThePanelWhileTheCardSignsStopsTheEngineSoTheNextRequestOpens() async throws {
        let provider = HangingCardProvider()
        let coordinator = makeCoordinator(provider: provider, prompt: CountingPrompt())
        let first = try await open(coordinator)
        let signing = Task { await coordinator.confirm() }
        try await waitUntil { provider.isSigning }

        coordinator.cancel()

        let result = await first.result
        guard case .failure(let error) = result else { return XCTFail("expected a cancellation, got \(result)") }
        XCTAssertEqual(error.localizedDescription, WebSigningBridge.cancelledMessage)
        try await waitUntil { !coordinator.isWorking }
        // Without the stop the engine call never ends; fail here rather than hang.
        guard !coordinator.isWorking else { return }
        await signing.value
        XCTAssertEqual(provider.cancelSigningCalls, 1)

        let second = try await open(coordinator)
        XCTAssertNotNil(coordinator.pending)
        coordinator.cancel()
        _ = await second.result
    }

    func testClosingThePanelBeforeSigningLeavesTheEngineAlone() async throws {
        let provider = HangingCardProvider()
        let coordinator = makeCoordinator(provider: provider, prompt: CountingPrompt())
        let first = try await open(coordinator)

        coordinator.cancel()
        _ = await first.result
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(provider.cancelSigningCalls, 0)
    }

    /// The portal draws its error for the refused request beneath the floating panel.
    func testARequestRefusedWhileThePanelIsOpenBringsThePanelForward() async throws {
        let provider = HangingCardProvider()
        let prompt = CountingPrompt()
        let coordinator = makeCoordinator(provider: provider, prompt: prompt)
        let first = try await open(coordinator)
        XCTAssertEqual(prompt.showCount, 1)

        do {
            _ = try await coordinator.handle(request())
            XCTFail("a second request must be refused while the panel is open")
        } catch {
            XCTAssertEqual(error.localizedDescription, WebSigningCoordinator.Failure.busy.errorDescription)
        }

        XCTAssertEqual(prompt.showCount, 2)
        coordinator.cancel()
        _ = await first.result
    }
}

/// A card whose `sign` waits until `cancelSigning`, like an eID waiting for a BOK window
/// that never appears.
private final class HangingCardProvider: QualifiedSigningProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Void, Never>?
    private var signing = false
    private var stopped = false
    private var cancelCalls = 0

    var isSigning: Bool { lock.withLock { signing } }
    var cancelSigningCalls: Int { lock.withLock { cancelCalls } }

    func availableIdentities() async -> [SigningIdentityInfo] {
        [SigningIdentityInfo(id: "card-1", label: "Ján Novák", issuerSummary: "Testovacia CA",
                             isQualified: true, requiresPIN: true)]
    }
    func resolveIdentities(pin: String) async -> [SigningIdentityInfo]? { nil }
    func sign(_ request: SigningRequest) async throws -> SignedConversionResult {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow: Bool = lock.withLock {
                signing = true
                if stopped { return true }
                waiter = continuation
                return false
            }
            if resumeNow { continuation.resume() }
        }
        lock.withLock { signing = false }
        throw CancellationError()
    }
    func cancelSigning() async {
        let pending: CheckedContinuation<Void, Never>? = lock.withLock {
            cancelCalls += 1
            stopped = true
            defer { waiter = nil }
            return waiter
        }
        pending?.resume()
    }
    func inspectInputSignatures(in fileURL: URL) async -> InputSignatureInspectionResult {
        .unavailable(detail: "")
    }
    func inspectInputSignatures(in fileURLs: [URL]) async -> [URL: InputSignatureInspectionResult] { [:] }
    func inspectSignatureTree(in fileURL: URL) async -> SignatureTreeResult {
        .tree(SignatureTree(signatures: [], documents: []))
    }
    func validateSignatureTree(in fileURL: URL) async -> SignatureTreeResult {
        .tree(SignatureTree(signatures: [], documents: []))
    }
}

@MainActor
private final class CountingPrompt: WebSigningPromptPresenting {
    private(set) var showCount = 0
    func show(coordinator: WebSigningCoordinator) { showCount += 1 }
    func hide() {}
    func focus() {}
    func beginMiddlewareInput() {}
    func endMiddlewareInput() {}
}

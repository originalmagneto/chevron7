// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import XCTest
import Chevron7Kit
@testable import Chevron7App

@MainActor
final class ZakoCertificateResolutionTests: XCTestCase {
    func testRefreshIdentitiesResolvesCertificatesWhenPINIsPresent() async {
        let settingsStore = makeSettingsStore()
        let provider = CertificateResolutionProbeProvider()
        settingsStore.useRealSigningProvider(provider)
        let store = ZakoSessionStore(settingsStore: settingsStore)
        store.signingPIN = "1234"

        await store.refreshIdentities()

        XCTAssertEqual(provider.resolvedPIN, "1234")
        XCTAssertEqual(store.identities.map(\.id), ["engine-cert:resolved"])
        XCTAssertEqual(store.selectedIdentityID, "engine-cert:resolved")
    }

    func testChangingPINDuringResolutionDoesNotPublishStaleCertificate() async {
        let settingsStore = makeSettingsStore()
        let provider = CertificateResolutionProbeProvider()
        provider.suspendFirstResolution = true
        settingsStore.useRealSigningProvider(provider)
        let store = ZakoSessionStore(settingsStore: settingsStore)
        store.signingPIN = "old-pin"

        let resolutionTask = Task { @MainActor in
            await store.resolveCertificateForAuthorization(force: true)
        }
        await provider.waitForFirstResolution()
        store.signingPIN = "new-pin"
        provider.releaseFirstResolution()
        await resolutionTask.value

        XCTAssertEqual(provider.resolvedPINs, ["old-pin", "new-pin"])
        XCTAssertEqual(store.identities.map(\.id), ["engine-cert:new-pin"])
        XCTAssertEqual(store.selectedIdentityID, "engine-cert:new-pin")
    }
}

private final class CertificateResolutionProbeProvider: QualifiedSigningProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var firstResolutionContinuation: CheckedContinuation<Void, Never>?
    private var firstResolutionStarted = false
    var suspendFirstResolution = false
    private(set) var resolvedPINs: [String] = []

    var resolvedPIN: String? {
        lock.withLock { resolvedPINs.last }
    }

    func availableIdentities() async -> [SigningIdentityInfo] {
        [SigningIdentityInfo(
            id: "engine:eid",
            label: "Podpisová karta",
            issuerSummary: "Zadajte PIN pre načítanie certifikátov",
            isQualified: true,
            requiresPIN: true)]
    }

    func waitForFirstResolution() async {
        while !lock.withLock({ firstResolutionStarted }) {
            await Task.yield()
        }
    }

    func releaseFirstResolution() {
        let continuation = lock.withLock {
            defer { firstResolutionContinuation = nil }
            return firstResolutionContinuation
        }
        continuation?.resume()
    }

    func resolveIdentities(pin: String) async -> [SigningIdentityInfo]? {
        let shouldSuspend = lock.withLock {
            resolvedPINs.append(pin)
            if resolvedPINs.count == 1 {
                if !suspendFirstResolution { firstResolutionStarted = true }
                return suspendFirstResolution
            }
            return false
        }
        if shouldSuspend {
            await withCheckedContinuation { continuation in
                lock.withLock {
                    firstResolutionContinuation = continuation
                    // A waiter may release as soon as it observes this flag.
                    firstResolutionStarted = true
                }
            }
        }
        let identityID = pin == "1234" ? "engine-cert:resolved" : "engine-cert:\(pin)"
        return [SigningIdentityInfo(
            id: identityID,
            label: "Mandátny certifikát",
            issuerSummary: "SAK",
            isMandateCertificate: true,
            isQualified: true)]
    }

    func sign(_ request: SigningRequest) async throws -> SignedConversionResult {
        throw SigningError.identityUnavailable
    }
}

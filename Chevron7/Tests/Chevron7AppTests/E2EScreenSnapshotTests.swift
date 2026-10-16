// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import AppKit
import Chevron7Kit
import Chevron7TestSupport
import SwiftUI
import XCTest
@testable import Chevron7App

/// Renders the four E→E ZaKo screens to PNG for a before/after review. Runs only when
/// `CHEVRON7_SNAPSHOT_DIR` names an output folder; otherwise it is skipped.
@MainActor
final class E2EScreenSnapshotTests: XCTestCase {
    private var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["CHEVRON7_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0) }
    }

    func testRenderE2EScreens() async throws {
        guard let outputDirectory else { throw XCTSkip("Set CHEVRON7_SNAPSHOT_DIR to render the screens.") }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let settingsStore = makeSettingsStore()
        let profile = AdvocateProfile(fullName: "Mgr. Ján Advokát", position: "advokát", registrationNumber: "1042",
                                      ico: "42249180", officeName: "Advokátska kancelária Advokát")
        settingsStore.settings.profiles = [profile]
        settingsStore.settings.activeProfileID = profile.id
        settingsStore.ezzkAccountController.setMode(.test)
        let directory = makeTemporaryDirectory("e2e-snapshots")
        let a4 = CGSize(width: 595, height: 842)
        let data = TestPDFBuilderApp.build(pages: [
            (a4, { ctx, size in
                TestPDFBuilderApp.text("Zmluva o pôžičke", at: CGPoint(x: 60, y: size.height - 90), size: 18)(ctx, size)
                TestPDFBuilderApp.text("uzavretá podľa § 657 Občianskeho zákonníka", at: CGPoint(x: 60, y: size.height - 120), size: 11)(ctx, size)
            })
        ])
        let source = directory.appendingPathComponent("Zmluva o pôžičke.pdf")
        try data.write(to: source)
        var client = E2EEvidenceFixtures.Signature()
        client.signer = "Ján Klient"
        client.signedRevisionLength = data.count
        var lender = E2EEvidenceFixtures.Signature()
        lender.id = "S-2"
        lender.signer = "Mária Veriteľka"
        lender.signedRevisionLength = data.count
        var facts = E2EEvidenceFixtures.PDF()
        facts.declaredPdfaPart = 2
        facts.pdfaCompliant = true
        let provider = SnapshotEvidenceProvider(payload: E2EEvidenceFixtures.payload(signatures: [client, lender], pdf: facts))
        settingsStore.useRealSigningProvider(provider)
        let store = ZakoSessionStore(settingsStore: settingsStore,
                                     exampleBank: ExampleBank(directory: makeTemporaryDirectory("e2e-snapshot-bank")))
        store.direction = .electronicToElectronic

        render(ZakoFlowView(store: store), named: "1-intake", to: outputDirectory)

        await store.loadElectronicOriginal(at: source)
        store.isVerifying = true
        render(ZakoFlowView(store: store), named: "2a-verification-running", to: outputDirectory)
        store.isVerifying = false
        render(ZakoFlowView(store: store), named: "2b-verification", to: outputDirectory)

        store.step = .attestation
        render(ZakoFlowView(store: store), named: "3-dolozka", to: outputDirectory)

        store.attestation.originalDocumentTypeLabel = "Zmluva"
        store.identities = [SigningIdentityInfo(id: "card", label: "Mgr. Ján Advokát (OPRÁVNENIE 1042)",
                                                issuerSummary: "I.CA Qualified 2 CA", isMandateCertificate: true,
                                                isQualified: true)]
        store.selectedIdentityID = "card"
        store.lastError = E2EFormIssue.from(FormSchemaValidator.Failure.invalid(
            details: "riadok 1: element UsedDevice: Schemas validity error : Element '{urn:x}UsedDevice': [facet 'minLength'] The value has a length of '0'")).advice
        store.step = .authorize
        render(ZakoFlowView(store: store), named: "4-autorizacia", to: outputDirectory)
    }

    private func render<V: View>(_ view: V, named name: String, to directory: URL) {
        let size = NSSize(width: 1100, height: 720)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
    }
}

private final class SnapshotEvidenceProvider: QualifiedSigningProviding, @unchecked Sendable {
    let payload: Data
    init(payload: Data) { self.payload = payload }
    func availableIdentities() async -> [SigningIdentityInfo] { [] }
    func conversionEvidence(for fileURL: URL) async throws -> ConversionEvidence {
        try ConversionEvidence.decode(payloadJSON: payload)
    }
    func sign(_ request: SigningRequest) async throws -> SignedConversionResult {
        try await DemoSigningProvider().sign(request)
    }
}

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

    /// The verification screen of a container with three files: names, formats, pages, the
    /// signers of each file, the embedded-files and changed-after-signing notes, and a PDF's own
    /// signature under its file.
    func testRenderMultiFileVerification() async throws {
        guard let outputDirectory else { throw XCTSkip("Set CHEVRON7_SNAPSHOT_DIR to render the screens.") }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let settingsStore = makeSettingsStore()
        settingsStore.ezzkAccountController.setMode(.test)
        let directory = makeTemporaryDirectory("e2e-multi-snapshots")
        let a4 = CGSize(width: 595, height: 842)
        let pdf = TestPDFBuilderApp.build(pages: [
            (a4, { ctx, size in
                TestPDFBuilderApp.text("Zmluva o pôžičke", at: CGPoint(x: 60, y: size.height - 90), size: 18)(ctx, size)
            }),
            (a4, { ctx, size in
                TestPDFBuilderApp.text("Strana 2", at: CGPoint(x: 60, y: size.height - 90), size: 18)(ctx, size)
            })
        ])
        var zmluva = E2EEvidenceFixtures.DataObject(name: "Zmluva o pôžičke.pdf", bytes: pdf)
        zmluva.coveredBy = ["C-1"]
        zmluva.pages = 2
        zmluva.embeddedFileNames = ["splatkovy-kalendar.xlsx"]
        var own = E2EEvidenceFixtures.PDF()
        own.changesAfterLastSignature = ["ANNOTATION"]
        zmluva.nestedPDF = own
        var pades = E2EEvidenceFixtures.Signature()
        pades.id = "P-1"
        pades.signer = "Mária Veriteľka"
        pades.signedRevisionLength = pdf.count - 10
        pades.signatureValue = Data("pades-P-1".utf8)
        zmluva.nestedSignatures = [pades]
        var scan = E2EEvidenceFixtures.DataObject(
            name: "Príloha 1 - sken.png",
            bytes: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0x50, count: 40))
        scan.kind = "png"
        scan.coveredBy = ["C-1"]
        var photo = E2EEvidenceFixtures.DataObject(
            name: "Príloha 2 - fotografia.jpg",
            bytes: Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0x4A, count: 40))
        photo.kind = "jpeg"
        photo.coveredBy = ["C-1"]
        let objects = [zmluva, scan, photo]
        let source = directory.appendingPathComponent("Spis klienta.asice")
        try ASiCEPackager().package(files: objects.map { .init(path: $0.name, data: $0.bytes) }).write(to: source)
        var container = E2EEvidenceFixtures.Signature()
        container.id = "C-1"
        container.format = "XAdES-BASELINE-T"
        container.signer = "Ján Klient"
        container.signatureValue = Data("container-C-1".utf8)
        var facts = E2EEvidenceFixtures.PDF()
        facts.asicDataObjectCount = objects.count
        facts.asicDataObjectName = zmluva.name
        let provider = SnapshotEvidenceProvider(payload: E2EEvidenceFixtures.payload(
            signatures: [container], pdf: facts, dataObjects: objects))
        settingsStore.useRealSigningProvider(provider)
        let store = ZakoSessionStore(settingsStore: settingsStore,
                                     exampleBank: ExampleBank(directory: makeTemporaryDirectory("e2e-multi-snapshot-bank")))
        store.direction = .electronicToElectronic

        await store.loadElectronicOriginal(at: source)
        XCTAssertNil(store.verificationError)
        XCTAssertEqual(store.electronicOriginal?.files.count, 3)
        store.attestation.originalDocumentTypeLabels[scan.name] = "Iný dokument"
        render(ZakoFlowView(store: store), named: "2c-verification-multi-file", to: outputDirectory)
        render(ZakoFlowView(store: store), named: "2d-verification-multi-file-tall", to: outputDirectory,
               size: NSSize(width: 1100, height: 1500))
    }

    private func render<V: View>(_ view: V, named name: String, to directory: URL,
                                 size: NSSize = NSSize(width: 1100, height: 720)) {
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

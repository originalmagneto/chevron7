// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Kit
import Chevron7TestSupport
import CryptoKit
import Foundation
import PDFKit
import XCTest
@testable import Chevron7App

/// ZaKo E→E end to end in Demo: verification of the client's signatures (engine evidence from
/// fixtures), the clause and record, the client container, the register row and the record.
@MainActor
final class ZakoE2EFlowTests: XCTestCase {
    private func requireXMLLint() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xmllint") else {
            throw XCTSkip("xmllint is needed for schema validation of the clause and the record.")
        }
    }

    /// A signed client PDF on disk and the provider that "validates" it with `signature`.
    private func makeStore(signatures: [E2EEvidenceFixtures.Signature]? = nil,
                           pdf facts: E2EEvidenceFixtures.PDF = E2EEvidenceFixtures.PDF()) throws
        -> (ZakoSessionStore, EvidenceProvider, URL) {
        let settingsStore = makeSettingsStore()
        let directory = makeTemporaryDirectory("e2e-flow")
        let a4 = CGSize(width: 595, height: 842)
        let data = TestPDFBuilderApp.build(pages: [
            (a4, { ctx, size in TestPDFBuilderApp.text("Zmluva o pôžičke", at: CGPoint(x: 60, y: size.height - 90), size: 16)(ctx, size) })
        ])
        let source = directory.appendingPathComponent("zmluva.pdf")
        try data.write(to: source)
        var signature = E2EEvidenceFixtures.Signature()
        signature.signedRevisionLength = data.count
        let provider = EvidenceProvider(payload: E2EEvidenceFixtures.payload(signatures: signatures ?? [signature], pdf: facts),
                                        sourceSize: data.count)
        settingsStore.useRealSigningProvider(provider)
        let original = settingsStore.settings
        addTeardownBlock { await MainActor.run { settingsStore.settings = original } }
        settingsStore.settings.learnFromReviews = false
        let store = ZakoSessionStore(settingsStore: settingsStore,
                                     exampleBank: ExampleBank(directory: makeTemporaryDirectory("e2e-bank")))
        store.direction = .electronicToElectronic
        return (store, provider, source)
    }

    private func prepareForAuthorization(_ store: ZakoSessionStore) {
        store.attestation.originalDocumentTypeLabel = "zmluva o pôžičke"
        store.attestation.performingPerson = AdvocateProfile(fullName: "JUDr. Test Testovací", position: "advokát",
                                                             registrationNumber: "4321", ico: "35764102")
        store.attestation.usedDeviceDescription = "Chevron7"
        store.identities = [SigningIdentityInfo(id: "demo", label: "Test mandátny certifikát", issuerSummary: "Test CA",
                                                isMandateCertificate: true, isQualified: true)]
        store.selectedIdentityID = "demo"
        store.includeQualifiedTimestamp = false
        store.step = .authorize
    }

    func testE2ESkipsAnalysis() async throws {
        let (store, _, source) = try makeStore()
        await store.loadElectronicOriginal(at: source)
        XCTAssertEqual(store.step, .verification)
        XCTAssertNil(store.verificationError)
        XCTAssertEqual(store.e2eDecision, .ready)
        XCTAssertTrue(store.canContinueFromVerification)
        XCTAssertTrue(store.securityElements.isEmpty, "no scan analysis for an electronic original")
        XCTAssertEqual(store.attestation.originalDocumentName, "zmluva.pdf")
    }

    func testInvalidSignatureCannotContinue() async throws {
        var invalid = E2EEvidenceFixtures.Signature()
        invalid.indication = "TOTAL_FAILED"
        let (store, provider, source) = try makeStore(signatures: [invalid])
        provider.fixRevisionLengths = true
        await store.loadElectronicOriginal(at: source)
        guard case .blocked = store.e2eDecision else { return XCTFail("expected blocked, got \(String(describing: store.e2eDecision))") }
        XCTAssertFalse(store.canContinueFromVerification)
    }

    func testUndeterminedNeedsConfirmationBeforeAttestation() async throws {
        var undetermined = E2EEvidenceFixtures.Signature()
        undetermined.indication = "INDETERMINATE"
        let (store, provider, source) = try makeStore(signatures: [undetermined])
        provider.fixRevisionLengths = true
        await store.loadElectronicOriginal(at: source)
        XCTAssertFalse(store.canContinueFromVerification)
        store.confirmUndetermined()
        XCTAssertTrue(store.canContinueFromVerification)
    }

    func testReverificationReplacesEvidenceBeforeAuthorization() async throws {
        var undetermined = E2EEvidenceFixtures.Signature()
        undetermined.indication = "INDETERMINATE"
        let (store, provider, source) = try makeStore(signatures: [undetermined])
        provider.fixRevisionLengths = true
        await store.loadElectronicOriginal(at: source)
        store.confirmUndetermined()
        XCTAssertTrue(store.canContinueFromVerification)

        var invalid = E2EEvidenceFixtures.Signature()
        invalid.indication = "TOTAL_FAILED"
        provider.payload = E2EEvidenceFixtures.payload(signatures: [invalid])
        await store.verifyElectronicOriginal()

        XCTAssertFalse(store.undeterminedConfirmed, "a new verification needs a new confirmation")
        XCTAssertFalse(store.canContinueFromVerification)
        XCTAssertEqual(store.electronicOriginal?.authorizations.first?.state, .invalid)
    }

    func testDemoE2EKeepsPdfaByteIdentical() async throws {
        try requireXMLLint()
        var facts = E2EEvidenceFixtures.PDF()
        facts.declaredPdfaPart = 2
        facts.pdfaCompliant = true
        let (store, provider, source) = try makeStore(pdf: facts)
        await store.loadElectronicOriginal(at: source)
        prepareForAuthorization(store)

        await store.authorizeAndSign()

        XCTAssertEqual(store.step, .done, store.lastError ?? "")
        XCTAssertEqual(provider.signedKinds, [.client, .record])
        XCTAssertEqual(provider.clientSource, try Data(contentsOf: source), "the client's PDF goes in unchanged")
        let row = try XCTUnwrap(store.evidenceStore.record(id: store.currentRecordID))
        XCTAssertEqual(row.direction, .electronicToElectronic)
        XCTAssertTrue(row.attestationXML.contains(OfficialForm.recordE2E_1_0.namespace))
        XCTAssertEqual(row.fingerprintSHA256Hex,
                       SHA256.hash(data: try Data(contentsOf: source)).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(row.validationEvidenceSource, "Chevron7 (DSS 6.4)")
        XCTAssertNotNil(store.evidenceStore.validationEvidenceData(for: row))
        XCTAssertNotNil(row.recordContainerPath)
    }

    func testDemoE2EConvertsPlainPdf() async throws {
        try requireXMLLint()
        let (store, provider, source) = try makeStore()
        let converted = Data("%PDF-1.7 converted".utf8)
        store.pdfaFromSignedRunner = PdfaFromSignedRunner(launch: { arguments in
            try converted.write(to: URL(fileURLWithPath: arguments[2]))
            return (0, "")
        })
        await store.loadElectronicOriginal(at: source)
        prepareForAuthorization(store)

        await store.authorizeAndSign()

        XCTAssertEqual(store.step, .done, store.lastError ?? "")
        XCTAssertEqual(provider.clientSource, converted)
        let row = try XCTUnwrap(store.evidenceStore.record(id: store.currentRecordID))
        XCTAssertEqual(row.fingerprintSHA256Hex, SHA256.hash(data: converted).map { String(format: "%02x", $0) }.joined())
    }

    func testNotCompliantConversionOffersRasterAndSpendsNoSignature() async throws {
        try requireXMLLint()
        let (store, provider, source) = try makeStore()
        store.pdfaFromSignedRunner = PdfaFromSignedRunner(launch: { _ in (3, "font") })
        await store.loadElectronicOriginal(at: source)
        prepareForAuthorization(store)

        await store.authorizeAndSign()

        XCTAssertTrue(store.rasterConversionOffered)
        XCTAssertEqual(provider.signedKinds, [])
        XCTAssertNotEqual(store.step, .done)
    }

    func testProductionWithoutQualifiedReportIsRefusedBeforeAnyNumber() async throws {
        let (store, provider, source) = try makeStore()
        await store.loadElectronicOriginal(at: source)
        prepareForAuthorization(store)
        store.settingsStore.ezzkAccountController.setMode(.production)
        defer { store.settingsStore.ezzkAccountController.setMode(.demo) }

        XCTAssertFalse(store.canContinueFromVerification)
        await store.authorizeElectronicOriginal(viaMobile: false, ezzkMode: .production)

        XCTAssertEqual(store.lastError, ZakoSessionStore.e2eNeedsQualifiedValidationMessage)
        XCTAssertNil(store.attestation.evidenceNumber, "no number is spent on a refusal")
        XCTAssertEqual(provider.signedKinds, [])
    }

    func testP2EFlowStillStartsWithAnalysis() async throws {
        let (store, _, source) = try makeStore()
        store.direction = .paperToElectronic
        await store.loadDocument(at: source)
        XCTAssertEqual(store.step, .analysis)
        XCTAssertNil(store.electronicOriginal)
    }
}

/// Answers EVIDENCE with a fixture payload and signs with the Demo provider, recording what it signed.
private final class EvidenceProvider: QualifiedSigningProviding, @unchecked Sendable {
    enum Kind: Equatable { case record, client }
    private let lock = NSLock()
    private let demo = DemoSigningProvider()
    nonisolated(unsafe) var payload: Data
    /// Rewrites every signature's revision length to the source size before decoding.
    nonisolated(unsafe) var fixRevisionLengths = false
    let sourceSize: Int
    private var kinds: [Kind] = []
    private var client: Data?

    init(payload: Data, sourceSize: Int) {
        self.payload = payload
        self.sourceSize = sourceSize
    }

    var signedKinds: [Kind] { lock.withLock { kinds } }
    var clientSource: Data? { lock.withLock { client } }

    func availableIdentities() async -> [SigningIdentityInfo] { [] }

    func conversionEvidence(for fileURL: URL) async throws -> ConversionEvidence {
        var data = payload
        if fixRevisionLengths,
           var json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           var evidence = json["evidence"] as? [String: Any],
           var signatures = evidence["signatures"] as? [[String: Any]] {
            for index in signatures.indices { signatures[index]["signedRevisionLength"] = sourceSize }
            evidence["signatures"] = signatures
            json["evidence"] = evidence
            data = try JSONSerialization.data(withJSONObject: json)
        }
        return try ConversionEvidence.decode(payloadJSON: data)
    }

    func sign(_ request: SigningRequest) async throws -> SignedConversionResult {
        lock.withLock {
            kinds.append(request.signsAsRecordContainer ? .record : .client)
            if !request.signsAsRecordContainer { client = request.pdfData }
        }
        var local = request
        local.includeTimestamp = false
        return try await demo.sign(local)
    }
}

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
        XCTAssertEqual(row.clientOutput, .asicContainer, "a new row names its output")
        XCTAssertNil(row.revisionOneLength)
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

    func testProductionIsLockedUntilTheLiveCheck() async throws {
        let (store, provider, source) = try makeStore()
        await store.loadElectronicOriginal(at: source)
        prepareForAuthorization(store)
        XCTAssertFalse(E2EProductionPolicy.enabled)
        await store.authorizeElectronicOriginal(viaMobile: false, ezzkMode: .production)
        XCTAssertEqual(store.lastError, E2EProductionPolicy.refusalMessage)
        XCTAssertNil(store.attestation.evidenceNumber)
        XCTAssertEqual(provider.signedKinds, [])
    }

    func testProductionWithoutQualifiedReportIsRefusedBeforeAnyNumber() async throws {
        try XCTSkipUnless(E2EProductionPolicy.enabled, "production E→E is locked until the live check")
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

    /// The owner's first live test (1.10.0): UsedDevice was empty and the profile missing,
    /// so the record failed its schema after a number had been allocated.
    func testOpeningFillsProfileAndUsedDevice() async throws {
        let (store, _, source) = try makeStore()
        let profile = AdvocateProfile(fullName: "Mgr. Ján Advokát", position: "advokát", registrationNumber: "1042",
                                      ico: "42249180", officeName: "Advokátska kancelária")
        store.settingsStore.settings.profiles = [profile]
        store.settingsStore.settings.activeProfileID = profile.id

        await store.loadElectronicOriginal(at: source)

        XCTAssertEqual(store.attestation.performingPerson.fullName, "Mgr. Ján Advokát")
        XCTAssertEqual(store.attestation.performingPerson.ico, "42249180")
        XCTAssertTrue(store.attestation.usedDeviceDescription.hasPrefix("Chevron7"))
    }

    func testEndToEndRecordCarriesEveryRequiredElement() async throws {
        try requireXMLLint()
        let (store, _, source) = try makeStore()
        let profile = AdvocateProfile(fullName: "Mgr. Ján Advokát", position: "advokát", registrationNumber: "1042",
                                      ico: "42249180", officeName: "Advokátska kancelária")
        store.settingsStore.settings.profiles = [profile]
        store.settingsStore.settings.activeProfileID = profile.id
        store.pdfaFromSignedRunner = PdfaFromSignedRunner(launch: { arguments in
            try Data("%PDF-1.7 converted".utf8).write(to: URL(fileURLWithPath: arguments[2]))
            return (0, "")
        })
        await store.loadElectronicOriginal(at: source)
        store.attestation.originalDocumentTypeLabel = "zmluva"
        store.identities = [SigningIdentityInfo(id: "demo", label: "Test mandátny certifikát", issuerSummary: "Test CA",
                                                isMandateCertificate: true, isQualified: true)]
        store.selectedIdentityID = "demo"
        store.includeQualifiedTimestamp = false

        await store.authorizeAndSign()

        XCTAssertEqual(store.step, .done, store.lastError ?? "")
        XCTAssertTrue(store.validationErrors.isEmpty, "no P→E rule reaches E→E: \(store.validationErrors)")
        let row = try XCTUnwrap(store.evidenceStore.record(id: store.currentRecordID))
        for element in ["UsedDevice", "OriginalDocumentType", "GivenName", "FamilyName", "Position", "ValidityVerificationResult",
                        "AuthorizationLocation", "PersonID", "ConversionExecutionDateTime"] {
            let value = row.attestationXML.components(separatedBy: "<\(element)>").dropFirst().first?
                .components(separatedBy: "</").first ?? ""
            XCTAssertFalse(value.isEmpty, "\(element) is empty in the record")
        }
        XCTAssertNoThrow(try FormSchemaValidator().validate(Data(row.attestationXML.utf8), against: .recordE2E_1_0))
    }

    func testFormErrorSpendsNoNumber() async throws {
        try requireXMLLint()
        let (store, provider, source) = try makeStore()
        store.pdfaFromSignedRunner = PdfaFromSignedRunner(launch: { arguments in
            try Data("%PDF-1.7 converted".utf8).write(to: URL(fileURLWithPath: arguments[2]))
            return (0, "")
        })
        await store.loadElectronicOriginal(at: source)
        prepareForAuthorization(store)
        store.attestation.performingPerson.fullName = "Novák"

        await store.authorizeAndSign()

        XCTAssertNil(store.attestation.evidenceNumber, "a form error must not cost an evidence number")
        XCTAssertEqual(provider.signedKinds, [])
        XCTAssertNotNil(store.lastError)
        XCTAssertFalse(store.lastError?.contains("Schemas validity error") == true, "no libxml text for the advocate")
    }

    func testVerificationStaysThroughAuthorizationAndNoP2EWarnings() async throws {
        let (store, _, source) = try makeStore()
        await store.loadElectronicOriginal(at: source)
        prepareForAuthorization(store)
        store.preparePreflight()
        XCTAssertTrue(store.validationErrors.isEmpty)
        XCTAssertTrue(store.preflightErrors.isEmpty)
        XCTAssertTrue(store.canContinueFromVerification)
        XCTAssertTrue(store.canBeginAuthorization)
    }

    func testP2EFlowStillStartsWithAnalysis() async throws {
        let (store, _, source) = try makeStore()
        store.direction = .paperToElectronic
        await store.loadDocument(at: source)
        XCTAssertEqual(store.step, .analysis)
        XCTAssertNil(store.electronicOriginal)
    }

    // MARK: - One PDF (spec 2026-11-17, 5.4)

    /// A kept PDF/A would carry the clause after the client's signatures, which would then read as
    /// changed after signing, so under one PDF it is always converted.
    func testKeepPlanIsConvertedForSinglePDF() async throws {
        try requireXMLLint()
        let (store, provider, source, _) = try makeSinglePDFStore(facts: Self.keptPdfaFacts)
        let converted = Data("%PDF-1.7 converted for one PDF".utf8)
        let calls = ConvertCalls()
        store.pdfaFromSignedRunner = PdfaFromSignedRunner(launch: { arguments in
            calls.record()
            try converted.write(to: URL(fileURLWithPath: arguments[2]))
            return (0, "")
        })
        await store.loadElectronicOriginal(at: source)
        guard case .keep = store.electronicOriginal?.plan else {
            return XCTFail("the fixture must qualify for .keep, got \(String(describing: store.electronicOriginal?.plan))")
        }
        prepareForAuthorization(store)

        await store.authorizeAndSign()

        XCTAssertEqual(store.step, .done, store.lastError ?? "")
        XCTAssertEqual(calls.count, 1, "PdfaFromSigned runs for a kept original")
        let request = try XCTUnwrap(provider.clientRequests.first)
        XCTAssertEqual(request.pdfData, converted)
        XCTAssertNotEqual(request.pdfData, try Data(contentsOf: source))
    }

    func testE2ESinglePDFRequestShape() async throws {
        try requireXMLLint()
        let (store, provider, source, settingsStore) = try makeSinglePDFStore(testMode: true)
        store.pdfaFromSignedRunner = Self.convertingRunner(Data("%PDF-1.7 converted".utf8))
        let renderer = StubClausePageRenderer()
        store.clausePageRenderer = renderer
        await store.loadElectronicOriginal(at: source)
        prepareForAuthorization(store)
        let number = seedNumber(store: store, settingsStore: settingsStore)

        await store.authorizeAndSign()

        XCTAssertEqual(store.step, .done, store.lastError ?? "")
        XCTAssertEqual(provider.clientRequests.count, 1)
        let request = try XCTUnwrap(provider.clientRequests.first)
        XCTAssertEqual(request.outputFormat, .embeddedPAdES)
        XCTAssertTrue(request.includeTimestamp, "outside Demo the one PDF is always Baseline T")
        XCTAssertTrue(request.extraFiles.isEmpty)
        XCTAssertFalse(request.signsExtraFilesAsDataObjects)
        XCTAssertEqual(request.timestampServers, TimestampAuthority.zakoPAdESQualifiedURLs.map(\.absoluteString))
        XCTAssertEqual(request.tsaURL, TimestampAuthority.zakoPAdESQualifiedURLs.first?.absoluteString)
        let clause = try XCTUnwrap(request.appendedClause)
        XCTAssertEqual(renderer.renderedForms, [.clauseE2E_1_3])
        let renderedXML = try XCTUnwrap(renderer.renderedXML.first)
        XCTAssertTrue(renderedXML.contains(OfficialForm.clauseE2E_1_3.namespace))
        XCTAssertEqual(clause.attachment, XMLDataContainerBuilder.build(formXML: renderedXML, form: .clauseE2E_1_3),
                       "the pages are rendered from the very clause that is attached")
        XCTAssertEqual(clause.pages, StubClausePageRenderer.pages)
        XCTAssertEqual(clause.attachmentName, ConversionOutputNaming.containerClauseName(evidenceNumber: number))
        XCTAssertEqual(clause.attachmentMimeType, AppendedClause.xdcMimeType)
        XCTAssertTrue(renderedXML.contains("PDF/A-3"), "the clause names the delivered PDF/A-3")
        XCTAssertEqual(request.filename, "zmluva-konvertovane.pdf")
        // The record keeps the XAdES order of its own authorities.
        let recordRequest = try XCTUnwrap(provider.recordRequests.first)
        XCTAssertEqual(recordRequest.timestampServers, TimestampAuthority.zakoQualifiedURLs.map(\.absoluteString))
        XCTAssertNil(recordRequest.appendedClause)
    }

    func testE2ESinglePDFRowFields() async throws {
        try requireXMLLint()
        let (store, provider, source, settingsStore) = try makeSinglePDFStore()
        let converted = Data("%PDF-1.7 converted".utf8)
        store.pdfaFromSignedRunner = Self.convertingRunner(converted)
        let renderer = StubClausePageRenderer()
        store.clausePageRenderer = renderer
        let sourceBytes = try Data(contentsOf: source)
        let directory = source.deletingLastPathComponent()
        await store.loadElectronicOriginal(at: source)
        prepareForAuthorization(store)

        await store.authorizeAndSign()

        XCTAssertEqual(store.step, .done, store.lastError ?? "")
        let row = try XCTUnwrap(settingsStore.evidenceStore.record(id: store.currentRecordID))
        // The source "zmluva.pdf" holds the default name, so the one PDF takes the next one.
        let expected = "zmluva-konvertovane.pdf"
        let renderedXML = try XCTUnwrap(renderer.renderedXML.first)
        XCTAssertTrue(renderedXML.contains("<NewDocumentName>\(expected)</NewDocumentName>"), renderedXML)
        XCTAssertEqual(row.direction, .electronicToElectronic)
        XCTAssertEqual(row.clientOutput, .singlePDF)
        XCTAssertEqual(row.revisionOneLength, converted.count)
        XCTAssertEqual(row.deliveredFileName, expected)
        XCTAssertEqual(row.pdfFileName, expected)
        XCTAssertEqual(row.newDocumentName, expected)
        XCTAssertTrue(row.attestationXML.contains("PDF/A-3"), "the record names the delivered PDF/A-3")
        let delivered = try Data(contentsOf: directory.appendingPathComponent(expected))
        XCTAssertGreaterThan(delivered.count, converted.count)
        let revisionOne = delivered.prefix(try XCTUnwrap(row.revisionOneLength))
        XCTAssertEqual(row.fingerprintSHA256Hex, SHA256.hash(data: revisionOne).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       ["zmluva.pdf", expected], "one PDF and no container or loose clause")
        XCTAssertEqual(try Data(contentsOf: source), sourceBytes, "the client's file is never replaced")
        XCTAssertNotNil(row.recordContainerPath, "the record is signed as before")
        XCTAssertEqual(provider.recordRequests.count, 1)
    }

    func testE2ESinglePDFRasterOfferStillWorks() async throws {
        try requireXMLLint()
        let (store, provider, source, _) = try makeSinglePDFStore(facts: Self.keptPdfaFacts)
        store.pdfaFromSignedRunner = PdfaFromSignedRunner(launch: { _ in (3, "font") })
        let renderer = StubClausePageRenderer()
        store.clausePageRenderer = renderer
        await store.loadElectronicOriginal(at: source)
        prepareForAuthorization(store)

        await store.authorizeAndSign()

        XCTAssertTrue(store.rasterConversionOffered)
        XCTAssertEqual(store.lastError, ZakoSessionStore.rasterOfferMessage)
        XCTAssertNil(store.attestation.evidenceNumber, "no number before the PDF/A exists")
        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertTrue(renderer.renderedXML.isEmpty)
        XCTAssertNotEqual(store.step, .done)
    }

    func testE2ESinglePDFThatChangedTheNewDocumentIsRefused() async throws {
        try requireXMLLint()
        let (store, provider, source, settingsStore) = try makeSinglePDFStore(testMode: true)
        provider.changesPrefix = true
        store.pdfaFromSignedRunner = Self.convertingRunner(Data("%PDF-1.7 converted".utf8))
        let directory = source.deletingLastPathComponent()
        await store.loadElectronicOriginal(at: source)
        prepareForAuthorization(store)
        let number = seedNumber(store: store, settingsStore: settingsStore)

        await store.authorizeAndSign()

        XCTAssertEqual(store.lastError,
                       SigningError.signingFailed(ZakoSessionStore.singlePDFPrefixChangedMessage).errorDescription)
        XCTAssertTrue(provider.recordRequests.isEmpty)
        XCTAssertEqual(settingsStore.evidenceNumberPool.reusable(mode: .test, at: Date(), excluding: [])?.number, number)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["zmluva.pdf"])
        XCTAssertTrue(settingsStore.evidenceStore.records.isEmpty)
    }

    func testE2EProductionRefusalComesBeforeTheOnePDFRefusal() async throws {
        let (store, provider, source, _) = try makeSinglePDFStore()
        await store.loadElectronicOriginal(at: source)
        prepareForAuthorization(store)

        await store.authorizeElectronicOriginal(viaMobile: false, ezzkMode: .production)

        XCTAssertEqual(store.lastError, E2EProductionPolicy.refusalMessage)
        XCTAssertNil(store.attestation.evidenceNumber)
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testE2ESinglePDFWithoutEngineRefusedBeforeConversionAndNumber() async throws {
        let (store, provider, source) = try makeStore()
        store.settingsStore.settings.zakoClientOutput = .singlePDF
        let calls = ConvertCalls()
        store.pdfaFromSignedRunner = PdfaFromSignedRunner(launch: { _ in
            calls.record()
            return (3, "font")
        })
        await store.loadElectronicOriginal(at: source)
        prepareForAuthorization(store)

        await store.authorizeAndSign()

        XCTAssertEqual(store.lastError, ZakoSinglePDFDelivery.engineRefusal)
        XCTAssertEqual(calls.count, 0, "nothing is converted for a refused output")
        XCTAssertNil(store.attestation.evidenceNumber)
        XCTAssertEqual(provider.signedKinds, [])
    }

    // MARK: - Several files in one ASiC-E (spec 2026-11-18, 7.4)

    func testDemoMultiFileDeliversContainerWithMergedPdf() async throws {
        try requireXMLLint()
        let (store, provider, source) = try makeMultiFileStore()
        let merged = Data("%PDF-1.7 merged".utf8)
        let calls = MergeCalls()
        store.pdfaFromSignedRunner = Self.mergingRunner(merged, calls: calls)
        await store.loadElectronicOriginal(at: source)
        XCTAssertEqual(store.attestation.newDocumentName, "spis.pdf", "the container's stem names the new document")
        prepareForAuthorization(store)

        await store.authorizeAndSign()

        XCTAssertEqual(store.step, .done, store.lastError ?? "")
        XCTAssertEqual(calls.names, [["a.pdf", "b.png", "c.jpg"]])
        XCTAssertEqual(calls.inputs.first, Self.multiFiles.map(\.bytes), "the files go in byte for byte")
        let request = try XCTUnwrap(provider.clientRequests.first)
        XCTAssertEqual(request.pdfData, merged)
        let clause = try XCTUnwrap(request.extraFiles.first { $0.path.hasSuffix(".xdcf") })
        let clauseText = String(decoding: clause.data, as: UTF8.self)
        for name in ["a-1", "a-2", "b.png", "c.jpg"] {
            XCTAssertTrue(clauseText.contains(name), "the clause lists \(name)")
        }
        let row = try XCTUnwrap(store.evidenceStore.record(id: store.currentRecordID))
        XCTAssertEqual(row.direction, .electronicToElectronic)
        XCTAssertEqual(row.clientOutput, .asicContainer)
        XCTAssertEqual(row.fingerprintSHA256Hex, SHA256.hash(data: merged).map { String(format: "%02x", $0) }.joined())
        XCTAssertNoThrow(try FormSchemaValidator().validate(Data(row.attestationXML.utf8), against: .recordE2E_1_0))
    }

    func testDemoMultiFileDeliversOnePdf() async throws {
        try requireXMLLint()
        let (store, provider, source) = try makeMultiFileStore(output: .singlePDF)
        let merged = Data("%PDF-1.7 merged".utf8)
        let calls = MergeCalls()
        store.pdfaFromSignedRunner = Self.mergingRunner(merged, calls: calls)
        let renderer = StubClausePageRenderer()
        store.clausePageRenderer = renderer
        await store.loadElectronicOriginal(at: source)
        prepareForAuthorization(store)

        await store.authorizeAndSign()

        XCTAssertEqual(store.step, .done, store.lastError ?? "")
        XCTAssertEqual(calls.names, [["a.pdf", "b.png", "c.jpg"]])
        let request = try XCTUnwrap(provider.clientRequests.first)
        XCTAssertEqual(request.pdfData, merged)
        XCTAssertNotNil(request.appendedClause)
        let clauseText = try XCTUnwrap(renderer.renderedXML.first)
        for name in ["a-1", "a-2", "b.png", "c.jpg"] {
            XCTAssertTrue(clauseText.contains(name), "the clause lists \(name)")
        }
        let row = try XCTUnwrap(store.evidenceStore.record(id: store.currentRecordID))
        XCTAssertEqual(row.clientOutput, .singlePDF)
        XCTAssertEqual(row.revisionOneLength, merged.count)
    }

    func testDemoMultiFileFollowsChosenOrder() async throws {
        try requireXMLLint()
        let (store, _, source) = try makeMultiFileStore(output: .singlePDF)
        let calls = MergeCalls()
        store.pdfaFromSignedRunner = Self.mergingRunner(Data("%PDF-1.7 merged".utf8), calls: calls)
        let renderer = StubClausePageRenderer()
        store.clausePageRenderer = renderer
        await store.loadElectronicOriginal(at: source)
        store.moveE2EFile(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(store.electronicOriginal?.files.map(\.entryName), ["c.jpg", "a.pdf", "b.png"])
        prepareForAuthorization(store)

        await store.authorizeAndSign()

        XCTAssertEqual(store.step, .done, store.lastError ?? "")
        XCTAssertEqual(calls.names, [["c.jpg", "a.pdf", "b.png"]])
        let clauseText = try XCTUnwrap(renderer.renderedXML.first)
        let positions = try ["c.jpg", "a-1", "a-2", "b.png"].map { name in
            try XCTUnwrap(clauseText.range(of: name)?.lowerBound, "\(name) in the clause")
        }
        XCTAssertEqual(positions, positions.sorted(), "the clause lists the originals in the chosen order")
    }

    func testReverificationKeepsTheChosenOrder() async throws {
        let (store, _, source) = try makeMultiFileStore()
        await store.loadElectronicOriginal(at: source)
        store.moveE2EFile(from: IndexSet(integer: 0), to: 3)
        await store.verifyElectronicOriginal()
        XCTAssertEqual(store.electronicOriginal?.files.map(\.entryName), ["b.png", "c.jpg", "a.pdf"])
    }

    func testMultiFileNotCompliantOffersRaster() async throws {
        try requireXMLLint()
        let (store, provider, source) = try makeMultiFileStore()
        let calls = MergeCalls()
        store.pdfaFromSignedRunner = PdfaFromSignedRunner(launch: { arguments in
            guard arguments.count > 1, arguments[1] == "--merge" else { return (1, "convert instead of merge") }
            calls.record(arguments)
            return (3, "font")
        })
        await store.loadElectronicOriginal(at: source)
        prepareForAuthorization(store)

        await store.authorizeAndSign()

        XCTAssertEqual(calls.names.count, 1, "the files were merged, not converted one by one")
        XCTAssertTrue(store.rasterConversionOffered)
        XCTAssertEqual(store.lastError, ZakoSessionStore.rasterOfferMessage)
        XCTAssertNil(store.attestation.evidenceNumber, "no number before the PDF/A exists")
        XCTAssertTrue(provider.requests.isEmpty)
        XCTAssertNotEqual(store.step, .done)

        store.rasterConversionApproved = true
        store.pdfaFromSignedRunner = Self.mergingRunner(Data("%PDF-1.7 merged".utf8), calls: calls)
        await store.authorizeAndSign()
        XCTAssertEqual(store.step, .done, store.lastError ?? "")
        XCTAssertEqual(calls.rasterFlags.last, true, "the approved raster conversion reaches the merge")
    }

    func testReorderIsRefusedWhileAuthorizing() async throws {
        let (store, _, source) = try makeMultiFileStore()
        await store.loadElectronicOriginal(at: source)
        store.isAuthorizing = true
        store.moveE2EFile(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(store.electronicOriginal?.files.map(\.entryName), ["a.pdf", "b.png", "c.jpg"])
        store.isAuthorizing = false
        store.moveE2EFile(from: IndexSet(integer: 2), to: 0)
        XCTAssertEqual(store.electronicOriginal?.files.map(\.entryName), ["c.jpg", "a.pdf", "b.png"])
    }

    func testSingleFileKeepsItsDefaultNewDocumentName() async throws {
        let (store, _, source) = try makeStore()
        await store.loadElectronicOriginal(at: source)
        XCTAssertEqual(store.attestation.newDocumentName, "zmluva")
    }

    // MARK: - Several-file fixtures

    /// a.pdf with one PAdES revision of its own (so two documents, a-1 and a-2), b.png and c.jpg.
    static var multiFiles: [E2EEvidenceFixtures.DataObject] {
        let pdf = Data("%PDF-1.7\n".utf8) + Data(repeating: 0x41, count: 991)
        var a = E2EEvidenceFixtures.DataObject(name: "a.pdf", bytes: pdf)
        a.coveredBy = ["C-1"]
        a.pages = 2
        a.embeddedFileNames = ["priloha.xlsx"]
        var pades = E2EEvidenceFixtures.Signature()
        pades.id = "P-1"
        pades.signer = "Mária Veriteľka"
        pades.signedRevisionLength = 900
        pades.signatureValue = Data("pades-P-1".utf8)
        a.nestedSignatures = [pades]
        var b = E2EEvidenceFixtures.DataObject(name: "b.png",
                                               bytes: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data(repeating: 0x50, count: 40))
        b.kind = "png"
        b.coveredBy = ["C-1"]
        var c = E2EEvidenceFixtures.DataObject(name: "c.jpg",
                                               bytes: Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0x4A, count: 40))
        c.kind = "jpeg"
        c.coveredBy = ["C-1"]
        return [a, b, c]
    }

    static func multiFilePayload() -> Data {
        var container = E2EEvidenceFixtures.Signature()
        container.id = "C-1"
        container.format = "XAdES-BASELINE-T"
        container.signatureValue = Data("container-C-1".utf8)
        var facts = E2EEvidenceFixtures.PDF()
        facts.asicDataObjectCount = multiFiles.count
        facts.asicDataObjectName = "a.pdf"
        return E2EEvidenceFixtures.payload(signatures: [container], pdf: facts, dataObjects: multiFiles)
    }

    /// `spis.asice` with three files on disk, the provider validating it and the output chosen.
    private func makeMultiFileStore(output: AppSettings.ZakoClientOutput = .asicContainer)
        throws -> (ZakoSessionStore, SinglePDFEvidenceProvider, URL) {
        let settingsStore = makeSettingsStore()
        let directory = makeTemporaryDirectory("e2e-multi")
        let source = directory.appendingPathComponent("spis.asice")
        try ASiCEPackager().package(files: Self.multiFiles.map { .init(path: $0.name, data: $0.bytes) }).write(to: source)
        let provider = SinglePDFEvidenceProvider(payload: Self.multiFilePayload())
        settingsStore.useRealSigningProvider(provider)
        let original = settingsStore.settings
        addTeardownBlock { await MainActor.run { settingsStore.settings = original } }
        settingsStore.settings.learnFromReviews = false
        settingsStore.settings.zakoClientOutput = output
        let store = ZakoSessionStore(settingsStore: settingsStore,
                                     exampleBank: ExampleBank(directory: makeTemporaryDirectory("e2e-multi-bank")))
        store.direction = .electronicToElectronic
        store.clausePageRenderer = StubClausePageRenderer()
        return (store, provider, source)
    }

    /// A merge runner that refuses the single-file conversion and records each merge's inputs.
    private static func mergingRunner(_ merged: Data, calls: MergeCalls) -> PdfaFromSignedRunner {
        PdfaFromSignedRunner(launch: { arguments in
            guard arguments.count > 1, arguments[1] == "--merge" else { return (1, "convert instead of merge") }
            calls.record(arguments)
            try merged.write(to: URL(fileURLWithPath: arguments[2]))
            return (0, "")
        })
    }

    // MARK: - One-PDF fixtures

    private static var keptPdfaFacts: E2EEvidenceFixtures.PDF {
        var facts = E2EEvidenceFixtures.PDF()
        facts.declaredPdfaPart = 2
        facts.pdfaCompliant = true
        return facts
    }

    private static func convertingRunner(_ converted: Data) -> PdfaFromSignedRunner {
        PdfaFromSignedRunner(launch: { arguments in
            try converted.write(to: URL(fileURLWithPath: arguments[2]))
            return (0, "")
        })
    }

    private static let optionsReply = #"<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:a="http://www.w3.org/2005/08/addressing">"#
        + #"<s:Header><a:Action s:mustUnderstand="1">http://www.ditec.sk/IEZZKService/IEZZKService/GetOptionsResponse</a:Action></s:Header><s:Body><GetOptionsResponse xmlns="http://www.ditec.sk/IEZZKService"/></s:Body></s:Envelope>"#

    /// The signed client PDF, a provider that validates it from the fixture and plays the engine's
    /// one-PDF signature, and the output set to one PDF; Testovacia evidencia when `testMode`.
    private func makeSinglePDFStore(facts: E2EEvidenceFixtures.PDF = E2EEvidenceFixtures.PDF(), testMode: Bool = false)
        throws -> (ZakoSessionStore, SinglePDFEvidenceProvider, URL, AppSettingsStore) {
        let settingsStore: AppSettingsStore
        if testMode {
            let transport = ScriptedTransport([Self.optionsReply])
            let controller = EZZKAccountController(mode: .test, credentialStore: MemoryCredentialStore(),
                                                   transportFactory: { _ in transport }, productionPolicy: .refused)
            settingsStore = makeSettingsStore(ezzkAccountController: controller)
        } else {
            settingsStore = makeSettingsStore()
        }
        let directory = makeTemporaryDirectory("e2e-single-pdf")
        let a4 = CGSize(width: 595, height: 842)
        let data = TestPDFBuilderApp.build(pages: [
            (a4, { ctx, size in TestPDFBuilderApp.text("Zmluva o pôžičke", at: CGPoint(x: 60, y: size.height - 90), size: 16)(ctx, size) })
        ])
        let source = directory.appendingPathComponent("zmluva.pdf")
        try data.write(to: source)
        var signature = E2EEvidenceFixtures.Signature()
        signature.signedRevisionLength = data.count
        let provider = SinglePDFEvidenceProvider(payload: E2EEvidenceFixtures.payload(signatures: [signature], pdf: facts))
        settingsStore.useRealSigningProvider(provider)
        let original = settingsStore.settings
        addTeardownBlock { await MainActor.run { settingsStore.settings = original } }
        settingsStore.settings.learnFromReviews = false
        settingsStore.settings.zakoClientOutput = .singlePDF
        let store = ZakoSessionStore(settingsStore: settingsStore,
                                     exampleBank: ExampleBank(directory: makeTemporaryDirectory("e2e-single-pdf-bank")))
        store.direction = .electronicToElectronic
        store.clausePageRenderer = StubClausePageRenderer()
        return (store, provider, source, settingsStore)
    }

    /// A number this app allocated earlier in Testovacia evidencia, kept in the pool.
    @discardableResult
    private func seedNumber(store: ZakoSessionStore, settingsStore: AppSettingsStore) -> String {
        let number = "1563-261117-7"
        let allocatedAt = Date()
        settingsStore.evidenceNumberPool.add(.init(number: number, mode: .test, allocatedAt: allocatedAt))
        store.attestation.evidenceNumber = number
        store.attestation.evidenceNumberAllocatedAt = allocatedAt
        store.attestation.evidenceNumberMode = .test
        return number
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

/// Counts the PdfaFromSigned launches.
private final class ConvertCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func record() { lock.withLock { calls += 1 } }
}

/// The shared one-PDF engine double with the EVIDENCE answer an E→E original needs.
private final class SinglePDFEvidenceProvider: QualifiedSigningProviding, @unchecked Sendable {
    private let signer = SinglePDFRecordingProvider()
    let payload: Data

    init(payload: Data) {
        self.payload = payload
    }

    var supportsAppendedClause: Bool { signer.supportsAppendedClause }
    var changesPrefix: Bool {
        get { signer.changesPrefix }
        set { signer.changesPrefix = newValue }
    }
    var requests: [SigningRequest] { signer.requests }
    var clientRequests: [SigningRequest] { signer.clientRequests }
    var recordRequests: [SigningRequest] { signer.recordRequests }

    func availableIdentities() async -> [SigningIdentityInfo] { [] }

    func conversionEvidence(for fileURL: URL) async throws -> ConversionEvidence {
        try ConversionEvidence.decode(payloadJSON: payload)
    }

    func sign(_ request: SigningRequest) async throws -> SignedConversionResult {
        try await signer.sign(request)
    }
}

/// Every PdfaFromSigned --merge launch: its input names and bytes (read before the runner's
/// temporary folder goes) and whether it rasterized.
private final class MergeCalls: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedNames: [[String]] = []
    private var recordedInputs: [[Data]] = []
    private var recordedRaster: [Bool] = []

    var names: [[String]] { lock.withLock { recordedNames } }
    var inputs: [[Data]] { lock.withLock { recordedInputs } }
    var rasterFlags: [Bool] { lock.withLock { recordedRaster } }

    /// `PdfaFromSigned --merge <out> <icc> <title> [--raster] (<in> <name>)...`
    func record(_ arguments: [String]) {
        var rest = Array(arguments.dropFirst(5))
        let raster = rest.first == "--raster"
        if raster { rest.removeFirst() }
        var names: [String] = []
        var inputs: [Data] = []
        var index = 0
        while index + 1 < rest.count {
            inputs.append((try? Data(contentsOf: URL(fileURLWithPath: rest[index]))) ?? Data())
            names.append(rest[index + 1])
            index += 2
        }
        lock.withLock {
            recordedNames.append(names)
            recordedInputs.append(inputs)
            recordedRaster.append(raster)
        }
    }
}

// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Kit
import CryptoKit
import Foundation
import PDFKit
import XCTest
@testable import Chevron7App

/// ZaKo P→E in today's order with the one-PDF output (`AppSettings.ZakoClientOutput.singlePDF`):
/// the clause is appended to the PDF/A and signed with it as one PAdES document. The engine is
/// replaced by a provider that appends a fake revision; nothing leaves the machine.
@MainActor
final class ZakoSinglePDFFlowTests: XCTestCase {
    func testSinglePDFSignsPadesWithAppendedClause() async throws {
        try requireXMLLint()
        let (settingsStore, _) = makeTestModeSettingsStore()
        let provider = SinglePDFRecordingProvider()
        settingsStore.useRealSigningProvider(provider)
        let store = try makeReadyStore(settingsStore: settingsStore, output: .singlePDF)
        let renderer = StubClausePageRenderer()
        store.clausePageRenderer = renderer
        let number = seedNumber(store: store, settingsStore: settingsStore)

        await store.authorizeAndSign()

        XCTAssertEqual(store.step, .done, store.lastError ?? "")
        let request = try XCTUnwrap(provider.clientRequests.first)
        XCTAssertEqual(provider.clientRequests.count, 1)
        XCTAssertEqual(request.outputFormat, .embeddedPAdES)
        XCTAssertTrue(request.includeTimestamp, "outside Demo the one PDF is always Baseline T")
        XCTAssertTrue(request.extraFiles.isEmpty)
        XCTAssertFalse(request.signsExtraFilesAsDataObjects)
        XCTAssertEqual(request.timestampServers, TimestampAuthority.zakoPAdESQualifiedURLs.map(\.absoluteString))
        XCTAssertEqual(request.tsaURL, TimestampAuthority.zakoPAdESQualifiedURLs.first?.absoluteString)
        let clause = try XCTUnwrap(request.appendedClause)
        let renderedXML = try XCTUnwrap(renderer.renderedXML.first)
        XCTAssertEqual(renderer.renderedForms, [.clause_1_3])
        XCTAssertEqual(clause.attachment, XMLDataContainerBuilder.build(formXML: renderedXML, form: .clause_1_3),
                       "the pages are rendered from the very clause that is attached")
        XCTAssertEqual(clause.pages, StubClausePageRenderer.pages)
        XCTAssertEqual(clause.attachmentName, ConversionOutputNaming.containerClauseName(evidenceNumber: number))
        XCTAssertEqual(clause.attachmentMimeType, AppendedClause.xdcMimeType)
        XCTAssertTrue(renderedXML.contains("PDF/A-3"), "the clause names the delivered PDF/A-3")
        // The record keeps the XAdES order of its own authorities.
        let recordRequest = try XCTUnwrap(provider.recordRequests.first)
        XCTAssertEqual(recordRequest.timestampServers, TimestampAuthority.zakoQualifiedURLs.map(\.absoluteString))
        XCTAssertNil(recordRequest.appendedClause)
    }

    func testSinglePDFNameFixedBeforeClause() async throws {
        try requireXMLLint()
        let settingsStore = makeSettingsStore()
        let provider = SinglePDFRecordingProvider()
        settingsStore.useRealSigningProvider(provider)
        let store = try makeReadyStore(settingsStore: settingsStore, output: .singlePDF)
        let renderer = StubClausePageRenderer()
        store.clausePageRenderer = renderer
        let directory = makeTemporaryDirectory("single-pdf-name")
        store.outputDirectoryOverride = directory
        try Data("earlier".utf8).write(to: directory.appendingPathComponent("Zmluva o dielo.pdf"))

        await store.authorizeAndSign()

        XCTAssertEqual(store.step, .done, store.lastError ?? "")
        let row = try XCTUnwrap(settingsStore.evidenceStore.record(id: store.currentRecordID))
        let renderedXML = try XCTUnwrap(renderer.renderedXML.first)
        let expected = "Zmluva o dielo-konvertovane.pdf"
        XCTAssertTrue(renderedXML.contains("<NewDocumentName>\(expected)</NewDocumentName>"), renderedXML)
        XCTAssertEqual(row.deliveredFileName, expected)
        XCTAssertEqual(row.pdfFileName, expected)
        XCTAssertEqual(row.newDocumentName, expected)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(expected).path))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("Zmluva o dielo.pdf")),
                       Data("earlier".utf8), "an existing file is never replaced")
    }

    func testSinglePDFWritesOnePdfOnly() async throws {
        try requireXMLLint()
        let settingsStore = makeSettingsStore()
        settingsStore.useRealSigningProvider(SinglePDFRecordingProvider())
        let store = try makeReadyStore(settingsStore: settingsStore, output: .singlePDF)
        store.clausePageRenderer = StubClausePageRenderer()
        let directory = makeTemporaryDirectory("single-pdf-output")
        store.outputDirectoryOverride = directory

        await store.authorizeAndSign()

        XCTAssertEqual(store.step, .done, store.lastError ?? "")
        let outputs = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(outputs, ["Zmluva o dielo.pdf"], "outputs: \(outputs)")
        XCTAssertFalse(outputs.contains { $0.hasSuffix(".asice") || $0.hasSuffix(".xdcf") })
    }

    func testSinglePDFRowFields() async throws {
        try requireXMLLint()
        let settingsStore = makeSettingsStore()
        let provider = SinglePDFRecordingProvider()
        settingsStore.useRealSigningProvider(provider)
        let store = try makeReadyStore(settingsStore: settingsStore, output: .singlePDF)
        store.clausePageRenderer = StubClausePageRenderer()
        let directory = makeTemporaryDirectory("single-pdf-row")
        store.outputDirectoryOverride = directory

        await store.authorizeAndSign()

        XCTAssertEqual(store.step, .done, store.lastError ?? "")
        let finalPDF = try XCTUnwrap(provider.clientRequests.first?.pdfData)
        let row = try XCTUnwrap(settingsStore.evidenceStore.record(id: store.currentRecordID))
        XCTAssertEqual(row.clientOutput, .singlePDF)
        XCTAssertTrue(row.attestationXML.contains("PDF/A-3"), "the record names the delivered PDF/A-3")
        XCTAssertEqual(row.revisionOneLength, finalPDF.count)
        let delivered = try Data(contentsOf: directory.appendingPathComponent(try XCTUnwrap(row.deliveredFileName)))
        XCTAssertGreaterThan(delivered.count, finalPDF.count)
        let revisionOne = delivered.prefix(try XCTUnwrap(row.revisionOneLength))
        let hex = SHA256.hash(data: revisionOne).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(row.fingerprintSHA256Hex, hex)
        XCTAssertNotNil(row.recordContainerPath, "the record is signed as before")
    }

    func testFailedSignatureLeavesNumberAndNoOutput() async throws {
        try requireXMLLint()
        let (settingsStore, _) = makeTestModeSettingsStore()
        let provider = SinglePDFRecordingProvider()
        provider.refusesClient = true
        settingsStore.useRealSigningProvider(provider)
        let store = try makeReadyStore(settingsStore: settingsStore, output: .singlePDF)
        store.clausePageRenderer = StubClausePageRenderer()
        let directory = makeTemporaryDirectory("single-pdf-failed")
        store.outputDirectoryOverride = directory
        let number = seedNumber(store: store, settingsStore: settingsStore)

        await store.authorizeAndSign()

        XCTAssertNotNil(store.lastError)
        XCTAssertNotEqual(store.step, .done)
        XCTAssertEqual(provider.clientRequests.count, 1)
        XCTAssertTrue(provider.recordRequests.isEmpty)
        XCTAssertEqual(settingsStore.evidenceNumberPool.reusable(mode: .test, at: Date(), excluding: [])?.number, number)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        XCTAssertTrue(settingsStore.evidenceStore.records.isEmpty)
    }

    func testSignedResultThatChangedThePDFAIsRefused() async throws {
        try requireXMLLint()
        let (settingsStore, _) = makeTestModeSettingsStore()
        let provider = SinglePDFRecordingProvider()
        provider.changesPrefix = true
        settingsStore.useRealSigningProvider(provider)
        let store = try makeReadyStore(settingsStore: settingsStore, output: .singlePDF)
        store.clausePageRenderer = StubClausePageRenderer()
        let directory = makeTemporaryDirectory("single-pdf-prefix")
        store.outputDirectoryOverride = directory
        let number = seedNumber(store: store, settingsStore: settingsStore)

        await store.authorizeAndSign()

        XCTAssertEqual(store.lastError,
                       SigningError.signingFailed(ZakoSessionStore.singlePDFPrefixChangedMessage).errorDescription)
        XCTAssertTrue(provider.recordRequests.isEmpty)
        XCTAssertEqual(settingsStore.evidenceNumberPool.reusable(mode: .test, at: Date(), excluding: [])?.number, number)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        XCTAssertTrue(settingsStore.evidenceStore.records.isEmpty)
    }

    func testSinglePDFRefusedInProductionBeforeNumber() async throws {
        let transport = ScriptedTransport([])
        let controller = EZZKAccountController(mode: .production, credentialStore: MemoryCredentialStore(),
                                               transportFactory: { _ in transport }, productionPolicy: .refused)
        let settingsStore = makeSettingsStore(ezzkAccountController: controller)
        let provider = SinglePDFRecordingProvider()
        settingsStore.useRealSigningProvider(provider)
        let store = try makeReadyStore(settingsStore: settingsStore, output: .singlePDF, preview: false)

        await store.authorizeAndSign()

        XCTAssertEqual(store.lastError, SinglePDFProductionPolicy.refusalMessage)
        XCTAssertNil(store.attestation.evidenceNumber)
        XCTAssertEqual(transport.operations, [], "nothing reaches EZZK")
        XCTAssertTrue(provider.clientRequests.isEmpty)
    }

    func testSinglePDFRefusedWithoutEngineBeforeNumber() async throws {
        let settingsStore = makeSettingsStore()
        settingsStore.useRealSigningProvider(ContainerOnlyProvider())
        let store = try makeReadyStore(settingsStore: settingsStore, output: .singlePDF)

        await store.authorizeAndSign()

        XCTAssertEqual(store.lastError, ZakoSinglePDFDelivery.engineRefusal)
        XCTAssertNil(store.attestation.evidenceNumber)
    }

    func testContainerOutputUnchanged() async throws {
        try requireXMLLint()
        let (settingsStore, _) = makeTestModeSettingsStore()
        let provider = SinglePDFRecordingProvider()
        settingsStore.useRealSigningProvider(provider)
        let store = try makeReadyStore(settingsStore: settingsStore, output: nil)
        XCTAssertEqual(settingsStore.settings.zakoClientOutput, .asicContainer, "the container is the default")
        let renderer = StubClausePageRenderer()
        store.clausePageRenderer = renderer
        let directory = makeTemporaryDirectory("container-output")
        store.outputDirectoryOverride = directory
        let number = seedNumber(store: store, settingsStore: settingsStore)

        await store.authorizeAndSign()

        XCTAssertEqual(store.step, .done, store.lastError ?? "")
        XCTAssertTrue(renderer.renderedXML.isEmpty, "no clause pages for the container")
        let request = try XCTUnwrap(provider.clientRequests.first)
        XCTAssertEqual(request.outputFormat, .attachedASIC)
        XCTAssertNil(request.appendedClause)
        XCTAssertTrue(request.signsExtraFilesAsDataObjects)
        XCTAssertEqual(request.filename, "Zmluva o dielo.pdf")
        XCTAssertEqual(request.timestampServers, TimestampAuthority.zakoQualifiedURLs.map(\.absoluteString))
        XCTAssertEqual(request.tsaURL, TimestampAuthority.zakoQualifiedURLs.first?.absoluteString)
        XCTAssertEqual(request.extraFiles.map(\.path),
                       ["mimetype", "Zmluva o dielo.pdf",
                        ConversionOutputNaming.containerClauseName(evidenceNumber: number), "META-INF/manifest.xml"])
        let outputs = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(outputs, ["Zmluva o dielo.asice"])
        let row = try XCTUnwrap(settingsStore.evidenceStore.record(id: store.currentRecordID))
        XCTAssertNil(row.clientOutput)
        XCTAssertNil(row.revisionOneLength)
        XCTAssertEqual(row.pdfFileName, "Zmluva o dielo.pdf")
        XCTAssertEqual(row.deliveredFileName, "Zmluva o dielo.asice")
    }

    func testWriteWithoutOverwritingTakesAUniqueNameWhenTheTargetAppeared() throws {
        let directory = makeTemporaryDirectory("single-pdf-write")
        let preferred = directory.appendingPathComponent("Zmluva o dielo.pdf")
        try Data("other".utf8).write(to: preferred)

        let written = try ZakoSessionStore.writeWithoutOverwriting(Data("signed".utf8), preferred: preferred)

        XCTAssertEqual(written.lastPathComponent, "Zmluva o dielo (2).pdf")
        XCTAssertEqual(try Data(contentsOf: preferred), Data("other".utf8))
        XCTAssertEqual(try Data(contentsOf: written), Data("signed".utf8))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       ["Zmluva o dielo.pdf", "Zmluva o dielo (2).pdf"], "no staging file is left")
    }

    // MARK: - Fixtures

    private static let optionsReply = #"<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:a="http://www.w3.org/2005/08/addressing">"#
        + #"<s:Header><a:Action s:mustUnderstand="1">http://www.ditec.sk/IEZZKService/IEZZKService/GetOptionsResponse</a:Action></s:Header><s:Body><GetOptionsResponse xmlns="http://www.ditec.sk/IEZZKService"/></s:Body></s:Envelope>"#

    private func requireXMLLint() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xmllint") else {
            throw XCTSkip("xmllint is needed for schema validation of the clause and the record.")
        }
    }

    /// Testovacia evidencia: the server time comes from the script; sending the record later
    /// finds no reply and stays queued, which these tests do not look at.
    private func makeTestModeSettingsStore() -> (AppSettingsStore, ScriptedTransport) {
        let transport = ScriptedTransport([Self.optionsReply])
        let controller = EZZKAccountController(mode: .test, credentialStore: MemoryCredentialStore(),
                                               transportFactory: { _ in transport }, productionPolicy: .refused)
        return (makeSettingsStore(ezzkAccountController: controller), transport)
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

    private func makeReadyStore(settingsStore: AppSettingsStore, output: AppSettings.ZakoClientOutput?,
                                preview: Bool = false) throws -> ZakoSessionStore {
        let original = settingsStore.settings
        addTeardownBlock { await MainActor.run { settingsStore.settings = original } }
        settingsStore.settings.learnFromReviews = false
        settingsStore.settings.zakoRecordFirstPreview = preview
        if let output { settingsStore.settings.zakoClientOutput = output }
        let a4 = CGSize(width: 595, height: 842)
        let data = TestPDFBuilderApp.build(pages: [
            (a4, { ctx, size in TestPDFBuilderApp.text("Zmluva o dielo", at: CGPoint(x: 60, y: size.height - 90), size: 16)(ctx, size) }),
            (a4, { ctx, size in TestPDFBuilderApp.text("Podpisy zmluvných strán", at: CGPoint(x: 60, y: size.height - 90), size: 16)(ctx, size) })
        ])
        let bank = ExampleBank(directory: makeTemporaryDirectory("single-pdf-bank"))
        let store = ZakoSessionStore(settingsStore: settingsStore, exampleBank: bank)
        store.document = try XCTUnwrap(PDFDocument(data: data))
        store.documentData = data
        store.analysis = PDFAnalysisEngine().analyze(document: try XCTUnwrap(store.document))
        store.inputSignatureInspection = .completed(signatures: [])
        store.markPageReviewed(0)
        store.markPageReviewed(1)
        store.confirmNoSecurityElements()
        store.attestation.originalDocumentName = "Zmluva o dielo"
        store.attestation.originalDocumentTypeLabel = "Zmluva"
        store.attestation.originConfirmed = true
        store.attestation.numberOfSheets = 1
        store.attestation.nonEmptyPageCount = store.analysis.nonEmptyPages
        store.attestation.paperSizeBreakdown = [.init(sizeClass: .a4Portrait, sheets: 1)]
        store.attestation.newDocumentName = "Zmluva o dielo.pdf"
        store.attestation.newDocumentFormatLabel = "PDF/A-2"
        store.attestation.performingPerson = AdvocateProfile(fullName: "JUDr. Test Testovací",
                                                             position: "advokát",
                                                             registrationNumber: "4321",
                                                             ico: "35764102")
        store.attestation.usedDeviceDescription = "Skenovanie / import do aplikácie Chevron7"
        store.identities = [SigningIdentityInfo(id: "demo", label: "Test mandátny certifikát",
                                                issuerSummary: "Test CA", isMandateCertificate: true,
                                                isQualified: true)]
        store.selectedIdentityID = "demo"
        store.includeQualifiedTimestamp = false
        store.step = .authorize
        return store
    }
}

/// Stands in for the WebKit renderer and remembers the clause XML it was given.
@MainActor
private final class StubClausePageRenderer: ClausePageRendering, @unchecked Sendable {
    static let pages = Data("%PDF-1.7 clause pages".utf8)
    private(set) var renderedXML: [String] = []
    private(set) var renderedForms: [OfficialForm] = []

    func render(clauseXML: Data, form: OfficialForm) async throws -> Data {
        renderedXML.append(String(decoding: clauseXML, as: UTF8.self))
        renderedForms.append(form)
        return Self.pages
    }
}

/// Plays the engine for the one-PDF request (the source plus a fake revision) and signs the
/// record and any container with the Demo provider. Records every request.
private final class SinglePDFRecordingProvider: QualifiedSigningProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var received: [SigningRequest] = []
    private let demo = DemoSigningProvider()
    nonisolated(unsafe) var refusesClient = false
    nonisolated(unsafe) var changesPrefix = false

    var supportsAppendedClause: Bool { true }
    var clientRequests: [SigningRequest] { lock.withLock { received.filter { !$0.signsAsRecordContainer } } }
    var recordRequests: [SigningRequest] { lock.withLock { received.filter(\.signsAsRecordContainer) } }

    func availableIdentities() async -> [SigningIdentityInfo] { [] }

    func sign(_ request: SigningRequest) async throws -> SignedConversionResult {
        lock.withLock { received.append(request) }
        if !request.signsAsRecordContainer, refusesClient {
            throw SigningError.signingFailed("Karta bola vybratá počas podpisu.")
        }
        if !request.signsAsRecordContainer, request.appendedClause != nil {
            var source = request.pdfData
            if changesPrefix { source[source.startIndex + 10] ^= 0xFF }
            return SignedConversionResult(pdfData: source + Data("\n% clause and signature\n%%EOF\n".utf8),
                                          asicData: nil, signedAt: Date(),
                                          signatureLabel: "Test", isLegallyBinding: false)
        }
        var local = request
        local.includeTimestamp = false
        return try await demo.sign(local)
    }
}

/// A provider without the engine's one-PDF support (as the Demo signer).
private final class ContainerOnlyProvider: QualifiedSigningProviding, @unchecked Sendable {
    private let demo = DemoSigningProvider()
    func availableIdentities() async -> [SigningIdentityInfo] { [] }
    func sign(_ request: SigningRequest) async throws -> SignedConversionResult {
        try await demo.sign(request)
    }
}

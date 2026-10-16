// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Kit
import Foundation
import PDFKit
import XCTest
@testable import Chevron7App

/// ZaKo under the order of 1. 1. 2027 (`ZakoRegime.recordFirst`): the record 1.2 is signed and
/// sent first, the clause and the PDF/A are signed only after EZZK has processed the record.
/// Demo with the test preview stands in for the date; nothing leaves the machine.
@MainActor
final class ZakoRecordFirstFlowTests: XCTestCase {
    func testRecordIsSignedAndProcessedBeforeTheClientContainer() async throws {
        try requireXMLLint()
        let settingsStore = makeSettingsStore()
        let provider = OrderRecordingProvider()
        settingsStore.useRealSigningProvider(provider)
        let store = try makeReadyStore(settingsStore: settingsStore)
        let demoService = try XCTUnwrap(settingsStore.ezzkService as? MockEZZKService)
        var clientSignedAfterProcessed: Bool?
        provider.onClientSigning = {
            clientSignedAfterProcessed = settingsStore.evidenceStore.record(id: store.currentRecordID)?.status == .processed
        }

        await store.authorizeAndSign()

        XCTAssertNil(store.lastError)
        XCTAssertEqual(store.step, .done)
        XCTAssertEqual(provider.kinds, [.record, .client], "the record is signed first")
        XCTAssertEqual(clientSignedAfterProcessed, true, "the clause is signed only once EZZK processed the record")
        XCTAssertNil(store.recordFirstPending)
        let row = try XCTUnwrap(settingsStore.evidenceStore.record(id: store.currentRecordID))
        XCTAssertEqual(row.status, .processed)
        XCTAssertEqual(row.formPack?.recordVersion, "1.2")
        XCTAssertEqual(row.formPack?.packID, FormPackRepository.record12Unverified.id)
        XCTAssertTrue(row.attestationXML.contains(OfficialForm.record_1_2.namespace))
        XCTAssertLessThan(row.conversionTime, ZakoRegime.recordFirstFrom,
                          "the preview keeps the real conversion time")
        XCTAssertEqual(demoService.submittedRecords.count, 1)
        let outputs = try FileManager.default.contentsOfDirectory(atPath: try XCTUnwrap(store.outputDirectory).path)
        XCTAssertEqual(outputs.count, 1, "outputs: \(outputs)")
        XCTAssertEqual(row.deliveredFileName, outputs.first)
        XCTAssertEqual(row.pdfFileName, "Zmluva o dielo.pdf")
        let number = try XCTUnwrap(store.attestation.evidenceNumber)
        XCTAssertNil(settingsStore.evidenceNumberPool.reusable(mode: .demo, at: Date(), excluding: []),
                     "the number \(number) is spent")
    }

    func testWithoutPreviewTodayTheClauseIsSignedFirst() async throws {
        try requireXMLLint()
        let settingsStore = makeSettingsStore()
        let provider = OrderRecordingProvider()
        settingsStore.useRealSigningProvider(provider)
        let store = try makeReadyStore(settingsStore: settingsStore, preview: false)

        await store.authorizeAndSign()

        XCTAssertEqual(store.step, .done, store.lastError ?? "")
        XCTAssertEqual(provider.kinds, [.client, .record])
        let row = try XCTUnwrap(settingsStore.evidenceStore.record(id: store.currentRecordID))
        XCTAssertEqual(row.formPack?.recordVersion, "1.0")
    }

    func testRejectedRecordStopsTheConversionBeforeTheClient() async throws {
        try requireXMLLint()
        let settingsStore = makeSettingsStore()
        let provider = OrderRecordingProvider()
        settingsStore.useRealSigningProvider(provider)
        let store = try makeReadyStore(settingsStore: settingsStore)
        store.recordFirstLookup = { id in
            guard var row = settingsStore.evidenceStore.record(id: id) else { return .refused("") }
            row.status = .rejected
            row.ezzkResultCode = 12
            row.ezzkResultDescription = "Neznámy obsah"
            row.updatedAt = Date()
            settingsStore.evidenceStore.upsert(row)
            return .row(row)
        }

        await store.authorizeAndSign()

        XCTAssertEqual(provider.kinds, [.record])
        XCTAssertNotEqual(store.step, .done)
        XCTAssertNil(store.recordFirstPending)
        XCTAssertEqual(store.lastError, ZakoSessionStore.recordFirstRejectedMessage(code: 12, description: "Neznámy obsah"))
        let directory = store.outputDirectory
        XCTAssertNil(directory, "nothing is delivered")
        XCTAssertNil(store.attestation.evidenceNumber, "the next attempt takes a new number")
        XCTAssertNil(settingsStore.evidenceStore.record(id: store.currentRecordID), "and writes a new row")
        XCTAssertEqual(settingsStore.evidenceStore.records.first?.status, .rejected, "the refused row stays as it is")
        XCTAssertEqual(settingsStore.evidenceStore.records.count, 1)
    }

    func testTimedOutWaitResumesWithoutSigningTheRecordAgain() async throws {
        try requireXMLLint()
        let settingsStore = makeSettingsStore()
        let provider = OrderRecordingProvider()
        settingsStore.useRealSigningProvider(provider)
        let store = try makeReadyStore(settingsStore: settingsStore)
        let demoService = try XCTUnwrap(settingsStore.ezzkService as? MockEZZKService)
        var processed = false
        store.recordFirstLookup = { id in
            guard var row = settingsStore.evidenceStore.record(id: id) else { return .refused("") }
            if processed {
                row.status = .processed
                row.updatedAt = Date()
                settingsStore.evidenceStore.upsert(row)
            }
            return .row(row)
        }
        store.recordFirstWaitLimit = 0.05

        await store.authorizeAndSign()

        XCTAssertEqual(provider.kinds, [.record])
        XCTAssertEqual(store.lastError, ZakoSessionStore.recordFirstTimedOutMessage)
        let pending = try XCTUnwrap(store.recordFirstPending)
        XCTAssertEqual(pending.stage, .awaitingEZZK)
        let number = store.attestation.evidenceNumber

        processed = true
        store.recordFirstWaitLimit = 5
        await store.authorizeAndSign()

        XCTAssertEqual(store.step, .done, store.lastError ?? "")
        XCTAssertEqual(provider.kinds, [.record, .client], "the record is never signed twice")
        XCTAssertEqual(store.attestation.evidenceNumber, number, "no second number")
        XCTAssertEqual(demoService.submittedRecords.count, 1, "the record is sent once")
        XCTAssertNil(store.recordFirstPending)
    }

    func testStoppedWaitKeepsTheSentRecordForLater() async throws {
        try requireXMLLint()
        let settingsStore = makeSettingsStore()
        let provider = OrderRecordingProvider()
        settingsStore.useRealSigningProvider(provider)
        let store = try makeReadyStore(settingsStore: settingsStore)
        store.recordFirstLookup = { [weak store] id in
            store?.stopWaitingForEZZK()
            return .row(try! XCTUnwrap(settingsStore.evidenceStore.record(id: id)))
        }

        await store.authorizeAndSign()

        XCTAssertEqual(store.lastError, ZakoSessionStore.recordFirstWaitStoppedMessage)
        XCTAssertNotNil(store.recordFirstPending)
        XCTAssertFalse(store.isWaitingForEZZK)
        XCTAssertEqual(settingsStore.evidenceStore.record(id: store.currentRecordID)?.status, .acceptedForProcessing)
    }

    func testFailedRecordSignatureLeavesNoRowAndKeepsTheNumber() async throws {
        try requireXMLLint()
        let settingsStore = makeSettingsStore()
        let provider = OrderRecordingProvider()
        provider.refusesRecord = true
        settingsStore.useRealSigningProvider(provider)
        let store = try makeReadyStore(settingsStore: settingsStore)

        await store.authorizeAndSign()

        XCTAssertEqual(provider.kinds, [.record])
        XCTAssertNotNil(store.lastError)
        XCTAssertTrue(settingsStore.evidenceStore.records.isEmpty, "no row before the record is signed")
        XCTAssertNil(store.recordFirstPending)
        // Demo keeps no pool; the number stays on the conversion (outside Demo the pool keeps
        // it, because only a signed record or client container removes it).
        let number = try XCTUnwrap(store.attestation.evidenceNumber)

        provider.refusesRecord = false
        await store.authorizeAndSign()

        XCTAssertEqual(store.step, .done, store.lastError ?? "")
        XCTAssertEqual(store.attestation.evidenceNumber, number, "the next attempt uses the same number")
        XCTAssertEqual(provider.kinds, [.record, .record, .client])
        XCTAssertEqual(settingsStore.evidenceStore.records.count, 1)
    }

    /// Outside Demo the pool keeps an allocated number until a signed record carries it.
    func testOutsideDemoFailedRecordSignatureKeepsTheNumberInThePool() async throws {
        try requireXMLLint()
        let transport = ScriptedTransport([Self.optionsReply])
        let controller = EZZKAccountController(mode: .test, credentialStore: MemoryCredentialStore(),
                                               transportFactory: { _ in transport }, productionPolicy: .refused)
        let settingsStore = makeSettingsStore(ezzkAccountController: controller)
        let provider = OrderRecordingProvider()
        provider.refusesRecord = true
        settingsStore.useRealSigningProvider(provider)
        let store = try makeReadyStore(settingsStore: settingsStore)
        let allocatedAt = Date()
        settingsStore.evidenceNumberPool.add(.init(number: "1563-261016-7", mode: .test, allocatedAt: allocatedAt))
        store.attestation.evidenceNumber = "1563-261016-7"
        store.attestation.evidenceNumberAllocatedAt = allocatedAt
        store.attestation.evidenceNumberMode = .test

        await store.authorizeAndSign()

        XCTAssertEqual(provider.kinds, [.record])
        XCTAssertTrue(settingsStore.evidenceStore.records.isEmpty)
        XCTAssertEqual(settingsStore.evidenceNumberPool.reusable(mode: .test, at: allocatedAt, excluding: [])?.number,
                       "1563-261016-7")
        XCTAssertEqual(transport.operations, ["GetOptions"], "nothing but the server time reaches EZZK")
    }

    func testPhoneIsRefusedUnderTheNewOrder() async throws {
        let settingsStore = makeSettingsStore()
        settingsStore.settings.mobileSigningEnabled = true
        let store = try makeReadyStore(settingsStore: settingsStore)

        await store.authorizeAndSign(viaMobile: true)

        XCTAssertEqual(store.lastError, ZakoSessionStore.recordFirstMobileMessage)
        XCTAssertNil(store.attestation.evidenceNumber, "no number for a conversion that cannot run")
    }

    func testChangedFormRefusesToResume() async throws {
        try requireXMLLint()
        let settingsStore = makeSettingsStore()
        let provider = OrderRecordingProvider()
        settingsStore.useRealSigningProvider(provider)
        let store = try makeReadyStore(settingsStore: settingsStore)
        store.recordFirstLookup = { id in .row(try! XCTUnwrap(settingsStore.evidenceStore.record(id: id))) }
        store.recordFirstWaitLimit = 0.05
        await store.authorizeAndSign()
        XCTAssertNotNil(store.recordFirstPending)

        store.attestation.originalDocumentName = "Iný názov"
        await store.authorizeAndSign()

        XCTAssertEqual(store.lastError, ZakoSessionStore.recordFirstFormChangedMessage)
        XCTAssertEqual(provider.kinds, [.record])
    }

    func testNewDocumentDropsThePendingConversion() async throws {
        try requireXMLLint()
        let settingsStore = makeSettingsStore()
        settingsStore.useRealSigningProvider(OrderRecordingProvider())
        let store = try makeReadyStore(settingsStore: settingsStore)
        store.recordFirstLookup = { id in .row(try! XCTUnwrap(settingsStore.evidenceStore.record(id: id))) }
        store.recordFirstWaitLimit = 0.05
        await store.authorizeAndSign()
        XCTAssertNotNil(store.recordFirstPending)

        store.resetSession(keepingProfile: true)

        XCTAssertNil(store.recordFirstPending)
    }

    // MARK: - Fixtures

    private static let optionsReply = #"<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:a="http://www.w3.org/2005/08/addressing">"#
        + #"<s:Header><a:Action s:mustUnderstand="1">http://www.ditec.sk/IEZZKService/IEZZKService/GetOptionsResponse</a:Action></s:Header><s:Body><GetOptionsResponse xmlns="http://www.ditec.sk/IEZZKService"/></s:Body></s:Envelope>"#

    private func requireXMLLint() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xmllint") else {
            throw XCTSkip("xmllint is needed for schema validation of the clause and the record.")
        }
    }

    private func makeReadyStore(settingsStore: AppSettingsStore, preview: Bool = true) throws -> ZakoSessionStore {
        let original = settingsStore.settings
        addTeardownBlock { await MainActor.run { settingsStore.settings = original } }
        settingsStore.settings.learnFromReviews = false
        settingsStore.settings.zakoRecordFirstPreview = preview
        let a4 = CGSize(width: 595, height: 842)
        let data = TestPDFBuilderApp.build(pages: [
            (a4, { ctx, size in TestPDFBuilderApp.text("Zmluva o dielo", at: CGPoint(x: 60, y: size.height - 90), size: 16)(ctx, size) }),
            (a4, { ctx, size in TestPDFBuilderApp.text("Podpisy zmluvných strán", at: CGPoint(x: 60, y: size.height - 90), size: 16)(ctx, size) })
        ])
        let bank = ExampleBank(directory: makeTemporaryDirectory("record-first-bank"))
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
        store.recordFirstPollInterval = .milliseconds(1)
        store.step = .authorize
        return store
    }
}

/// Signs with the Demo provider and records which document each request signed.
private final class OrderRecordingProvider: QualifiedSigningProviding, @unchecked Sendable {
    enum Kind: Equatable { case record, client }
    private let lock = NSLock()
    private var received: [Kind] = []
    private let demo = DemoSigningProvider()
    nonisolated(unsafe) var refusesRecord = false
    /// Runs on the main actor when the client container signature starts.
    nonisolated(unsafe) var onClientSigning: (@MainActor () -> Void)?

    var kinds: [Kind] { lock.withLock { received } }

    func availableIdentities() async -> [SigningIdentityInfo] { [] }

    func sign(_ request: SigningRequest) async throws -> SignedConversionResult {
        let kind: Kind = request.signsAsRecordContainer ? .record : .client
        lock.withLock { received.append(kind) }
        if kind == .record, refusesRecord {
            throw SigningError.signingFailed("Karta bola vybratá počas podpisu záznamu.")
        }
        if kind == .client, let onClientSigning { await onClientSigning() }
        var local = request
        local.includeTimestamp = false
        return try await demo.sign(local)
    }
}

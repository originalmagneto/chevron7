// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7TestSupport
import CryptoKit
import Foundation
import PDFKit
import XCTest
@testable import Chevron7App
@testable import Chevron7Kit

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
        XCTAssertEqual(row.clientOutput, .asicContainer, "a new row names its output")
        XCTAssertNil(row.revisionOneLength)
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

    /// E→E: the record names the original's documents in order, so a resume after they changed
    /// (here the order of two files) refuses and signs nothing.
    func testE2EPendingRefusesAfterOriginalChange() async throws {
        let settingsStore = makeSettingsStore()
        let provider = OrderRecordingProvider()
        settingsStore.useRealSigningProvider(provider)
        let store = try makeReadyStore(settingsStore: settingsStore)
        store.direction = .electronicToElectronic
        let a = Data(SHA256.hash(data: Data("a".utf8)))
        let b = Data(SHA256.hash(data: Data("b".utf8)))
        store.electronicOriginal = try Self.electronicOriginal(fingerprints: [b, a])
        store.recordFirstPending = Self.e2ePending(attestation: store.attestation, fingerprints: [a, b])

        await store.resumeRecordFirst(viaMobile: false)

        XCTAssertEqual(store.lastError, ZakoSessionStore.recordFirstOriginalChangedMessage)
        XCTAssertEqual(store.lastError, "Pôvodný dokument alebo poradie jeho súborov sa od podpisu záznamu zmenili. Dokončite konverziu s pôvodným stavom alebo začnite novú.")
        XCTAssertTrue(provider.kinds.isEmpty, "nothing is signed")
        XCTAssertNotNil(store.recordFirstPending, "the conversion can still be finished with the original state")

        // The same documents in the signed order pass this check (and stop later, at the missing row).
        store.lastError = nil
        store.electronicOriginal = try Self.electronicOriginal(fingerprints: [a, b])
        await store.resumeRecordFirst(viaMobile: false)
        XCTAssertEqual(store.lastError, ZakoSessionStore.recordFirstMissingRowMessage)
        XCTAssertTrue(provider.kinds.isEmpty)
    }

    /// An E→E original whose documents carry `fingerprints`, in that order.
    private static func electronicOriginal(fingerprints: [Data]) throws -> ElectronicOriginal {
        let pdf = Data("%PDF-1.7\n".utf8) + Data(repeating: 0x41, count: 200)
        var signature = E2EEvidenceFixtures.Signature()
        signature.signedRevisionLength = pdf.count
        let evidence = try ConversionEvidence.decode(payloadJSON: E2EEvidenceFixtures.payload(signatures: [signature]))
        var original = try ElectronicOriginal.make(sourceName: "zmluva.pdf", sourceData: pdf, evidence: evidence)
        let template = try XCTUnwrap(original.documents.first)
        original.documents = fingerprints.enumerated().map { index, fingerprint in
            var document = template
            document.name = "zmluva-\(index + 1)"
            document.sha256 = fingerprint
            return document
        }
        return original
    }

    private static func e2ePending(attestation: AttestationData, fingerprints: [Data]) -> RecordFirstPending {
        RecordFirstPending(
            recordID: UUID(), stage: .awaitingEZZK,
            direction: .electronicToElectronic, originalFingerprints: fingerprints,
            mode: .demo, evidenceNumber: "1563-261118-1", conversionTime: Date(),
            finalPDF: Data("%PDF-1.7\n".utf8), fingerprint: "00", containerDocumentName: "zmluva.pdf",
            containerFiles: [], directory: FileManager.default.temporaryDirectory,
            stampsSignatures: false, timestampServers: nil, tsaURL: nil, attestation: attestation,
            clientOutput: .asicContainer, appendedClause: nil, fixedTarget: nil,
            clientTimestampServers: nil, clientTSAURL: nil)
    }

    // MARK: - One PDF (AppSettings.ZakoClientOutput.singlePDF)

    /// The PDF/A check of the appended clause runs before the record is signed, so a result that
    /// would not be PDF/A-3b costs no signature, no row and no number.
    func testRecordFirstChecksPdfaBeforeRecord() async throws {
        try requireXMLLint()
        let (settingsStore, transport) = makeTestModeSettingsStore()
        let provider = SinglePDFRecordingProvider()
        settingsStore.useRealSigningProvider(provider)
        let store = try makeReadyStore(settingsStore: settingsStore, output: .singlePDF)
        let renderer = StubClausePageRenderer()
        store.clausePageRenderer = renderer
        let check = CheckRecorder(status: 3, stderr: "6.8-1 embedded file\n")
        store.pdfClauseCheckRunner = check.runner
        let directory = makeTemporaryDirectory("record-first-single-pdf-check")
        store.outputDirectoryOverride = directory
        let number = seedNumber(store: store, settingsStore: settingsStore)
        // Should the check be skipped, the wait ends at once instead of after 30 minutes.
        store.recordFirstLookup = { id in .row(try! XCTUnwrap(settingsStore.evidenceStore.record(id: id))) }
        store.recordFirstWaitLimit = 0.05

        await store.authorizeAndSign()

        XCTAssertEqual(store.lastError,
                       PdfClauseCheckRunner.Failure.notCompliant(["6.8-1 embedded file"]).errorDescription)
        XCTAssertEqual(check.calls, 1)
        XCTAssertEqual(renderer.renderedXML.count, 1)
        XCTAssertTrue(provider.requests.isEmpty, "no record is signed")
        XCTAssertTrue(settingsStore.evidenceStore.records.isEmpty, "no row")
        XCTAssertNil(store.recordFirstPending)
        XCTAssertEqual(settingsStore.evidenceNumberPool.reusable(mode: .test, at: Date(), excluding: [])?.number, number)
        XCTAssertEqual(transport.operations, ["GetOptions"], "nothing but the server time reaches EZZK")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    /// The rules behind a refused PDF/A-3b check go to the ZaKo log without the temporary paths.
    func testPDFACheckFailureIsLoggedWithoutPaths() {
        let logged = ZakoSessionStore.logPDFACheckFailure([
            "6.8-1 embedded file",
            "6.2.11.4.1-1 font not embedded in /private/var/folders/x1/T/pdf-clause-check-1/source.pdf"
        ])
        XCTAssertEqual(logged, ["6.8-1 embedded file", "6.2.11.4.1-1 font not embedded in <cesta>"])
    }

    func testRecordFirstSinglePDFRequestShape() async throws {
        try requireXMLLint()
        let settingsStore = makeSettingsStore()
        let provider = SinglePDFRecordingProvider()
        settingsStore.useRealSigningProvider(provider)
        let store = try makeReadyStore(settingsStore: settingsStore, output: .singlePDF)
        let renderer = StubClausePageRenderer()
        store.clausePageRenderer = renderer
        let check = CheckRecorder(status: 0, stderr: "", provider: provider)
        store.pdfClauseCheckRunner = check.runner
        let directory = makeTemporaryDirectory("record-first-single-pdf-shape")
        store.outputDirectoryOverride = directory

        await store.authorizeAndSign()

        XCTAssertEqual(store.step, .done, store.lastError ?? "")
        XCTAssertEqual(provider.requests.map(\.signsAsRecordContainer), [true, false], "the record is signed first")
        XCTAssertEqual(check.requestsBeforeCheck, [0], "the PDF/A check runs before the record is signed")
        let request = try XCTUnwrap(provider.clientRequests.first)
        XCTAssertEqual(request.outputFormat, .embeddedPAdES)
        XCTAssertEqual(request.filename, "Zmluva o dielo.pdf")
        XCTAssertTrue(request.extraFiles.isEmpty)
        XCTAssertFalse(request.signsExtraFilesAsDataObjects)
        let clause = try XCTUnwrap(request.appendedClause)
        let renderedXML = try XCTUnwrap(renderer.renderedXML.first)
        XCTAssertEqual(renderer.renderedForms, [.clause_1_3])
        XCTAssertEqual(clause.pages, StubClausePageRenderer.pages)
        XCTAssertEqual(clause.attachment, XMLDataContainerBuilder.build(formXML: renderedXML, form: .clause_1_3),
                       "the pages are rendered from the very clause that is attached")
        XCTAssertTrue(renderedXML.contains("PDF/A-3"), "the clause names the delivered PDF/A-3")
        XCTAssertEqual(check.sources, [request.pdfData], "the check ran on the very PDF/A that is signed")
        XCTAssertEqual(check.attachments, [clause.attachment])
        XCTAssertNil(try XCTUnwrap(provider.recordRequests.first).appendedClause)

        let row = try XCTUnwrap(settingsStore.evidenceStore.record(id: store.currentRecordID))
        XCTAssertEqual(row.status, .processed)
        XCTAssertEqual(row.formPack?.recordVersion, "1.2")
        XCTAssertTrue(row.attestationXML.contains(#"<ItemCode>3</ItemCode><ItemName Language="sk">PDF/A-3</ItemName>"#),
                      "record 1.2 names the delivered PDF/A-3")
        XCTAssertEqual(row.clientOutput, .singlePDF)
        XCTAssertEqual(row.revisionOneLength, request.pdfData.count)
        XCTAssertEqual(row.pdfFileName, "Zmluva o dielo.pdf")
        XCTAssertEqual(row.deliveredFileName, "Zmluva o dielo.pdf")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["Zmluva o dielo.pdf"])
        XCTAssertNil(store.recordFirstPending)
    }

    /// "Dokončiť konverziu" finishes with the output chosen when the conversion started, the
    /// clause rendered then and the name the record carries.
    func testResumeSignsStoredClauseAndKeepsRecordedName() async throws {
        try requireXMLLint()
        let (settingsStore, _) = makeTestModeSettingsStore()
        let provider = SinglePDFRecordingProvider()
        settingsStore.useRealSigningProvider(provider)
        let store = try makeReadyStore(settingsStore: settingsStore, output: .singlePDF)
        let renderer = StubClausePageRenderer()
        store.clausePageRenderer = renderer
        let check = CheckRecorder(status: 0, stderr: "")
        store.pdfClauseCheckRunner = check.runner
        let directory = makeTemporaryDirectory("record-first-single-pdf-resume")
        store.outputDirectoryOverride = directory
        seedNumber(store: store, settingsStore: settingsStore)
        store.recordFirstLookup = { id in .row(try! XCTUnwrap(settingsStore.evidenceStore.record(id: id))) }
        store.recordFirstWaitLimit = 0.05

        await store.authorizeAndSign()

        XCTAssertNotEqual(store.step, .done)
        let pending = try XCTUnwrap(store.recordFirstPending, store.lastError ?? "")
        XCTAssertEqual(pending.clientOutput, .singlePDF)
        let storedClause = try XCTUnwrap(pending.appendedClause)
        let fixedTarget = try XCTUnwrap(pending.fixedTarget)
        XCTAssertEqual(fixedTarget, directory.appendingPathComponent("Zmluva o dielo.pdf"))
        XCTAssertTrue(provider.clientRequests.isEmpty)
        let recordRequest = try XCTUnwrap(provider.recordRequests.first)
        XCTAssertEqual(recordRequest.timestampServers, TimestampAuthority.zakoQualifiedURLs.map(\.absoluteString),
                       "the record keeps the XAdES order")

        // Meanwhile the setting changes and a file takes the fixed name; EZZK processes the record.
        settingsStore.settings.zakoClientOutput = .asicContainer
        try Data("earlier".utf8).write(to: fixedTarget)
        var row = try XCTUnwrap(settingsStore.evidenceStore.record(id: store.currentRecordID))
        row.status = .processed
        row.updatedAt = Date()
        settingsStore.evidenceStore.upsert(row)

        await store.authorizeAndSign()

        XCTAssertEqual(store.step, .done, store.lastError ?? "")
        XCTAssertEqual(provider.recordRequests.count, 1, "the record is never signed twice")
        XCTAssertEqual(renderer.renderedXML.count, 1, "the clause pages are not rendered again")
        XCTAssertEqual(check.calls, 1)
        let request = try XCTUnwrap(provider.clientRequests.first)
        XCTAssertEqual(provider.clientRequests.count, 1)
        XCTAssertEqual(request.outputFormat, .embeddedPAdES)
        XCTAssertEqual(request.appendedClause, storedClause)
        XCTAssertTrue(request.extraFiles.isEmpty)
        XCTAssertTrue(request.includeTimestamp, "outside Demo the one PDF is always Baseline T")
        XCTAssertEqual(request.timestampServers, TimestampAuthority.zakoPAdESQualifiedURLs.map(\.absoluteString))
        XCTAssertEqual(request.tsaURL, TimestampAuthority.zakoPAdESQualifiedURLs.first?.absoluteString)
        XCTAssertEqual(try Data(contentsOf: fixedTarget), Data("earlier".utf8), "an existing file is never replaced")
        let outputs = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        XCTAssertEqual(outputs, ["Zmluva o dielo.pdf", "Zmluva o dielo (2).pdf"])
        let finished = try XCTUnwrap(settingsStore.evidenceStore.record(id: store.currentRecordID))
        XCTAssertEqual(finished.pdfFileName, "Zmluva o dielo.pdf", "the name the record carries")
        XCTAssertEqual(finished.deliveredFileName, "Zmluva o dielo (2).pdf")
        XCTAssertEqual(finished.clientOutput, .singlePDF)
        XCTAssertEqual(finished.revisionOneLength, request.pdfData.count)
        XCTAssertNil(store.recordFirstPending)
    }

    func testRecordFirstSignedResultThatChangedThePDFAKeepsThePendingConversion() async throws {
        try requireXMLLint()
        let settingsStore = makeSettingsStore()
        let provider = SinglePDFRecordingProvider()
        provider.changesPrefix = true
        settingsStore.useRealSigningProvider(provider)
        let store = try makeReadyStore(settingsStore: settingsStore, output: .singlePDF)
        store.clausePageRenderer = StubClausePageRenderer()
        store.pdfClauseCheckRunner = CheckRecorder(status: 0, stderr: "").runner
        let directory = makeTemporaryDirectory("record-first-single-pdf-prefix")
        store.outputDirectoryOverride = directory

        await store.authorizeAndSign()

        XCTAssertEqual(store.lastError,
                       SigningError.signingFailed(ZakoSessionStore.recordFirstSinglePDFPrefixChangedMessage).errorDescription)
        XCTAssertNotEqual(store.step, .done)
        XCTAssertEqual(store.recordFirstPending?.stage, .signingClientContainer, "the conversion can be finished later")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    /// The client signature fails after EZZK processed the record: the message says the record stays
    /// in EZZK and how to go on; a resume without the engine's one-PDF support refuses the same way.
    func testFailedClientSignatureAfterTheRecordSaysHowToGoOn() async throws {
        try requireXMLLint()
        let settingsStore = makeSettingsStore()
        let provider = SinglePDFRecordingProvider()
        provider.refusesClient = true
        settingsStore.useRealSigningProvider(provider)
        let store = try makeReadyStore(settingsStore: settingsStore, output: .singlePDF)
        store.clausePageRenderer = StubClausePageRenderer()
        store.pdfClauseCheckRunner = CheckRecorder(status: 0, stderr: "").runner
        store.outputDirectoryOverride = makeTemporaryDirectory("record-first-single-pdf-client-failed")

        await store.authorizeAndSign()

        XCTAssertEqual(store.recordFirstPending?.stage, .signingClientContainer)
        let detail = SigningError.signingFailed("Karta bola vybratá počas podpisu.").errorDescription ?? ""
        XCTAssertEqual(store.lastError, RecordFirstClientSignatureError(detail: detail).errorDescription)
        let message = try XCTUnwrap(store.lastError)
        XCTAssertTrue(message.contains("Záznam o konverzii zostáva v EZZK"), message)
        XCTAssertTrue(message.contains("Dokončiť konverziu"), message)
        XCTAssertTrue(message.contains("novú konverziu"), message)

        settingsStore.useRealSigningProvider(NoAppendedClauseProvider())

        await store.authorizeAndSign()

        XCTAssertEqual(store.lastError,
                       RecordFirstClientSignatureError(
                           detail: SigningError.signingFailed(ZakoSinglePDFDelivery.engineRefusal).errorDescription ?? "")
                           .errorDescription)
        XCTAssertEqual(store.recordFirstPending?.stage, .signingClientContainer, "the conversion can still be finished")
        XCTAssertNotEqual(store.step, .done)
    }

    // MARK: - Fixtures

    private static let optionsReply = #"<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:a="http://www.w3.org/2005/08/addressing">"#
        + #"<s:Header><a:Action s:mustUnderstand="1">http://www.ditec.sk/IEZZKService/IEZZKService/GetOptionsResponse</a:Action></s:Header><s:Body><GetOptionsResponse xmlns="http://www.ditec.sk/IEZZKService"/></s:Body></s:Envelope>"#

    private func requireXMLLint() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xmllint") else {
            throw XCTSkip("xmllint is needed for schema validation of the clause and the record.")
        }
    }

    /// Testovacia evidencia: the server time comes from the script; sending the record finds no
    /// credentials, so the record stays signed and the conversion waits.
    private func makeTestModeSettingsStore() -> (AppSettingsStore, ScriptedTransport) {
        let transport = ScriptedTransport([Self.optionsReply])
        let controller = EZZKAccountController(mode: .test, credentialStore: MemoryCredentialStore(),
                                               transportFactory: { _ in transport }, productionPolicy: .refused)
        return (makeSettingsStore(ezzkAccountController: controller), transport)
    }

    /// A number this app allocated earlier in Testovacia evidencia, kept in the pool.
    @discardableResult
    private func seedNumber(store: ZakoSessionStore, settingsStore: AppSettingsStore) -> String {
        let number = "1563-261117-8"
        let allocatedAt = Date()
        settingsStore.evidenceNumberPool.add(.init(number: number, mode: .test, allocatedAt: allocatedAt))
        store.attestation.evidenceNumber = number
        store.attestation.evidenceNumberAllocatedAt = allocatedAt
        store.attestation.evidenceNumberMode = .test
        return number
    }

    private func makeReadyStore(settingsStore: AppSettingsStore, preview: Bool = true,
                                output: AppSettings.ZakoClientOutput? = nil) throws -> ZakoSessionStore {
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

/// Stands in for the engine's PDF/A check of the appended clause: answers with a fixed exit
/// status and remembers what it was asked to check.
private final class CheckRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var checkedSources: [Data] = []
    private var checkedAttachments: [Data] = []
    private var signedBefore: [Int] = []
    private let status: Int32
    private let stderr: String
    private let provider: SinglePDFRecordingProvider?

    init(status: Int32, stderr: String, provider: SinglePDFRecordingProvider? = nil) {
        self.status = status
        self.stderr = stderr
        self.provider = provider
    }

    var calls: Int { lock.withLock { checkedSources.count } }
    var sources: [Data] { lock.withLock { checkedSources } }
    var attachments: [Data] { lock.withLock { checkedAttachments } }
    /// How many signing requests the provider had received when each check ran.
    var requestsBeforeCheck: [Int] { lock.withLock { signedBefore } }

    var runner: PdfClauseCheckRunner {
        PdfClauseCheckRunner(launch: { [self] arguments in
            // PdfClauseAppender <source> <pages> <attachment> <name> <mime>
            let source = (try? Data(contentsOf: URL(fileURLWithPath: arguments[1]))) ?? Data()
            let attachment = (try? Data(contentsOf: URL(fileURLWithPath: arguments[3]))) ?? Data()
            let before = provider?.requests.count ?? 0
            lock.withLock {
                checkedSources.append(source)
                checkedAttachments.append(attachment)
                signedBefore.append(before)
            }
            return (status, stderr)
        })
    }
}

/// A provider without the engine's one-PDF support, as the Demo signer.
private final class NoAppendedClauseProvider: QualifiedSigningProviding, @unchecked Sendable {
    private let demo = DemoSigningProvider()
    func availableIdentities() async -> [SigningIdentityInfo] { [] }
    func sign(_ request: SigningRequest) async throws -> SignedConversionResult {
        try await demo.sign(request)
    }
}

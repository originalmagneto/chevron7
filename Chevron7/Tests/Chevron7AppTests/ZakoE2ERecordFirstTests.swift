// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7TestSupport
import CryptoKit
import Foundation
import PDFKit
import XCTest
@testable import Chevron7App
@testable import Chevron7Kit

/// E→E under the order of 1. 1. 2027 (spec 2026-11-18-zako-e2e-record-first, 7.3 to 7.5): the
/// record E→E 1.2 is signed and sent first, the client output (ASiC-E or one PDF) is signed only
/// once EZZK processed it. Demo with the test preview stands in for the date.
@MainActor
final class ZakoE2ERecordFirstTests: XCTestCase {
    // MARK: - Order and outputs

    func testE2ERecordIsSignedAndProcessedBeforeTheClientOutput() async throws {
        try requireXMLLint()
        for output in [AppSettings.ZakoClientOutput.asicContainer, .singlePDF] {
            let (store, provider, source, settingsStore) = try makeStore(output: output)
            let converted = Data("%PDF-1.7 converted \(output)".utf8)
            store.pdfaFromSignedRunner = Self.convertingRunner(converted)
            var clientSignedAfterProcessed: Bool?
            provider.onClientSigning = {
                clientSignedAfterProcessed = settingsStore.evidenceStore.record(id: store.currentRecordID)?.status == .processed
            }
            await store.loadElectronicOriginal(at: source)
            prepareForAuthorization(store)

            await store.authorizeAndSign()

            XCTAssertEqual(store.step, .done, "\(output): \(store.lastError ?? "")")
            XCTAssertNil(store.lastError)
            XCTAssertEqual(provider.requests.map(\.signsAsRecordContainer), [true, false], "\(output): the record first")
            XCTAssertEqual(clientSignedAfterProcessed, true, "\(output): the client output only after EZZK processed")
            XCTAssertNil(store.recordFirstPending)
            let row = try XCTUnwrap(settingsStore.evidenceStore.record(id: store.currentRecordID))
            XCTAssertEqual(row.status, .processed)
            XCTAssertEqual(row.direction, .electronicToElectronic)
            XCTAssertEqual(row.formPack?.packID, FormPackRepository.e2eRecord12Unverified.id)
            XCTAssertEqual(row.formPack?.recordVersion, "1.2")
            XCTAssertTrue(row.attestationXML.contains(OfficialForm.recordE2E_1_2.namespace))
            XCTAssertNoThrow(try FormSchemaValidator().validate(Data(row.attestationXML.utf8), against: .recordE2E_1_2))
            XCTAssertEqual(row.fingerprintSHA256Hex, SHA256.hash(data: converted).map { String(format: "%02x", $0) }.joined())
            XCTAssertEqual(row.validationEvidenceSource, "Chevron7 (DSS 6.4)")
            XCTAssertNotNil(settingsStore.evidenceStore.validationEvidenceData(for: row))
            XCTAssertNotNil(row.recordContainerPath)
            XCTAssertEqual(row.clientOutput, output)
            let client = try XCTUnwrap(provider.clientRequests.first)
            XCTAssertEqual(client.pdfData, converted)
            let directory = source.deletingLastPathComponent()
            let delivered = try XCTUnwrap(row.deliveredFileName)
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent(delivered).path))
            if output == .singlePDF {
                XCTAssertEqual(client.outputFormat, .embeddedPAdES)
                XCTAssertNotNil(client.appendedClause)
                XCTAssertEqual(row.revisionOneLength, converted.count)
                XCTAssertEqual(delivered, "zmluva-konvertovane.pdf")
                XCTAssertEqual(row.pdfFileName, delivered)
                XCTAssertTrue(row.attestationXML.contains("PDF/A-3"), "record 1.2 names the delivered PDF/A-3")
            } else {
                XCTAssertTrue(client.signsExtraFilesAsDataObjects)
                XCTAssertNotNil(client.extraFiles.first { $0.path.hasSuffix(".xml.xdcf") }, "the clause travels with the PDF")
                XCTAssertNil(client.appendedClause)
                XCTAssertNil(row.revisionOneLength)
                XCTAssertEqual(delivered, "zmluva.asice")
                XCTAssertEqual(row.pdfFileName, "zmluva.pdf")
            }
        }
    }

    /// A kept PDF/A goes into the container byte for byte, with the client's signatures, as today.
    func testE2EKeptPdfaIsSignedAsTodayAfterTheRecord() async throws {
        try requireXMLLint()
        var facts = E2EEvidenceFixtures.PDF()
        facts.declaredPdfaPart = 2
        facts.pdfaCompliant = true
        var requests: [Bool: SigningRequest] = [:]
        for preview in [false, true] {
            let (store, provider, source, _) = try makeStore(output: .asicContainer, facts: facts, preview: preview)
            await store.loadElectronicOriginal(at: source)
            prepareForAuthorization(store)

            await store.authorizeAndSign()

            XCTAssertEqual(store.step, .done, store.lastError ?? "")
            let client = try XCTUnwrap(provider.clientRequests.first)
            XCTAssertEqual(client.pdfData, try Data(contentsOf: source), "the client's PDF goes in unchanged")
            XCTAssertEqual(provider.requests.map(\.signsAsRecordContainer), preview ? [true, false] : [false, true])
            requests[preview] = client
        }
        let today = try XCTUnwrap(requests[false])
        let recordFirst = try XCTUnwrap(requests[true])
        XCTAssertEqual(recordFirst.filename, today.filename)
        XCTAssertEqual(recordFirst.extraFiles.map(\.path), today.extraFiles.map(\.path))
        XCTAssertEqual(recordFirst.signsExtraFilesAsDataObjects, today.signsExtraFilesAsDataObjects)
        XCTAssertEqual(recordFirst.outputFormat, today.outputFormat)
        XCTAssertEqual(recordFirst.includeTimestamp, today.includeTimestamp)
        XCTAssertEqual(recordFirst.tsaURL, today.tsaURL)
        XCTAssertEqual(recordFirst.timestampServers, today.timestampServers)
    }

    /// The one PDF is checked as PDF/A-3b before the record is signed, as P→E does.
    func testE2ESinglePDFIsCheckedBeforeTheRecord() async throws {
        try requireXMLLint()
        let (store, provider, source, settingsStore, transport) = try makeTestModeStore(output: .singlePDF)
        store.pdfaFromSignedRunner = Self.convertingRunner(Data("%PDF-1.7 converted".utf8))
        store.pdfClauseCheckRunner = PdfClauseCheckRunner(launch: { _ in (3, "6.8-1 embedded file\n") })
        await store.loadElectronicOriginal(at: source)
        prepareForAuthorization(store)
        let number = seedNumber(store: store, settingsStore: settingsStore)

        await store.authorizeAndSign()

        XCTAssertEqual(store.lastError,
                       PdfClauseCheckRunner.Failure.notCompliant(["6.8-1 embedded file"]).errorDescription)
        XCTAssertTrue(provider.requests.isEmpty, "no record is signed")
        XCTAssertTrue(settingsStore.evidenceStore.records.isEmpty)
        XCTAssertNil(store.recordFirstPending)
        XCTAssertEqual(settingsStore.evidenceNumberPool.reusable(mode: .test, at: Date(), excluding: [])?.number, number)
        XCTAssertEqual(transport.operations, ["GetOptions"], "nothing but the server time reaches EZZK")
    }

    /// The row is built from the values the record was rendered from: a change to the session
    /// while the record is being signed never reaches it.
    func testE2ERowIsBuiltFromTheSignedValues() async throws {
        try requireXMLLint()
        let (store, provider, source, settingsStore) = try makeStore()
        store.pdfaFromSignedRunner = Self.convertingRunner(Data("%PDF-1.7 converted".utf8))
        waitsForEver(store, settingsStore: settingsStore)
        await store.loadElectronicOriginal(at: source)
        prepareForAuthorization(store)
        let signedName = store.attestation.originalDocumentName
        let signedPerson = store.attestation.performingPerson.fullName
        provider.onRecordSigning = {
            store.attestation.originalDocumentName = "iny-dokument.pdf"
            store.attestation.performingPerson = AdvocateProfile(fullName: "Iná osoba", position: "advokát",
                                                                 registrationNumber: "1", ico: "35764102")
        }

        await store.authorizeAndSign()

        let row = try XCTUnwrap(settingsStore.evidenceStore.record(id: store.currentRecordID))
        XCTAssertEqual(row.originalName, signedName)
        XCTAssertEqual(row.performingPersonName, signedPerson)
        XCTAssertTrue(row.attestationXML.contains(signedName))
        XCTAssertEqual(store.recordFirstPending?.attestation.originalDocumentName, signedName)
    }

    /// A record container that cannot be stored leaves no row and no validation evidence file,
    /// and keeps the number.
    func testE2EUnstorableRecordLeavesNoValidationEvidence() async throws {
        try requireXMLLint()
        let (store, provider, source, settingsStore, transport) = try makeTestModeStore()
        store.pdfaFromSignedRunner = Self.convertingRunner(Data("%PDF-1.7 converted".utf8))
        await store.loadElectronicOriginal(at: source)
        prepareForAuthorization(store)
        let number = seedNumber(store: store, settingsStore: settingsStore)
        // A file where the records folder belongs makes storing the record container fail.
        let evidenceFolder = settingsStore.storageRoot.appendingPathComponent("Evidence", isDirectory: true)
        try Data("not a folder".utf8).write(to: evidenceFolder.appendingPathComponent("records"))

        await store.authorizeAndSign()

        XCTAssertEqual(provider.requests.map(\.signsAsRecordContainer), [true])
        XCTAssertNotNil(store.lastError)
        XCTAssertTrue(settingsStore.evidenceStore.records.isEmpty)
        let validation = evidenceFolder.appendingPathComponent("validation", isDirectory: true)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: validation.path)) ?? [], [],
                       "no orphan validation evidence")
        XCTAssertNil(store.recordFirstPending)
        XCTAssertEqual(settingsStore.evidenceNumberPool.reusable(mode: .test, at: Date(), excluding: [])?.number, number)
        XCTAssertEqual(transport.operations, ["GetOptions"])
    }

    func testE2ERejectedRecordDeliversNothing() async throws {
        try requireXMLLint()
        let (store, provider, source, settingsStore) = try makeStore()
        store.pdfaFromSignedRunner = Self.convertingRunner(Data("%PDF-1.7 converted".utf8))
        store.recordFirstLookup = { id in
            guard var row = settingsStore.evidenceStore.record(id: id) else { return .refused("") }
            row.status = .rejected
            row.ezzkResultCode = 12
            row.ezzkResultDescription = "Neznámy obsah"
            row.updatedAt = Date()
            settingsStore.evidenceStore.upsert(row)
            return .row(row)
        }
        let directory = source.deletingLastPathComponent()
        await store.loadElectronicOriginal(at: source)
        prepareForAuthorization(store)

        await store.authorizeAndSign()

        XCTAssertEqual(provider.requests.map(\.signsAsRecordContainer), [true])
        XCTAssertNotEqual(store.step, .done)
        XCTAssertNil(store.recordFirstPending)
        XCTAssertEqual(store.lastError, ZakoSessionStore.recordFirstRejectedMessage(code: 12, description: "Neznámy obsah"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["zmluva.pdf"],
                       "nothing is delivered")
        XCTAssertEqual(settingsStore.evidenceStore.records.map(\.status), [.rejected])
    }

    func testE2EFailedRecordSignatureLeavesNoRowAndKeepsTheNumber() async throws {
        try requireXMLLint()
        let (store, provider, source, settingsStore, transport) = try makeTestModeStore()
        provider.refusesRecord = true
        store.pdfaFromSignedRunner = Self.convertingRunner(Data("%PDF-1.7 converted".utf8))
        await store.loadElectronicOriginal(at: source)
        prepareForAuthorization(store)
        let number = seedNumber(store: store, settingsStore: settingsStore)

        await store.authorizeAndSign()

        XCTAssertEqual(provider.requests.map(\.signsAsRecordContainer), [true])
        XCTAssertNotNil(store.lastError)
        XCTAssertTrue(settingsStore.evidenceStore.records.isEmpty, "no row before the record is signed")
        XCTAssertNil(store.recordFirstPending)
        XCTAssertEqual(settingsStore.evidenceNumberPool.reusable(mode: .test, at: Date(), excluding: [])?.number, number)
        XCTAssertEqual(transport.operations, ["GetOptions"], "nothing but the server time reaches EZZK")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: source.deletingLastPathComponent().path),
                       ["zmluva.pdf"])
    }

    // MARK: - Resume

    func testE2EResumeAtWaitAndAtClientSignature() async throws {
        try requireXMLLint()
        // At the wait: EZZK has not processed the record yet.
        do {
            let (store, provider, source, settingsStore) = try makeStore()
            store.pdfaFromSignedRunner = Self.convertingRunner(Data("%PDF-1.7 converted".utf8))
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
            await store.loadElectronicOriginal(at: source)
            prepareForAuthorization(store)

            await store.authorizeAndSign()

            XCTAssertEqual(store.lastError, ZakoSessionStore.recordFirstTimedOutMessage)
            let pending = try XCTUnwrap(store.recordFirstPending)
            XCTAssertEqual(pending.stage, .awaitingEZZK)
            XCTAssertEqual(pending.direction, .electronicToElectronic)
            XCTAssertEqual(pending.originalFingerprints, store.electronicOriginal?.documents.map(\.sha256))
            let number = store.attestation.evidenceNumber

            processed = true
            store.recordFirstWaitLimit = 5
            await store.authorizeAndSign()

            XCTAssertEqual(store.step, .done, store.lastError ?? "")
            XCTAssertEqual(provider.requests.map(\.signsAsRecordContainer), [true, false], "the record is never signed twice")
            XCTAssertEqual(store.attestation.evidenceNumber, number)
            XCTAssertNil(store.recordFirstPending)
            let row = try XCTUnwrap(settingsStore.evidenceStore.record(id: store.currentRecordID))
            XCTAssertEqual(row.deliveredFileName, "zmluva.asice")
        }
        // At the client signature: EZZK processed the record, the card failed.
        do {
            let (store, provider, source, settingsStore) = try makeStore(output: .singlePDF)
            store.pdfaFromSignedRunner = Self.convertingRunner(Data("%PDF-1.7 converted".utf8))
            provider.refusesClient = true
            await store.loadElectronicOriginal(at: source)
            prepareForAuthorization(store)

            await store.authorizeAndSign()

            XCTAssertEqual(store.recordFirstPending?.stage, .signingClientContainer)
            XCTAssertTrue(store.lastError?.contains("Záznam o konverzii zostáva v EZZK") == true, store.lastError ?? "")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: source.deletingLastPathComponent().path),
                           ["zmluva.pdf"])

            provider.refusesClient = false
            await store.authorizeAndSign()

            XCTAssertEqual(store.step, .done, store.lastError ?? "")
            XCTAssertEqual(provider.requests.map(\.signsAsRecordContainer), [true, false, false])
            XCTAssertNil(store.recordFirstPending)
            let row = try XCTUnwrap(settingsStore.evidenceStore.record(id: store.currentRecordID))
            XCTAssertEqual(row.deliveredFileName, "zmluva-konvertovane.pdf")
            XCTAssertEqual(row.clientOutput, .singlePDF)
        }
    }

    func testResumeRefusedAfterOrderChange() async throws {
        try requireXMLLint()
        let (store, provider, source, settingsStore) = try makeMultiFileStore()
        await store.loadElectronicOriginal(at: source)
        prepareForAuthorization(store)
        waitsForEver(store, settingsStore: settingsStore)

        await store.authorizeAndSign()
        XCTAssertNotNil(store.recordFirstPending, store.lastError ?? "")

        store.electronicOriginal = store.electronicOriginal?.reordered(entryNames: ["b.png", "a.pdf", "c.jpg"])
        await store.authorizeAndSign()

        XCTAssertEqual(store.lastError, ZakoSessionStore.recordFirstOriginalChangedMessage)
        XCTAssertEqual(provider.requests.map(\.signsAsRecordContainer), [true], "no client output")
        XCTAssertNotNil(store.recordFirstPending)
    }

    func testResumeRefusedAfterTypeChange() async throws {
        try requireXMLLint()
        let (store, provider, source, settingsStore) = try makeMultiFileStore()
        await store.loadElectronicOriginal(at: source)
        prepareForAuthorization(store)
        store.attestation.originalDocumentTypeLabels["b.png"] = "fotografia"
        waitsForEver(store, settingsStore: settingsStore)

        await store.authorizeAndSign()
        XCTAssertNotNil(store.recordFirstPending, store.lastError ?? "")

        store.attestation.originalDocumentTypeLabels["b.png"] = "plná moc"
        await store.authorizeAndSign()

        XCTAssertEqual(store.lastError, ZakoSessionStore.recordFirstFormChangedMessage)
        XCTAssertEqual(provider.requests.map(\.signsAsRecordContainer), [true])
    }

    // MARK: - Several files

    func testE2EMultiFileRecordFirst() async throws {
        try requireXMLLint()
        let (store, provider, source, settingsStore) = try makeMultiFileStore()
        await store.loadElectronicOriginal(at: source)
        prepareForAuthorization(store)

        await store.authorizeAndSign()

        XCTAssertEqual(store.step, .done, store.lastError ?? "")
        XCTAssertEqual(provider.requests.map(\.signsAsRecordContainer), [true, false])
        XCTAssertEqual(try XCTUnwrap(provider.clientRequests.first).pdfData, Self.merged)
        let row = try XCTUnwrap(settingsStore.evidenceStore.record(id: store.currentRecordID))
        XCTAssertEqual(row.status, .processed)
        XCTAssertEqual(row.formPack?.packID, FormPackRepository.e2eRecord12Unverified.id)
        XCTAssertNoThrow(try FormSchemaValidator().validate(Data(row.attestationXML.utf8), against: .recordE2E_1_2))
        for name in ["a-1", "a-2", "b.png", "c.jpg"] {
            XCTAssertTrue(row.attestationXML.contains(name), "the record names \(name)")
        }
        XCTAssertEqual(row.deliveredFileName, "spis (2).asice", "beside the client's spis.asice, never replacing it")
    }

    // MARK: - Refusals before a number

    func testE2EUndeterminedQualificationRefusedBeforeNumber() async throws {
        var signature = E2EEvidenceFixtures.Signature()
        signature.qualification = "INDETERMINATE_QESIG"
        let (store, provider, source, _) = try makeStore(signature: signature)
        let calls = ConversionCount()
        store.pdfaFromSignedRunner = PdfaFromSignedRunner(launch: { arguments in
            calls.increment()
            try Data("%PDF-1.7 converted".utf8).write(to: URL(fileURLWithPath: arguments[2]))
            return (0, "")
        })
        await store.loadElectronicOriginal(at: source)
        if case .needsConfirmation = store.e2eDecision { store.confirmUndetermined() }
        prepareForAuthorization(store)

        await store.authorizeAndSign()

        XCTAssertEqual(store.lastError, ZakoSessionStore.e2eUndeterminedQualificationMessage(signer: "Ján Klient"))
        XCTAssertEqual(store.lastError,
                       "Kvalifikáciu podpisu Ján Klient sa nepodarilo určiť. Podľa postupu od 1. 1. 2027 ho nemožno zapísať do záznamu. Skúste overenie znova.")
        XCTAssertNil(store.attestation.evidenceNumber, "no number is spent on a refusal")
        XCTAssertEqual(calls.value, 0, "nothing is converted")
        XCTAssertTrue(provider.requests.isEmpty)
    }

    func testE2EPhoneRefusedInNewOrder() async throws {
        let (store, provider, source, settingsStore) = try makeStore()
        settingsStore.settings.mobileSigningEnabled = true
        await store.loadElectronicOriginal(at: source)
        prepareForAuthorization(store)

        await store.authorizeAndSign(viaMobile: true)

        XCTAssertEqual(store.lastError, ZakoSessionStore.recordFirstMobileMessage)
        XCTAssertNil(store.attestation.evidenceNumber)
        XCTAssertTrue(provider.requests.isEmpty)
    }

    /// The Mac's clock said today's order, EZZK's time says the new one: the forms are checked
    /// again in the new order before anything is signed, and its refusals hold.
    func testRegimeFlipAtEZZKTimeRechecksForms() async throws {
        try requireXMLLint()
        var signature = E2EEvidenceFixtures.Signature()
        signature.qualification = "INDETERMINATE_QESIG"
        let (store, provider, source, settingsStore, transport) = try makeTestModeStore(signature: signature)
        store.pdfaFromSignedRunner = Self.convertingRunner(Data("%PDF-1.7 converted".utf8))
        await store.loadElectronicOriginal(at: source)
        if case .needsConfirmation = store.e2eDecision { store.confirmUndetermined() }
        prepareForAuthorization(store)
        let number = seedNumber(store: store, settingsStore: settingsStore)
        let macClock = ZakoRegime.resolve(conversionTime: Date(), mode: .test, preview: false)
        XCTAssertEqual(macClock.regime, .clauseFirst)

        // The preview stands in for EZZK's time after the switch.
        await store.authorizeElectronicOriginal(viaMobile: false, ezzkMode: .test, expectedRegime: macClock)

        XCTAssertEqual(store.lastError, ZakoSessionStore.e2eUndeterminedQualificationMessage(signer: "Ján Klient"))
        XCTAssertTrue(provider.requests.isEmpty, "nothing is signed")
        XCTAssertTrue(settingsStore.evidenceStore.records.isEmpty)
        XCTAssertNil(store.recordFirstPending)
        XCTAssertEqual(settingsStore.evidenceNumberPool.reusable(mode: .test, at: Date(), excluding: [])?.number, number)
        XCTAssertEqual(transport.operations, ["GetOptions"])
    }

    func testE2EClauseFirstRowCarriesRecord10Pack() async throws {
        try requireXMLLint()
        let (store, provider, source, settingsStore) = try makeStore(preview: false)
        store.pdfaFromSignedRunner = Self.convertingRunner(Data("%PDF-1.7 converted".utf8))
        await store.loadElectronicOriginal(at: source)
        prepareForAuthorization(store)

        await store.authorizeAndSign()

        XCTAssertEqual(store.step, .done, store.lastError ?? "")
        XCTAssertEqual(provider.requests.map(\.signsAsRecordContainer), [false, true], "today the clause first")
        let row = try XCTUnwrap(settingsStore.evidenceStore.record(id: store.currentRecordID))
        XCTAssertEqual(row.formPack?.packID, FormPackRepository.e2eRecord10Unverified.id)
        XCTAssertEqual(row.formPack?.recordVersion, "1.0")
        XCTAssertNoThrow(try FormSchemaValidator().validate(Data(row.attestationXML.utf8), against: .recordE2E_1_0))
    }

    // MARK: - Fixtures

    private static let merged = Data("%PDF-1.7 merged".utf8)

    private static let optionsReply = #"<s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" xmlns:a="http://www.w3.org/2005/08/addressing">"#
        + #"<s:Header><a:Action s:mustUnderstand="1">http://www.ditec.sk/IEZZKService/IEZZKService/GetOptionsResponse</a:Action></s:Header><s:Body><GetOptionsResponse xmlns="http://www.ditec.sk/IEZZKService"/></s:Body></s:Envelope>"#

    private func requireXMLLint() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/xmllint") else {
            throw XCTSkip("xmllint is needed for schema validation of the clause and the record.")
        }
    }

    private static func convertingRunner(_ converted: Data) -> PdfaFromSignedRunner {
        PdfaFromSignedRunner(launch: { arguments in
            try converted.write(to: URL(fileURLWithPath: arguments[2]))
            return (0, "")
        })
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

    /// The record is never processed and the wait ends at once, so a pending conversion stays.
    private func waitsForEver(_ store: ZakoSessionStore, settingsStore: AppSettingsStore) {
        store.recordFirstLookup = { id in .row(try! XCTUnwrap(settingsStore.evidenceStore.record(id: id))) }
        store.recordFirstWaitLimit = 0.05
    }

    /// The store's common setup: the client's signed PDF, the provider and the stubs of the one PDF.
    private func configure(_ settingsStore: AppSettingsStore, provider: E2ERecordFirstProvider,
                           output: AppSettings.ZakoClientOutput, preview: Bool) -> ZakoSessionStore {
        settingsStore.useRealSigningProvider(provider)
        let original = settingsStore.settings
        addTeardownBlock { await MainActor.run { settingsStore.settings = original } }
        settingsStore.settings.learnFromReviews = false
        settingsStore.settings.zakoRecordFirstPreview = preview
        settingsStore.settings.zakoClientOutput = output
        let store = ZakoSessionStore(settingsStore: settingsStore,
                                     exampleBank: ExampleBank(directory: makeTemporaryDirectory("e2e-record-first-bank")))
        store.direction = .electronicToElectronic
        store.clausePageRenderer = StubClausePageRenderer()
        store.pdfClauseCheckRunner = PdfClauseCheckRunner(launch: { _ in (0, "") })
        store.recordFirstPollInterval = .milliseconds(1)
        return store
    }

    private func writeClientPDF() throws -> (URL, Data) {
        let directory = makeTemporaryDirectory("e2e-record-first")
        let a4 = CGSize(width: 595, height: 842)
        let data = TestPDFBuilderApp.build(pages: [
            (a4, { ctx, size in TestPDFBuilderApp.text("Zmluva o pôžičke", at: CGPoint(x: 60, y: size.height - 90), size: 16)(ctx, size) })
        ])
        let source = directory.appendingPathComponent("zmluva.pdf")
        try data.write(to: source)
        return (source, data)
    }

    private func makeStore(output: AppSettings.ZakoClientOutput = .asicContainer,
                           signature: E2EEvidenceFixtures.Signature = E2EEvidenceFixtures.Signature(),
                           facts: E2EEvidenceFixtures.PDF = E2EEvidenceFixtures.PDF(),
                           preview: Bool = true) throws
        -> (ZakoSessionStore, E2ERecordFirstProvider, URL, AppSettingsStore) {
        let settingsStore = makeSettingsStore()
        let (source, data) = try writeClientPDF()
        var signature = signature
        signature.signedRevisionLength = data.count
        let provider = E2ERecordFirstProvider(payload: E2EEvidenceFixtures.payload(signatures: [signature], pdf: facts))
        let store = configure(settingsStore, provider: provider, output: output, preview: preview)
        return (store, provider, source, settingsStore)
    }

    /// Testovacia evidencia with the preview: the server time comes from the script, sending
    /// finds no credentials.
    private func makeTestModeStore(signature: E2EEvidenceFixtures.Signature = E2EEvidenceFixtures.Signature(),
                                   output: AppSettings.ZakoClientOutput = .asicContainer) throws
        -> (ZakoSessionStore, E2ERecordFirstProvider, URL, AppSettingsStore, ScriptedTransport) {
        let transport = ScriptedTransport([Self.optionsReply])
        let controller = EZZKAccountController(mode: .test, credentialStore: MemoryCredentialStore(),
                                               transportFactory: { _ in transport }, productionPolicy: .refused)
        let settingsStore = makeSettingsStore(ezzkAccountController: controller)
        let (source, data) = try writeClientPDF()
        var signature = signature
        signature.signedRevisionLength = data.count
        let provider = E2ERecordFirstProvider(payload: E2EEvidenceFixtures.payload(signatures: [signature]))
        let store = configure(settingsStore, provider: provider, output: output, preview: true)
        return (store, provider, source, settingsStore, transport)
    }

    /// `spis.asice` with three files, merged into one PDF/A.
    private func makeMultiFileStore() throws -> (ZakoSessionStore, E2ERecordFirstProvider, URL, AppSettingsStore) {
        let settingsStore = makeSettingsStore()
        let directory = makeTemporaryDirectory("e2e-record-first-multi")
        let source = directory.appendingPathComponent("spis.asice")
        try ASiCEPackager().package(files: ZakoE2EFlowTests.multiFiles.map { .init(path: $0.name, data: $0.bytes) })
            .write(to: source)
        let provider = E2ERecordFirstProvider(payload: ZakoE2EFlowTests.multiFilePayload())
        let store = configure(settingsStore, provider: provider, output: .asicContainer, preview: true)
        let merged = Self.merged
        store.pdfaFromSignedRunner = PdfaFromSignedRunner(launch: { arguments in
            guard arguments.count > 1, arguments[1] == "--merge" else { return (1, "convert instead of merge") }
            try merged.write(to: URL(fileURLWithPath: arguments[2]))
            return (0, "")
        })
        return (store, provider, source, settingsStore)
    }

    /// A number this app allocated earlier in Testovacia evidencia, kept in the pool.
    @discardableResult
    private func seedNumber(store: ZakoSessionStore, settingsStore: AppSettingsStore) -> String {
        let number = "1563-261118-9"
        let allocatedAt = Date()
        settingsStore.evidenceNumberPool.add(.init(number: number, mode: .test, allocatedAt: allocatedAt))
        store.attestation.evidenceNumber = number
        store.attestation.evidenceNumberAllocatedAt = allocatedAt
        store.attestation.evidenceNumberMode = .test
        return number
    }
}

/// The engine double of an E→E conversion: answers EVIDENCE from a fixture and signs as the
/// one-PDF double does; can refuse the record or the client output and runs a hook when the
/// record or the client output is signed.
private final class E2ERecordFirstProvider: QualifiedSigningProviding, @unchecked Sendable {
    private let signer = SinglePDFRecordingProvider()
    private let lock = NSLock()
    private var received: [SigningRequest] = []
    let payload: Data
    nonisolated(unsafe) var refusesRecord = false
    nonisolated(unsafe) var onClientSigning: (@MainActor () -> Void)?
    nonisolated(unsafe) var onRecordSigning: (@MainActor () -> Void)?

    init(payload: Data) {
        self.payload = payload
    }

    var supportsAppendedClause: Bool { signer.supportsAppendedClause }
    var refusesClient: Bool {
        get { signer.refusesClient }
        set { signer.refusesClient = newValue }
    }
    /// Every request in the order it arrived, refused ones included.
    var requests: [SigningRequest] { lock.withLock { received } }
    var clientRequests: [SigningRequest] { requests.filter { !$0.signsAsRecordContainer } }

    func availableIdentities() async -> [SigningIdentityInfo] { [] }

    func conversionEvidence(for fileURL: URL) async throws -> ConversionEvidence {
        try ConversionEvidence.decode(payloadJSON: payload)
    }

    func sign(_ request: SigningRequest) async throws -> SignedConversionResult {
        lock.withLock { received.append(request) }
        if request.signsAsRecordContainer, let onRecordSigning { await onRecordSigning() }
        if request.signsAsRecordContainer, refusesRecord {
            throw SigningError.signingFailed("Karta bola vybratá počas podpisu záznamu.")
        }
        if !request.signsAsRecordContainer, let onClientSigning { await onClientSigning() }
        return try await signer.sign(request)
    }
}

private final class ConversionCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

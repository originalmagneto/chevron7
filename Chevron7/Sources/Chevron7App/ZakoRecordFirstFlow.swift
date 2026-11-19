// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Kit
import Foundation

/// A conversion under the order of 1. 1. 2027 (`ZakoRegime.recordFirst`) whose record is
/// signed and registered but whose client container is not signed yet. Everything the rest of
/// the conversion needs is kept as it was when the record was signed, so a resume never reads
/// a new server time, allocates a number or renders the record again.
struct RecordFirstPending: Sendable {
    enum Stage: Equatable, Sendable {
        /// The record is sent (or waiting to be sent) and EZZK has not reported it processed.
        case awaitingEZZK
        /// EZZK processed the record; the PDF/A and the clause are signed next.
        case signingClientContainer
    }

    let recordID: UUID
    var stage: Stage
    /// The conversion's direction: the row and the client signature follow it.
    let direction: ConversionDirection
    /// E→E: the SHA-256 of the original's documents in order, as the record names them; a
    /// resume refuses when they changed. Nil for P→E.
    let originalFingerprints: [Data]?
    let mode: AppSettings.EZZKMode
    let evidenceNumber: String
    let conversionTime: Date
    let finalPDF: Data
    let fingerprint: String
    let containerDocumentName: String
    let containerFiles: [ASiCEPackager.Entry]
    let directory: URL
    let stampsSignatures: Bool
    let timestampServers: [String]?
    let tsaURL: String?
    /// The form as it was signed into the record: the clause must say the same.
    let attestation: AttestationData
    /// The client output chosen when the conversion started; a resume never reads the setting.
    let clientOutput: AppSettings.ZakoClientOutput
    /// One PDF: the clause pages and XDC rendered and checked before the record was signed.
    let appendedClause: AppendedClause?
    /// One PDF: the delivered file's name, fixed before the clause and the record named it.
    let fixedTarget: URL?
    /// The client signature's authorities: the record's for the container, the PAdES order
    /// (BOSA first) for one PDF.
    let clientTimestampServers: [String]?
    let clientTSAURL: String?
}

/// The client signature of a record-first conversion failed after EZZK processed the record:
/// the record stays there and the conversion is finished with "Dokončiť konverziu".
struct RecordFirstClientSignatureError: LocalizedError, Equatable {
    let detail: String

    var errorDescription: String? {
        let detail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let sentence = detail.isEmpty || detail.hasSuffix(".") ? detail : detail + "."
        return (sentence.isEmpty ? "" : sentence + " ")
            + "Záznam o konverzii zostáva v EZZK. Kliknite znova na Dokončiť konverziu, alebo začnite novú konverziu."
    }
}

extension ZakoSessionStore {
    static let recordFirstMobileMessage = "Od 1. 1. 2027 sa najprv podpisuje záznam o konverzii, a ten mobil podpísať nevie. Autorizujte kartou."
    static let recordFirstModeChangedMessage = "Táto konverzia začala v inom režime EZZK. Prepnite späť alebo začnite konverziu znova."
    static let recordFirstOriginalChangedMessage = "Pôvodný dokument alebo poradie jeho súborov sa od podpisu záznamu zmenili. Dokončite konverziu s pôvodným stavom alebo začnite novú."
    static let recordFirstFormChangedMessage = "Údaje konverzie sa zmenili po podpise záznamu o konverzii. Doložka musí zodpovedať podpísanému záznamu: vráťte zmeny alebo začnite konverziu znova."
    static let recordFirstWaitStoppedMessage = "Čakanie na EZZK je zastavené. Záznam je odoslaný a Chevron7 ho overuje aj na pozadí. Keď ho EZZK spracuje, podržte Dokončiť konverziu a doložka sa podpíše."
    static let recordFirstTimedOutMessage = "EZZK záznam zatiaľ nespracovalo. Chevron7 ho overuje aj na pozadí; neskôr podržte Dokončiť konverziu a konverzia sa dokončí."
    static let recordFirstSinglePDFPrefixChangedMessage = "Podpísaný PDF nezačína nezmenenou konvertovanou listinou, ktorej odtlačok obsahuje doložka, preto sa neuložil. Záznam o konverzii zostáva v EZZK; kliknite znova na Dokončiť konverziu a dokument sa podpíše znova."
    static let recordFirstSinglePDFIncompleteMessage = "Uložená konverzia nemá pripravenú doložku pre jeden PDF, preto ju nemožno dokončiť. Začnite konverziu znova."
    static let recordFirstRowMismatchMessage = "Riadok Registra konverzií nezodpovedá podpísanému záznamu, preto sa nezapísal. Začnite konverziu znova."
    static let recordFirstMissingRowMessage = "Záznam tejto konverzie sa v Registri konverzií nenašiel, preto ju nemožno dokončiť. Začnite konverziu znova."

    static func recordFirstRejectedMessage(code: Int?, description: String?) -> String {
        let detail = [code.map { "kód \($0)" }, description].compactMap { $0 }.joined(separator: ": ")
        return "EZZK záznam o konverzii odmietlo\(detail.isEmpty ? "" : " (\(detail))"). Doložka sa preto nevytvorí a klient nedostane nič; skontrolujte údaje a začnite konverziu znova."
    }

    /// Signs the record first, registers and sends it, waits until EZZK has processed it, and
    /// only then signs the clause and the PDF/A for the client (§ 36 ods. 3 zákona č.
    /// 305/2013 Z. z. from 1. 1. 2027). A failed record signature leaves no row and keeps the
    /// number in the pool for the next attempt. The caller builds the `.signed` register row
    /// (`makeRow`, with `pending.recordID` as its id), which is asked for only once the record
    /// is signed; a row that cannot be built leaves no row and keeps the number as well.
    func startRecordFirst(_ pending: RecordFirstPending, recordDelivery: ZakoRecordDelivery,
                          identityID: String, makeRow: () throws -> EvidenceRecord) async throws {
        analysisProgressText = "Podpisujem záznam o konverzii…"
        let signedRecord = try await middlewareInput.during(asksEIDForBOK) {
            try await signingProvider.sign(SigningRequest(
                pdfData: recordDelivery.recordXDCF,
                identityID: identityID,
                includeTimestamp: pending.stampsSignatures,
                tsaURL: pending.tsaURL,
                pin: signingPIN.isEmpty ? nil : signingPIN,
                filename: recordDelivery.entryName,
                timestampServers: pending.timestampServers,
                signsAsRecordContainer: true))
        }
        guard let asic = signedRecord.asicData else {
            throw SigningError.signingFailed("Podpis záznamu nevrátil kontajner ASiC-E.")
        }
        let recordCheck = ASiCEContainerVerifier().verify(asic)
        guard recordCheck.isValid else {
            throw ComplianceValidationError(domain: "Kontajner záznamu o konverzii", issues: recordCheck.issues)
        }

        var record = try makeRow()
        do {
            guard record.id == pending.recordID, record.status == .signed else {
                throw SigningError.signingFailed(Self.recordFirstRowMismatchMessage)
            }
            // Held from the first write until the send, so the periodic check cannot send it twice.
            let held = settingsStore.statusChecker.hold(record.id)
            defer { if held { settingsStore.statusChecker.release(record.id) } }
            record.recordContainerPath = try evidenceStore.storeRecordContainer(asic, for: record.id)
            evidenceStore.upsert(record)
        } catch {
            // No row is written: the validation evidence `makeRow` stored beside it goes too.
            if let path = record.validationEvidencePath {
                evidenceStore.removeValidationEvidence(at: path)
            }
            throw error
        }
        // The signed record carries the number from here on, so the pool never offers it again.
        evidenceNumberPool.remove(pending.evidenceNumber)
        // The details signed into the record become the active profile.
        saveProfileFromForm()
        recordFirstPending = pending
        submissionStatus = .signed
        // The wait sends the `.signed` row first, then polls it.
        try await continueRecordFirst()
    }

    /// Picks up a record-first conversion where it stopped: waiting for EZZK, or the client
    /// signature. Refuses when the EZZK mode or the form changed since the record was signed,
    /// and for E→E when the original's documents or their order changed.
    func resumeRecordFirst(viaMobile: Bool) async {
        guard let pending = recordFirstPending else { return }
        if viaMobile {
            lastError = Self.recordFirstMobileMessage
            return
        }
        guard pending.mode == settingsStore.ezzkAccountController.mode else {
            lastError = Self.recordFirstModeChangedMessage
            return
        }
        if pending.direction == .electronicToElectronic,
           electronicOriginal?.documents.map(\.sha256) != pending.originalFingerprints {
            lastError = Self.recordFirstOriginalChangedMessage
            return
        }
        guard Self.formMatches(attestation, signed: pending.attestation) else {
            lastError = Self.recordFirstFormChangedMessage
            return
        }
        do {
            try await continueRecordFirst()
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// "Zastaviť čakanie": the wait ends at its next check; the record stays sent and the
    /// conversion can be finished later with "Autorizovať konverziu".
    func stopWaitingForEZZK() {
        stopWaitingRequested = true
    }

    /// The fields the advocate can still edit on the authorize screen, compared with the form
    /// signed into the record. The evidence number and times come from the pending value.
    static func formMatches(_ current: AttestationData, signed: AttestationData) -> Bool {
        var current = current
        current.evidenceNumber = signed.evidenceNumber
        current.evidenceNumberAllocatedAt = signed.evidenceNumberAllocatedAt
        current.evidenceNumberMode = signed.evidenceNumberMode
        current.conversionExecutionDateTime = signed.conversionExecutionDateTime
        return current == signed
    }

    private func continueRecordFirst() async throws {
        guard var pending = recordFirstPending else { return }
        if pending.stage == .awaitingEZZK {
            guard try await waitUntilEZZKProcessed(pending) else { return }
            pending.stage = .signingClientContainer
            recordFirstPending = pending
        }
        do {
            try await signClientContainer(pending)
        } catch let error as SigningError where Self.recordFirstClientMessagesSayHowToGoOn.contains(error) {
            throw error
        } catch {
            // EZZK holds the processed record: the message says so and how to finish.
            throw RecordFirstClientSignatureError(detail: error.localizedDescription)
        }
    }

    /// Client signature failures whose own message already says what happens next.
    private static var recordFirstClientMessagesSayHowToGoOn: [SigningError] {
        [.signingFailed(recordFirstMissingRowMessage), .signingFailed(recordFirstSinglePDFIncompleteMessage),
         .signingFailed(recordFirstSinglePDFPrefixChangedMessage)]
    }

    /// Polls the row until EZZK reports it processed. Returns false when the wait ended
    /// without it (stopped, timed out, refused); `lastError` then says why.
    private func waitUntilEZZKProcessed(_ pending: RecordFirstPending) async throws -> Bool {
        stopWaitingRequested = false
        isWaitingForEZZK = true
        defer {
            isWaitingForEZZK = false
            stopWaitingRequested = false
        }
        let deadline = Date().addingTimeInterval(recordFirstWaitLimit)
        while true {
            guard let row = evidenceStore.record(id: pending.recordID) else {
                startNewRecordAttempt()
                lastError = Self.recordFirstMissingRowMessage
                return false
            }
            submissionStatus = row.status
            switch row.status {
            case .processed:
                return true
            case .rejected:
                startNewRecordAttempt()
                lastError = Self.recordFirstRejectedMessage(code: row.ezzkResultCode,
                                                            description: row.ezzkResultDescription)
                return false
            case .recordUnsigned:
                startNewRecordAttempt()
                lastError = row.ezzkResultDescription ?? Self.recordFirstMissingRowMessage
                return false
            case .signed, .queuedForSubmission, .submissionFailed, .late:
                // Not sent yet, or EZZK did not know the number after a lost reply: send it
                // (the coordinator never resends an unknown outcome blindly).
                analysisProgressText = "Odosielam záznam do EZZK…"
                let refusal = await submitRecordFirst(pending.recordID)
                if let refusal, evidenceStore.record(id: pending.recordID)?.status.isSubmissionPendingState == true {
                    lastError = refusal
                    return false
                }
            default:
                break
            }
            guard Date() < deadline else {
                lastError = Self.recordFirstTimedOutMessage
                return false
            }
            analysisProgressText = "Čakám, kým EZZK spracuje záznam… (môže to trvať niekoľko minút)"
            // Sleeps in short steps, so "Zastaviť čakanie" and a cancelled task act at once.
            let nextCheck = ContinuousClock.now.advanced(by: recordFirstPollInterval)
            while ContinuousClock.now < nextCheck {
                if stopWaitingRequested || Task.isCancelled {
                    lastError = Self.recordFirstWaitStoppedMessage
                    return false
                }
                let step = min(Duration.seconds(1), ContinuousClock.now.duration(to: nextCheck))
                guard (try? await Task.sleep(for: step)) != nil else {
                    lastError = Self.recordFirstWaitStoppedMessage
                    return false
                }
            }
            if stopWaitingRequested {
                lastError = Self.recordFirstWaitStoppedMessage
                return false
            }
            // A busy row (the periodic check has it) is simply checked again next time.
            _ = await (recordFirstLookup ?? { [settingsStore] id in await settingsStore.statusChecker.verify(id: id) })(pending.recordID)
        }
    }

    /// Sends the row; returns the refusal reason when the checker would not act on it.
    private func submitRecordFirst(_ id: UUID) async -> String? {
        let result = await settingsStore.statusChecker.submit(id: id)
        if case .refused(let reason) = result, reason != EZZKStatusChecker.rowBusyMessage { return reason }
        return nil
    }

    /// Under the order of 1. 1. 2027 the client PDF is signed only after EZZK processed the
    /// record, which spends the number, so the engine's PDF/A-3b check of the appended clause
    /// runs before the record is signed: a failure leaves no row and an unused number.
    func checkAppendedClauseBeforeRecord(source: Data, clause appendedClause: AppendedClause) async throws {
        analysisProgressText = "Kontrolujem PDF/A s doložkou…"
        let runner = pdfClauseCheckRunner
        do {
            try await Task.detached(priority: .userInitiated) {
                try runner.check(source: source, clause: appendedClause)
            }.value
        } catch PdfClauseCheckRunner.Failure.notCompliant(let lines) {
            // The advocate sees the Slovak summary; veraPDF's rules go to the system log.
            Self.logPDFACheckFailure(lines)
            throw PdfClauseCheckRunner.Failure.notCompliant(lines)
        }
    }

    private func signClientContainer(_ pending: RecordFirstPending) async throws {
        guard let identityID = selectedIdentityID else { throw SigningError.identityUnavailable }
        guard evidenceStore.record(id: pending.recordID) != nil else {
            startNewRecordAttempt()
            throw SigningError.signingFailed(Self.recordFirstMissingRowMessage)
        }
        // Held through the signature, so the row cannot be deleted while it is being completed.
        let held = settingsStore.statusChecker.hold(pending.recordID)
        defer { if held { settingsStore.statusChecker.release(pending.recordID) } }
        analysisProgressText = "Autorizujem kvalifikovaným podpisom…"
        let signed: SignedConversionResult
        let deliveredTarget: URL
        if pending.direction == .electronicToElectronic {
            // E→E signs exactly what its order of today signs (`signE2EClientOutput`): the new
            // document with the clause XDCF in an ASiC-E (a kept PDF/A through the engine's
            // signed-source wrapping), or the one PDF with the clause appended.
            let appendedClause: AppendedClause?
            let fixedTarget: URL?
            if pending.clientOutput == .singlePDF {
                // Never the container instead: the record already names the one PDF.
                guard let clause = pending.appendedClause, let target = pending.fixedTarget else {
                    throw SigningError.signingFailed(Self.recordFirstSinglePDFIncompleteMessage)
                }
                // A resume may run with another signer than the one the conversion started with.
                guard signingProvider.supportsAppendedClause else {
                    throw SigningError.signingFailed(ZakoSinglePDFDelivery.engineRefusal)
                }
                appendedClause = clause
                fixedTarget = target
            } else {
                appendedClause = nil
                fixedTarget = nil
            }
            let output = try await signE2EClientOutput(
                newDocument: pending.finalPDF,
                containerDocumentName: pending.containerDocumentName,
                containerFiles: pending.containerFiles,
                appendedClause: appendedClause,
                identityID: identityID,
                stamps: pending.stampsSignatures,
                tsaURL: pending.clientTSAURL,
                timestampServers: pending.clientTimestampServers,
                prefixChangedMessage: Self.recordFirstSinglePDFPrefixChangedMessage)
            signed = output.signed
            analysisProgressText = "Ukladám a zapisujem do evidencie…"
            try FileManager.default.createDirectory(at: pending.directory, withIntermediateDirectories: true)
            deliveredTarget = try Self.deliverE2EClientOutput(output, singlePDFTarget: fixedTarget,
                                                              directory: pending.directory,
                                                              containerDocumentName: pending.containerDocumentName)
        } else if pending.clientOutput == .singlePDF {
            // Never the container instead: the record already names the one PDF.
            guard let appendedClause = pending.appendedClause, let fixedTarget = pending.fixedTarget else {
                throw SigningError.signingFailed(Self.recordFirstSinglePDFIncompleteMessage)
            }
            // A resume may run with another signer than the one the conversion started with.
            guard signingProvider.supportsAppendedClause else {
                throw SigningError.signingFailed(ZakoSinglePDFDelivery.engineRefusal)
            }
            // The engine appends the stored clause to the PDF/A and signs the whole as PAdES.
            signed = try await middlewareInput.during(asksEIDForBOK) {
                try await signingProvider.sign(SigningRequest(
                    pdfData: pending.finalPDF,
                    identityID: identityID,
                    includeTimestamp: pending.stampsSignatures,
                    tsaURL: pending.clientTSAURL,
                    outputFormat: .embeddedPAdES,
                    pin: signingPIN.isEmpty ? nil : signingPIN,
                    filename: pending.containerDocumentName,
                    timestampServers: pending.clientTimestampServers,
                    appendedClause: appendedClause))
            }
            guard Self.singlePDFKeepsSource(signed, source: pending.finalPDF) else {
                throw SigningError.signingFailed(Self.recordFirstSinglePDFPrefixChangedMessage)
            }
            analysisProgressText = "Ukladám a zapisujem do evidencie…"
            try FileManager.default.createDirectory(at: pending.directory, withIntermediateDirectories: true)
            // The record names the fixed file; should a file have taken it meanwhile, the PDF goes
            // beside it under a unique name and never replaces it.
            deliveredTarget = try Self.writeWithoutOverwriting(signed.pdfData, preferred: fixedTarget)
        } else {
            signed = try await middlewareInput.during(asksEIDForBOK) {
                try await signingProvider.sign(SigningRequest(
                    pdfData: pending.finalPDF,
                    identityID: identityID,
                    includeTimestamp: pending.stampsSignatures,
                    tsaURL: pending.clientTSAURL,
                    pin: signingPIN.isEmpty ? nil : signingPIN,
                    extraFiles: pending.containerFiles,
                    filename: pending.containerDocumentName,
                    signsExtraFilesAsDataObjects: true,
                    timestampServers: pending.clientTimestampServers))
            }
            guard let asic = signed.asicData else {
                throw SigningError.signingFailed("Podpis doložky a dokumentu nevrátil kontajner ASiC-E.")
            }
            let containerCheck = ASiCEContainerVerifier().verify(asic)
            guard containerCheck.isValid else {
                throw ComplianceValidationError(domain: "ASiC-E kontajner", issues: containerCheck.issues)
            }

            analysisProgressText = "Ukladám a zapisujem do evidencie…"
            try FileManager.default.createDirectory(at: pending.directory, withIntermediateDirectories: true)
            deliveredTarget = ConversionOutputNaming.uniqueURL(
                in: pending.directory,
                fileName: ConversionOutputNaming.asicFileName(pdfFileName: pending.containerDocumentName))
            try asic.write(to: deliveredTarget, options: [.atomic])
        }
        outputDirectory = pending.directory

        if var row = evidenceStore.record(id: pending.recordID) {
            row.pdfFileName = pending.containerDocumentName
            row.deliveredFileName = deliveredTarget.lastPathComponent
            row.updatedAt = Date()
            evidenceStore.upsert(row)
            submissionStatus = row.status
        }
        recordFirstPending = nil
        lastError = nil
        result = signed
        step = .done
    }
}

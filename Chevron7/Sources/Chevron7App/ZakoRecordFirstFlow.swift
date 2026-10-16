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
}

extension ZakoSessionStore {
    static let recordFirstMobileMessage = "Od 1. 1. 2027 sa najprv podpisuje záznam o konverzii, a ten mobil podpísať nevie. Autorizujte kartou."
    static let recordFirstModeChangedMessage = "Táto konverzia začala v inom režime EZZK. Prepnite späť alebo začnite konverziu znova."
    static let recordFirstFormChangedMessage = "Údaje konverzie sa zmenili po podpise záznamu o konverzii. Doložka musí zodpovedať podpísanému záznamu: vráťte zmeny alebo začnite konverziu znova."
    static let recordFirstWaitStoppedMessage = "Čakanie na EZZK je zastavené. Záznam je odoslaný a Chevron7 ho overuje aj na pozadí. Keď ho EZZK spracuje, kliknite znova na Autorizovať konverziu a doložka sa podpíše."
    static let recordFirstTimedOutMessage = "EZZK záznam zatiaľ nespracovalo. Chevron7 ho overuje aj na pozadí; neskôr kliknite znova na Autorizovať konverziu a konverzia sa dokončí."
    static let recordFirstMissingRowMessage = "Záznam tejto konverzie sa v Registri konverzií nenašiel, preto ju nemožno dokončiť. Začnite konverziu znova."

    static func recordFirstRejectedMessage(code: Int?, description: String?) -> String {
        let detail = [code.map { "kód \($0)" }, description].compactMap { $0 }.joined(separator: ": ")
        return "EZZK záznam o konverzii odmietlo\(detail.isEmpty ? "" : " (\(detail))"). Doložka sa preto nevytvorí a klient nedostane nič; skontrolujte údaje a začnite konverziu znova."
    }

    /// Signs the record first, registers and sends it, waits until EZZK has processed it, and
    /// only then signs the clause and the PDF/A for the client (§ 36 ods. 3 zákona č.
    /// 305/2013 Z. z. from 1. 1. 2027). A failed record signature leaves no row and keeps the
    /// number in the pool for the next attempt.
    func startRecordFirst(_ pending: RecordFirstPending, recordDelivery: ZakoRecordDelivery,
                          formPack: ConversionFormPack, identityID: String,
                          securityReview: SecurityReviewStamp, securityElementCount: Int) async throws {
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

        var record = EvidenceRecord(
            id: pending.recordID,
            status: .signed,
            direction: .paperToElectronic,
            originalName: pending.attestation.originalDocumentName,
            newDocumentName: pending.containerDocumentName,
            evidenceNumber: pending.evidenceNumber,
            fingerprintSHA256Hex: pending.fingerprint,
            attestationXML: recordDelivery.recordXML,
            conversionTime: pending.conversionTime,
            performingPersonName: pending.attestation.performingPerson.fullName,
            securityElementCount: securityElementCount,
            totalPages: analysis.totalPages,
            totalSheets: pending.attestation.numberOfSheets,
            formPack: FormPackStamp(pack: formPack),
            securityReview: securityReview,
            ezzkMode: pending.mode,
            evidenceNumberAllocatedAt: pending.attestation.evidenceNumberAllocatedAt)
        do {
            // Held from the first write until the send, so the periodic check cannot send it twice.
            let held = settingsStore.statusChecker.hold(record.id)
            defer { if held { settingsStore.statusChecker.release(record.id) } }
            record.recordContainerPath = try evidenceStore.storeRecordContainer(asic, for: record.id)
            evidenceStore.upsert(record)
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
    /// signature. Refuses when the EZZK mode or the form changed since the record was signed.
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
        try await signClientContainer(pending)
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
        let signed = try await middlewareInput.during(asksEIDForBOK) {
            try await signingProvider.sign(SigningRequest(
                pdfData: pending.finalPDF,
                identityID: identityID,
                includeTimestamp: pending.stampsSignatures,
                tsaURL: pending.tsaURL,
                pin: signingPIN.isEmpty ? nil : signingPIN,
                extraFiles: pending.containerFiles,
                filename: pending.containerDocumentName,
                signsExtraFilesAsDataObjects: true,
                timestampServers: pending.timestampServers))
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
        let deliveredTarget = ConversionOutputNaming.uniqueURL(
            in: pending.directory,
            fileName: ConversionOutputNaming.asicFileName(pdfFileName: pending.containerDocumentName))
        try asic.write(to: deliveredTarget, options: [.atomic])
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

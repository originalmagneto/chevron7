// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import OSLog
import PDFKit
import Chevron7Kit

/// Whether E→E may run in Ostrá evidencia at all. Off until a conversion has been verified end
/// to end in Testovacia evidencia (owner's condition, 2026-10-16); then it still needs a
/// qualified validation service's report per conversion.
enum E2EProductionPolicy {
    static let enabled = false
    static let refusalMessage = "Zaručenú konverziu elektronického dokumentu Chevron7 v ostrej evidencii zatiaľ nevykonáva: najprv sa overuje v testovacej evidencii. Použite skúšobný režim alebo testovaciu evidenciu."
}

/// Guaranteed conversion of an electronic document to a new electronic document (E→E,
/// § 35 ods. 1 písm. c) and § 36 ods. 4 zákona č. 305/2013 Z. z.). The client's signatures are
/// verified first, the PDF stays byte for byte when it is PDF/A without attachments (else a new
/// PDF/A-2b), and the clause and record follow the official E→E forms. Signing, the register
/// and EZZK are the P→E path. Spec: `docs/superpowers/specs/2026-10-16-zako-e2e-design.md`.
extension ZakoSessionStore {
    static let e2eMobileMessage = "Zaručenú konverziu elektronického dokumentu autorizujte kartou s mandátnym certifikátom."
    static let e2eRecordFirstMessage = "Zaručenú konverziu elektronického dokumentu podľa postupu od 1. 1. 2027 Chevron7 zatiaľ nevykonáva."
    static let e2eNeedsQualifiedValidationMessage = "V ostrej evidencii treba podpisy klienta overiť kvalifikovanou službou validácie (§ 3 ods. 4 vyhlášky č. 70/2021 Z. z.). Pripojte jej výsledok pri overení; službu pridáte v Nastaveniach, EZZK, Rozšírené nastavenia, Kvalifikovaná služba validácie."

    func resetElectronicOriginal() {
        electronicOriginal = nil
        e2eDecision = nil
        isVerifying = false
        verificationError = nil
        undeterminedConfirmed = false
        qualifiedReport = nil
        qualifiedReportConfirmed = false
        qualifiedReportError = nil
        rasterConversionOffered = false
        rasterConversionApproved = false
    }

    /// Ostrá evidencia needs a qualified validation service's sealed output (owner's decision of
    /// 2026-10-16); Demo and Testovacia evidencia keep Chevron7's own validation report.
    var e2eNeedsQualifiedReport: Bool {
        settingsStore.ezzkAccountController.mode == .production
    }

    /// Whether the verification step may hand over to the clause step.
    var canContinueFromVerification: Bool {
        guard electronicOriginal != nil, let decision = e2eDecision else { return false }
        switch decision {
        case .blocked: return false
        case .needsConfirmation: guard undeterminedConfirmed else { return false }
        case .ready: break
        }
        if e2eNeedsQualifiedReport {
            guard let qualifiedReport else { return false }
            return qualifiedReport.binding == .matched || qualifiedReportConfirmed
        }
        return true
    }

    var e2eReadyToAuthorize: Bool {
        canContinueFromVerification
            && !attestation.originalDocumentTypeLabel.trimmingCharacters(in: .whitespaces).isEmpty
            && !attestation.newDocumentName.trimmingCharacters(in: .whitespaces).isEmpty
            && !attestation.performingPerson.fullName.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Opens a signed PDF or an ASiC-E as the original of an E→E conversion and verifies it.
    func loadElectronicOriginal(at url: URL, outputDirectory: URL? = nil, sourceName: String? = nil) async {
        lastError = nil
        resetSession(keepingProfile: true)
        sourceAccessIsActive = url.startAccessingSecurityScopedResource()
        outputDirectoryOverride = outputDirectory
        sourceNameOverride = sourceName
        guard let data = try? Data(contentsOf: url) else {
            lastError = "Súbor sa nepodarilo otvoriť."
            return
        }
        let pdfData = data.starts(with: Data("%PDF".utf8)) ? data : ASiCEContainerVerifier.extractPDFData(data)
        document = pdfData.flatMap(PDFDocument.init(data:))
        documentData = pdfData
        sourceURL = url
        let stem = sourceName ?? url.deletingPathExtension().lastPathComponent
        attestation.originalDocumentName = url.lastPathComponent
        attestation.newDocumentName = stem
        // The clause and the record name the advocate from the active profile, as P→E does.
        attestation.performingPerson = activeProfile()
        attestation.usedDeviceDescription = E2EFormModel.defaultUsedDevice
        step = .verification
        await verifyElectronicOriginal()
    }

    /// Validates the original against the trusted lists and reads what the clause and record
    /// need. A new verification replaces the previous one and every confirmation made on it.
    func verifyElectronicOriginal() async {
        guard let sourceURL, !isVerifying else { return }
        isVerifying = true
        defer { isVerifying = false }
        verificationError = nil
        undeterminedConfirmed = false
        qualifiedReport = nil
        qualifiedReportConfirmed = false
        qualifiedReportError = nil
        rasterConversionOffered = false
        rasterConversionApproved = false
        electronicOriginal = nil
        e2eDecision = nil
        do {
            let evidence = try await IntegrationValidationBroker.shared.run { [signingProvider] in
                try await signingProvider.conversionEvidence(for: sourceURL)
            }
            let data = try Data(contentsOf: sourceURL)
            let original = try ElectronicOriginal.make(sourceName: sourceURL.lastPathComponent, sourceData: data,
                                                       evidence: evidence)
            electronicOriginal = original
            e2eDecision = E2EVerificationGate.decide(original)
        } catch {
            verificationError = error.localizedDescription
        }
    }

    func confirmUndetermined() {
        undeterminedConfirmed = true
    }

    /// Imports a qualified validation service's sealed report for this original.
    func attachQualifiedReport(at url: URL) async {
        guard let original = electronicOriginal else { return }
        qualifiedReportError = nil
        qualifiedReport = nil
        qualifiedReportConfirmed = false
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let sealEvidence = try await IntegrationValidationBroker.shared.run { [signingProvider] in
                try await signingProvider.conversionEvidence(for: url)
            }
            qualifiedReport = try QualifiedValidationReport.accept(reportData: data, fileName: url.lastPathComponent,
                                                                   reportEvidence: sealEvidence, original: original)
        } catch {
            qualifiedReportError = error.localizedDescription
        }
    }

    /// The report shown and stored as the verification evidence: the qualified one when
    /// attached, else Chevron7's ETSI report.
    var validationReportForSaving: (data: Data, fileName: String)? {
        if let qualifiedReport {
            return (qualifiedReport.data, qualifiedReport.fileName)
        }
        guard let original = electronicOriginal else { return nil }
        let stem = (original.sourceName as NSString).deletingPathExtension
        return (original.evidence.etsiReport, "\(stem).overenie.xml")
    }

    /// The body of `authorizeAndSign` for E→E, after its common checks (mode, Demo provider,
    /// register, mandate certificate, regime).
    func authorizeElectronicOriginal(viaMobile: Bool, ezzkMode: AppSettings.EZZKMode) async {
        if viaMobile {
            lastError = Self.e2eMobileMessage
            return
        }
        if ezzkMode == .production, !E2EProductionPolicy.enabled {
            lastError = E2EProductionPolicy.refusalMessage
            return
        }
        // The client output is read once: the whole conversion delivers what was chosen here.
        let deliversSinglePDF = settings.zakoClientOutput == .singlePDF
        // One PDF needs the engine and a card and is not yet run in Ostrá evidencia: refused
        // before anything is converted or a number is allocated.
        if deliversSinglePDF,
           let refusal = ZakoSinglePDFDelivery.refusal(mode: ezzkMode, viaMobile: viaMobile,
                                                       provider: signingProvider) {
            lastError = refusal
            return
        }
        guard let original = electronicOriginal, canContinueFromVerification else {
            lastError = e2eNeedsQualifiedReport && qualifiedReport == nil
                ? Self.e2eNeedsQualifiedValidationMessage
                : "Dokončite overenie podpisov pôvodného dokumentu."
            return
        }
        guard e2eReadyToAuthorize else {
            lastError = "Vyplňte druh dokumentu a názov nového dokumentu."
            return
        }
        // The production gate comes before an evidence number, so none is spent on a refusal.
        if e2eNeedsQualifiedReport, qualifiedReport == nil {
            lastError = Self.e2eNeedsQualifiedValidationMessage
            return
        }
        // § 36 ods. 4 písm. c): the new document, made before an evidence number is allocated so
        // a failed conversion never costs one. A PDF/A without attachments stays byte for byte
        // with the client's signatures; anything else becomes a new PDF/A-2b. One PDF always
        // converts: the clause pages and attachment appended after the client's signatures would
        // leave them reported as changed after signing (spec 2026-11-17, 5.4).
        let keepsOriginal: Bool
        switch original.plan {
        case .keep: keepsOriginal = !deliversSinglePDF
        case .convert: keepsOriginal = false
        }
        let newDocument: Data
        if keepsOriginal {
            newDocument = original.pdfData
        } else {
            analysisProgressText = "Konvertujem do PDF/A…"
            do {
                newDocument = try pdfaFromSignedRunner.convert(original.pdfData, title: attestation.newDocumentName,
                                                                 raster: rasterConversionApproved)
            } catch PdfaFromSignedRunner.Failure.notCompliant {
                rasterConversionOffered = true
                lastError = Self.rasterOfferMessage
                return
            } catch {
                lastError = error.localizedDescription
                return
            }
        }
        let directory = ConversionOutputNaming.outputDirectory(
            sourceURL: sourceURL,
            preferredDirectory: outputDirectoryOverride,
            fallback: settingsStore.outputDirectory)
        var containerDocumentName = ConversionOutputNaming.containerDocumentName(
            newDocumentName: attestation.newDocumentName,
            fallback: attestation.originalDocumentName)
        // One PDF: the delivered file's name is fixed before any clause names it, so clause,
        // record and file agree; a name already taken in the folder (the client's own PDF
        // usually) is never reused.
        let singlePDFTarget: URL?
        if deliversSinglePDF {
            let target = ZakoSinglePDFDelivery.fixedTarget(in: directory, containerDocumentName: containerDocumentName)
            containerDocumentName = target.lastPathComponent
            singlePDFTarget = target
        } else {
            singlePDFTarget = nil
        }
        // Both forms are rendered and checked against the official schemas with a placeholder
        // number before EZZK is asked for a real one, so a form error never costs a number.
        if let issue = dryRunE2EForms(original: original, newDocument: newDocument,
                                      containerDocumentName: containerDocumentName,
                                      deliveredAsSinglePDF: deliversSinglePDF) {
            lastError = issue.advice
            if let detail = issue.technicalDetail {
                Self.e2eLogger.error("E→E form dry run failed: \(detail, privacy: .public)")
            }
            return
        }
        if needsFreshEvidenceNumber {
            analysisProgressText = "Získavam evidenčné číslo z EZZK…"
            attestation.evidenceNumber = nil
            attestation.evidenceNumberAllocatedAt = nil
            attestation.evidenceNumberMode = nil
            evidenceNumberError = nil
            await fetchEvidenceNumber()
            guard !needsFreshEvidenceNumber else {
                if lastError == nil { lastError = evidenceNumberError ?? AttestationValidationError.missingEvidenceNumber.errorDescription }
                return
            }
        }

        do {
            analysisProgressText = "Zisťujem dôveryhodný čas…"
            let conversionTime = try await ezzkService.serverTime()
            guard EZZKEvidenceNumberPolicy.isUsable(allocatedAt: attestation.evidenceNumberAllocatedAt,
                                                    at: conversionTime) else {
                evidenceNumberError = EZZKError.evidenceNumberExpired.errorDescription
                throw EZZKError.evidenceNumberExpired
            }
            let regime = ZakoRegime.resolve(conversionTime: conversionTime, mode: ezzkMode,
                                            preview: settings.zakoRecordFirstPreview)
            if regime.regime == .recordFirst {
                lastError = Self.e2eRecordFirstMessage
                return
            }
            serverTimeUsed = conversionTime
            attestation.conversionExecutionDateTime = conversionTime

            analysisProgressText = "Vytváram osvedčovaciu doložku…"
            let model = try E2EFormModel.make(original: original, attestation: attestation,
                                              newDocumentName: containerDocumentName, newDocumentData: newDocument,
                                              usedDevice: attestation.usedDeviceDescription,
                                              qualifiedReport: qualifiedReport?.data,
                                              deliveredAsSinglePDF: deliversSinglePDF)
            let builder = E2EDeliveryBuilder()
            let clause: E2EDeliveryBuilder.Clause
            let recordDelivery: ZakoRecordDelivery
            do {
                clause = try builder.clause(model)
                recordDelivery = try builder.record(model)
            } catch {
                // Passed with the placeholder; the number stays in the pool for the next try.
                let issue = E2EFormIssue.from(error)
                lastError = issue.advice
                return
            }

            // One PDF: the clause's readable pages, rendered from the very clause XML that is
            // attached, before anything is signed.
            let appendedClause: AppendedClause?
            if deliversSinglePDF {
                analysisProgressText = "Pripravujem strany osvedčovacej doložky…"
                appendedClause = try await ZakoSinglePDFDelivery.appendedClause(
                    clauseXML: Data(clause.xml.utf8),
                    clauseXDCF: clause.xdcf,
                    clauseFileName: ConversionOutputNaming.containerClauseName(evidenceNumber: attestation.evidenceNumber),
                    form: .clauseE2E_1_3,
                    renderer: clausePageRenderer)
            } else {
                appendedClause = nil
            }

            analysisProgressText = "Autorizujem kvalifikovaným podpisom…"
            if isCertificateTypePending {
                analysisProgressText = "Overujem certifikát na karte…"
                let resolved = await middlewareInput.during(asksEIDForBOK) {
                    await signingProvider.resolveIdentities(pin: signingPIN)
                }
                guard let resolved, !resolved.isEmpty else { throw SigningError.identityUnavailable }
                identities = resolved
                selectedIdentityID = resolved.first(where: { $0.isMandateCertificate })?.id ?? resolved.first?.id
            }
            if requiresMandateOverride {
                lastError = "Zvolený certifikát nie je mandátnym certifikátom pre zaručenú konverziu. Pokračovanie je možné len s výslovným override (audit záznam)."
                return
            }
            guard let identityID = selectedIdentityID else { throw SigningError.identityUnavailable }
            // The record is XAdES; the one PDF is PAdES and keeps the PAdES order (BOSA first).
            let timestamps = try zakoTimestampChoice()

            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let signed: SignedConversionResult
            let asic: Data?
            if let appendedClause {
                // The engine appends the clause to the PDF/A and signs the whole as PAdES.
                let clientTimestamps = try zakoTimestampChoice(signsPAdES: true)
                signed = try await middlewareInput.during(asksEIDForBOK) {
                    try await signingProvider.sign(SigningRequest(
                        pdfData: newDocument,
                        identityID: identityID,
                        includeTimestamp: clientTimestamps.stamps,
                        tsaURL: clientTimestamps.tsaURL,
                        outputFormat: .embeddedPAdES,
                        pin: signingPIN.isEmpty ? nil : signingPIN,
                        filename: containerDocumentName,
                        timestampServers: clientTimestamps.servers,
                        appendedClause: appendedClause))
                }
                // The clause fingerprints the new document, so the signed file must begin with
                // exactly those bytes (revision 1) and carry the clause and signature after them.
                guard Self.singlePDFKeepsSource(signed, source: newDocument) else {
                    throw SigningError.signingFailed(Self.singlePDFPrefixChangedMessage)
                }
                asic = nil
            } else {
                let containerFiles = ASiCEPackager().zakoContainer(
                    pdfData: newDocument,
                    pdfFileName: containerDocumentName,
                    dolozkaXML: clause.xdcf,
                    dolozkaFileName: ConversionOutputNaming.containerClauseName(evidenceNumber: attestation.evidenceNumber))
                signed = try await middlewareInput.during(asksEIDForBOK) {
                    try await signingProvider.sign(SigningRequest(
                        pdfData: newDocument,
                        identityID: identityID,
                        includeTimestamp: timestamps.stamps,
                        tsaURL: timestamps.tsaURL,
                        pin: signingPIN.isEmpty ? nil : signingPIN,
                        extraFiles: containerFiles,
                        filename: containerDocumentName,
                        signsExtraFilesAsDataObjects: true,
                        timestampServers: timestamps.servers))
                }
                guard let container = signed.asicData else {
                    throw SigningError.signingFailed("Podpis nevrátil kontajner ASiC-E.")
                }
                let containerCheck = ASiCEContainerVerifier().verify(container)
                guard containerCheck.isValid else {
                    throw ComplianceValidationError(domain: "ASiC-E kontajner", issues: containerCheck.issues)
                }
                asic = container
            }
            if let number = attestation.evidenceNumber {
                evidenceNumberPool.remove(number)
            }
            saveProfileFromForm()

            analysisProgressText = "Ukladám a zapisujem do evidencie…"
            let deliveredTarget: URL
            if let singlePDFTarget {
                // The name was fixed before the clause; should a file have taken it meanwhile,
                // the PDF goes beside it under a unique name and never replaces it.
                deliveredTarget = try Self.writeWithoutOverwriting(signed.pdfData, preferred: singlePDFTarget)
            } else if let asic {
                deliveredTarget = ConversionOutputNaming.uniqueURL(
                    in: directory,
                    fileName: ConversionOutputNaming.asicFileName(pdfFileName: containerDocumentName))
                try asic.write(to: deliveredTarget, options: [.atomic])
            } else {
                throw SigningError.signingFailed("Podpis nevrátil kontajner ASiC-E.")
            }
            outputDirectory = directory

            var record = EvidenceRecord(
                id: currentRecordID,
                status: .signed,
                direction: .electronicToElectronic,
                originalName: attestation.originalDocumentName,
                newDocumentName: containerDocumentName,
                evidenceNumber: attestation.evidenceNumber,
                fingerprintSHA256Hex: model.newDocument.sha256.map { String(format: "%02x", $0) }.joined(),
                attestationXML: recordDelivery.recordXML,
                conversionTime: conversionTime,
                performingPersonName: attestation.performingPerson.fullName,
                securityElementCount: 0,
                totalPages: document?.pageCount ?? 0,
                totalSheets: 0,
                pdfFileName: containerDocumentName,
                deliveredFileName: deliveredTarget.lastPathComponent,
                ezzkMode: attestation.evidenceNumberMode ?? ezzkMode,
                evidenceNumberAllocatedAt: attestation.evidenceNumberAllocatedAt,
                clientOutput: deliversSinglePDF ? .singlePDF : nil,
                // Revision 1 of the one PDF is the fingerprinted new document: a reader cuts it here.
                revisionOneLength: deliversSinglePDF ? newDocument.count : nil)
            if let qualifiedReport {
                record.validationEvidencePath = try evidenceStore.storeValidationEvidence(
                    qualifiedReport.data, fileExtension: qualifiedReport.fileExtension, for: record.id)
                record.validationEvidenceSource = "Kvalifikovaná služba validácie: \(qualifiedReport.sealSubject)"
            } else {
                record.validationEvidencePath = try evidenceStore.storeValidationEvidence(
                    original.evidence.etsiReport, fileExtension: "xml", for: record.id)
                record.validationEvidenceSource = "Chevron7 (DSS \(original.evidence.dssVersion))"
            }

            let rowID = record.id
            let held = settingsStore.statusChecker.hold(rowID)
            evidenceStore.upsert(record)
            do {
                defer { if held { settingsStore.statusChecker.release(rowID) } }
                analysisProgressText = "Podpisujem záznam o konverzii…"
                do {
                    let signedRecord = try await middlewareInput.during(asksEIDForBOK) {
                        try await signingProvider.sign(SigningRequest(
                            pdfData: recordDelivery.recordXDCF,
                            identityID: identityID,
                            includeTimestamp: timestamps.stamps,
                            tsaURL: timestamps.tsaURL,
                            pin: signingPIN.isEmpty ? nil : signingPIN,
                            filename: recordDelivery.entryName,
                            timestampServers: timestamps.servers,
                            signsAsRecordContainer: true))
                    }
                    guard let recordASiC = signedRecord.asicData else {
                        throw SigningError.signingFailed("Podpis záznamu nevrátil kontajner ASiC-E.")
                    }
                    let recordCheck = ASiCEContainerVerifier().verify(recordASiC)
                    guard recordCheck.isValid else {
                        throw ComplianceValidationError(domain: "Kontajner záznamu o konverzii", issues: recordCheck.issues)
                    }
                    record.recordContainerPath = try evidenceStore.storeRecordContainer(recordASiC, for: record.id)
                } catch {
                    record.status = .recordUnsigned
                    record.ezzkResultDescription = error.localizedDescription
                    evidenceStore.upsert(record)
                    submissionStatus = .recordUnsigned
                    lastError = Self.recordUnsignedMessage(error)
                    result = signed
                    step = .done
                    return
                }
                evidenceStore.upsert(record)
            }

            analysisProgressText = "Odosielam záznam do EZZK…"
            await sendRecord(record.id)
            result = signed
            step = .done
        } catch {
            lastError = error.localizedDescription
        }
    }

    static let rasterOfferMessage = "Prevod do PDF/A nevytvoril platné PDF/A (zvyčajne pre písma, ktoré dokument nevkladá). Môžete použiť rastrový PDF/A: strany sa uložia ako obrázky a text sa nebude dať označiť."
    static let e2eLogger = Logger(subsystem: "app.slovensko.chevron7", category: "ZaKo")

    /// The clause and the record rendered and schema-validated with a placeholder number and
    /// the Mac's clock: nil when both pass, else the advice for the advocate.
    func dryRunE2EForms(original: ElectronicOriginal, newDocument: Data,
                        containerDocumentName: String, deliveredAsSinglePDF: Bool = false) -> E2EFormIssue? {
        var draft = attestation
        draft.evidenceNumber = "0000-000000-0"
        draft.conversionExecutionDateTime = Date()
        do {
            let model = try E2EFormModel.make(original: original, attestation: draft,
                                              newDocumentName: containerDocumentName, newDocumentData: newDocument,
                                              usedDevice: draft.usedDeviceDescription,
                                              qualifiedReport: qualifiedReport?.data,
                                              deliveredAsSinglePDF: deliveredAsSinglePDF)
            let builder = E2EDeliveryBuilder()
            _ = try builder.clause(model)
            _ = try builder.record(model)
            return nil
        } catch {
            return E2EFormIssue.from(error)
        }
    }

    /// The timestamp authorities of a ZaKo signature: in Demo the switch and the chosen
    /// authority, outside Demo the built-in qualified ones, Sectigo first and BOSA last for
    /// XAdES, BOSA first for PAdES (`signsPAdES`, the one PDF).
    func zakoTimestampChoice(signsPAdES: Bool = false) throws -> (stamps: Bool, servers: [String]?, tsaURL: String?) {
        let stamps = usesQualifiedTimestamp
        if settingsStore.ezzkAccountController.isDemoMode {
            if stamps, settings.selectedTSAURL.trimmingCharacters(in: .whitespaces).isEmpty {
                throw SigningError.timestampFailed
            }
            return (stamps, nil, stamps ? settings.timestampAuthority(signsXAdES: !signsPAdES).url : nil)
        }
        // A PAdES signature (the one PDF) keeps BOSA first, which slovensko.sk sees in PAdES;
        // XAdES puts Sectigo first because slovensko.sk does not see a BOSA timestamp there.
        let qualified = (signsPAdES ? TimestampAuthority.zakoPAdESQualifiedURLs
                                    : TimestampAuthority.zakoQualifiedURLs).map(\.absoluteString)
        guard let first = qualified.first else { throw SigningError.timestampFailed }
        return (stamps, qualified, first)
    }
}

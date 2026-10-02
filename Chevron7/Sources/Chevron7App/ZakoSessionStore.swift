// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import PDFKit
import SwiftUI
import Chevron7Kit

@MainActor
@Observable
final class ZakoSessionStore {
    enum Step: Int, CaseIterable { case intake = 0, analysis = 1, attestation = 2, authorize = 3, done = 4 }

    var step: Step = .intake
    var sourceURL: URL?
    var document: PDFDocument?
    var documentData: Data?
    let exampleBank: ExampleBank
    var bankRecorderFactory: (ExampleBank, String) -> ExampleBankRecorder = { bank, version in
        ExampleBankRecorder(bank: bank, detectorVersion: version)
    }
    private var learnedSourceCache: (id: String, source: LearnedCandidateSource)?
    var detectionPipelineFactory: (AppSettings, ExampleBank) -> DetectionPipeline = { settings, bank in
        ZakoSessionStore.buildPipeline(settings: settings, bank: bank)
    }
    private(set) var detectorIdentifier: String = LayeredDetectionProvider(
        classifier: TwoStageClassifier(primary: NoOpClassifier(), secondary: nil)).identifier
    private var bankWork: Task<Void, Never>?
    private var resettingSecurityReview = false
    private var blankPagesWithConfirmedElements: Set<Int> = []
    private var bankWarningShown = false
    var analysis: DocumentAnalysis = .empty()
    var securityElements: [SecurityElement] = [] {
        didSet { securityElementsChanged(from: oldValue) }
    }
    var reviewedNonEmptyPages: Set<Int> = []
    var attestation = AttestationData()
    var sheetMethod: SheetCountingMethod = .duplexEstimate
    var manualSheetCount: Int?

    var isAnalyzing = false
    var analysisProgressText = ""
    /// Text-rule suggestion for the clause's document kind, from embedded text
    /// or one scan OCR pass. Shown as a one-tap chip, never written without confirmation.
    var suggestedDocumentKind: String?

    enum AIVisionReadiness: Equatable, Sendable {
        case builtInOnly(mode: AppSettings.AIMode)
        case ready(provider: AppSettings.AIMode)
        case unavailable(provider: AppSettings.AIMode, reason: String)

        var message: String {
            switch self {
            case .builtInOnly:
                return "Používa sa iba vstavaná on-device detekcia."
            case .ready(let provider):
                return "Konfigurácia \(provider.rawValue) je pripravená."
            case .unavailable(let provider, let reason):
                return "LLM \(provider.rawValue) nie je dostupné: \(reason) Vstavaná detekcia zostáva aktívna."
            }
        }
    }

    var aiVisionReadiness: AIVisionReadiness {
        Self.aiVisionReadiness(for: settings)
    }

    var analysisWarning: String?

    var identities: [SigningIdentityInfo] = []
    var selectedIdentityID: String?
    var includeQualifiedTimestamp = true
    /// The QTS switch exists only in Demo. Outside Demo both ZaKo signatures (client container
    /// and record) always carry a timestamp from the built-in qualified authorities.
    var showsQualifiedTimestampToggle: Bool { settingsStore.ezzkAccountController.isDemoMode }
    /// Whether the ZaKo signatures get a timestamp: the switch in Demo, always outside it, and
    /// always with the engine, which refuses Baseline B for ordinary files.
    var usesQualifiedTimestamp: Bool {
        showsQualifiedTimestampToggle ? includeQualifiedTimestamp || signingProvider.alwaysAddsQualifiedTimestamp : true
    }
    var allowNonMandateOverride = false
    private var mandateOverrideIdentityID: String?
    /// Kept for the whole app run once typed (the owner's choice), only in memory; cleared
    /// when the card leaves the reader or the card refuses it, so it never reaches another card.
    var signingPIN = ""
    /// What CryptoTokenKit reports about the inserted card, read without a PIN.
    private(set) var mandateCardState: MandateCertificate.CardState = .noCard
    /// Reads `mandateCardState`; tests substitute it.
    var readMandateCardState: () -> MandateCertificate.CardState = { MandateCertificate.currentCardState() }
    /// The card step the view presents while a guarded action waits for it.
    var cardPrompt: ZakoCardPrompt?
    /// The action the card flow completes once the mandate certificate is confirmed.
    var pendingCardAction: ZakoCardAction?
    private var isRefreshingIdentities = false
    private(set) var isResolvingCertificate = false
    var certificateLoadError: String?
    private var lastCertificateLoadPIN: String?
    var evidenceNumberRequested = false
    var fetchingEvidenceNumber = false
    var evidenceNumberError: String?
    var isAuthorizing = false
    private var reviewUpdatedAt: Date?

    var activeTool: SecurityElement.Kind?
    var previewPageIndex: Int = 0
    var lastDeletedElement: (SecurityElement, Int)?
    var selectedElementID: UUID?

    var snapper: any SegmentationSnapping = SegmentationSnapper()
    var snapAssetProgress: Double?
    var snapUnavailableReason: String?
    private var snapAssetsReady = false

    var validationErrors: [AttestationValidationError] = []
    var preflightErrors: [AttestationValidationError] = []
    var result: SignedConversionResult?
    /// The row state `lastError` describes (the last send, verify or signing outcome).
    var submissionStatus: EvidenceRecord.Status?
    var outputDirectory: URL?
    var lastError: String?
    let mobileSigning: MobileSigningCoordinator
    private(set) var isAuthorizingViaMobile = false

    static let mobileMandateRefusalMessage =
        "Podpis z mobilu nebol vytvorený mandátnym certifikátom. Zaručená konverzia vyžaduje mandátny certifikát advokáta, konverzia nebola autorizovaná a do evidencie sa nič nezapísalo."

    /// Signing the record, checking its container or storing it in the register failed:
    /// the client outputs exist, nothing was sent.
    static func recordUnsignedMessage(_ error: Error) -> String {
        "Dokumenty pre klienta sú podpísané a uložené, ale záznam o konverzii sa nepodarilo podpísať alebo uložiť: \(error.localizedDescription) Do EZZK sa nič neodoslalo. Záznam podpíšte znova novou konverziou; opakovaný podpis z Registra príde neskôr."
    }

    static let recordFromOtherModeMessage = EZZKStatusChecker.recordFromOtherModeMessage

    static let mobileOutsideDemoMessage =
        "Zaručenú konverziu s EZZK podpisujte kartou SAK. Podpis z mobilu je zatiaľ dostupný iba v režime Demo."

    var isMobileSigningAvailable: Bool {
        settings.mobileSigningEnabled && !signingProviderIsDemo && settingsStore.ezzkAccountController.isDemoMode
    }

    /// True when the user turned mobile signing on but the phone path is unavailable because
    /// EZZK is outside Demo mode: the button (`isMobileSigningAvailable`) hides in that case, so
    /// the view shows this notice instead of nothing.
    var showsMobileOutsideDemoNotice: Bool {
        settings.mobileSigningEnabled && !settingsStore.ezzkAccountController.isDemoMode
    }

    /// Preflight for the mobile path: the certificate is known only after the phone
    /// signs, so identity and mandate checks move to the post-signature refusal.
    var isMobilePreflightComplete: Bool {
        let result = AttestationPreflight.evaluate(
            attestation,
            securityElements: securityElements,
            hasSelectedIdentity: true,
            mandateRequirementSatisfied: true,
            inputSignatureInspection: inputSignatureInspection,
            unreviewedNonEmptyPages: unreviewedNonEmptyPages, documentPageCount: analysis.totalPages)
        return result.errors.allSatisfy { $0 == .missingEvidenceNumber } && result.unreviewedNonEmptyPages.isEmpty
            && preflightErrors.isEmpty
    }
    var serverTimeUsed: Date?
    var inputSignatureInspection = InputSignatureInspectionResult.unavailable(
        detail: "Kontrola podpisov ešte neprebehla.")

    var isPreflightComplete: Bool {
        let result = AttestationPreflight.evaluate(
            attestation,
            securityElements: securityElements,
            hasSelectedIdentity: selectedIdentityID != nil,
            mandateRequirementSatisfied: mandateRequirementSatisfied
                || hasValidMandateOverride
                || isCertificateTypePending,
            inputSignatureInspection: inputSignatureInspection,
            unreviewedNonEmptyPages: unreviewedNonEmptyPages, documentPageCount: analysis.totalPages)
        return result.isComplete && preflightErrors.isEmpty && evidenceNumberError == nil
    }
    var hasUnresolvedPreflightErrors: Bool {
        !AttestationPreflight.evaluate(
            attestation,
            securityElements: securityElements,
            hasSelectedIdentity: selectedIdentityID != nil,
            mandateRequirementSatisfied: mandateRequirementSatisfied,
            inputSignatureInspection: inputSignatureInspection,
            unreviewedNonEmptyPages: unreviewedNonEmptyPages, documentPageCount: analysis.totalPages
        ).errors.filter { $0 != .missingEvidenceNumber }.isEmpty
    }

    /// No number yet, or one this conversion may not use (another EZZK mode, or allocated on
    /// an earlier Bratislava day, after which EZZK no longer holds it).
    var needsFreshEvidenceNumber: Bool {
        guard let number = attestation.evidenceNumber, !number.isEmpty else { return true }
        if evidenceNumberModeError != nil { return true }
        return !EZZKEvidenceNumberPolicy.isUsable(allocatedAt: attestation.evidenceNumberAllocatedAt, at: Date())
    }

    var pendingSecurityElementCount: Int {
        securityElements.filter { $0.reviewState == .pending }.count
    }

    var confirmedSecurityElements: [SecurityElement] {
        securityElements.filter { $0.reviewState == .confirmed }
    }

    var securityReviewStamp: SecurityReviewStamp {
        SecurityReviewStamp(
            checkedNonEmptyPageIndices: Array(reviewedNonEmptyPages),
            confirmedElementCount: confirmedSecurityElements.count,
            rejectedElementCount: securityElements.filter { $0.reviewState == .rejected }.count,
            elementDecisions: securityElements.map {
                SecurityReviewElement(id: $0.id, state: $0.reviewState,
                                      kind: $0.kind, pageIndex: $0.pageIndex,
                                      boundingBox: $0.boundingBox, observation: $0.observation,
                                      verbalDescription: $0.verbalDescription, originalLocation: $0.originalLocation,
                                      newDocumentPageIndex: $0.newDocumentPageIndex)
            },
            detectorIdentifier: detectorIdentifier,
            reviewedAt: reviewUpdatedAt ?? Date(), noElementsConfirmed: attestation.noSecurityElementsConfirmed)
    }

    var unreviewedNonEmptyPages: [Int] {
        analysis.pageAnalyses
            .filter { !$0.isEmpty && !reviewedNonEmptyPages.contains($0.pageIndex) }
            .map(\.pageIndex)
    }

    let settingsStore: AppSettingsStore
    var settings: AppSettings { settingsStore.settings }
    let pdfaConverter: PDFAConverter
    let embeddedFileService: EmbeddedFileService
    let formPackRepository: FormPackRepository
    private(set) var selectedFormPack: ConversionFormPack
    var ezzkService: any EZZKServicing { settingsStore.ezzkService }
    /// The refusal for a number obtained in another EZZK mode than the one now selected,
    /// or nil. Purely local: it never calls EZZK.
    var evidenceNumberModeError: String? {
        guard attestation.evidenceNumber != nil,
              !EZZKEvidenceNumberPolicy.isFromCurrentMode(
                  numberMode: attestation.evidenceNumberMode,
                  currentMode: settingsStore.ezzkAccountController.mode) else { return nil }
        return EZZKError.evidenceNumberFromOtherMode.errorDescription
    }
    /// A warning, not a blocker: EZZK reports a record whose person differs from the account.
    var ezzkIdentityWarning: String? {
        guard !settingsStore.ezzkAccountController.isDemoMode else { return nil }
        return EZZKEvidenceNumberPolicy.identityMismatch(
            clausePerson: attestation.performingPerson,
            accountName: settings.ezzkPersonName,
            accountICO: settings.ezzkICO)
    }
    var signingProvider: any QualifiedSigningProviding { settingsStore.signingProvider }
    var evidenceStore: LocalEvidenceStore { settingsStore.evidenceStore }
    var evidenceNumberPool: EvidenceNumberPool { settingsStore.evidenceNumberPool }

    private var evidenceRequestID: UUID?
    private var sourceAccessIsActive = false
    private var outputDirectoryOverride: URL?
    private var sourceNameOverride: String?
    var profilePersister: ((AdvocateProfile) -> Void)?
    private(set) var currentRecordID = UUID()

    init(settingsStore: AppSettingsStore,
         formPackRepository: FormPackRepository = FormPackRepository(),
         exampleBank: ExampleBank? = nil,
         mobileSigning: MobileSigningCoordinator? = nil) {
        self.settingsStore = settingsStore
        self.mobileSigning = mobileSigning ?? MobileSigningCoordinator(settingsStore: settingsStore)
        self.pdfaConverter = PDFAConverter()
        self.embeddedFileService = EmbeddedFileService()
        self.formPackRepository = formPackRepository
        // A bank of its own on the settings store root, as before; the app passes the shared one.
        self.exampleBank = exampleBank ?? ExampleBank(directory: settingsStore.exampleBankDirectory)
        self.selectedFormPack = formPackRepository.packs.first {
            $0.direction == .paperToElectronic && $0.isActive(at: Date())
        } ?? FormPackRepository.currentLegacyUnverified
        self.currentRecordID = UUID()
        self.profilePersister = { [weak settingsStore] profile in
            guard let settingsStore else { return }
            if let index = settingsStore.settings.profiles.firstIndex(where: { $0.id == profile.id }) {
                settingsStore.settings.profiles[index] = profile
            } else {
                settingsStore.settings.profiles.append(profile)
            }
            settingsStore.settings.activeProfileID = profile.id
        }
    }

    static func aiVisionReadiness(for settings: AppSettings) -> AIVisionReadiness {
        func validEndpoint(_ rawValue: String) -> Bool {
            guard let url = URL(string: rawValue.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  url.host != nil else {
                return false
            }
            return true
        }

        func missing(_ values: [(String, Bool)]) -> String? {
            values.first(where: { !$0.1 })?.0
        }

        switch settings.aiMode {
        case .builtInOnDevice, .disabled:
            return .builtInOnly(mode: settings.aiMode)
        case .omlxLocal:
            if let reason = missing([
                ("URL", validEndpoint(settings.omlxURL)),
                ("model", !settings.omlxModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            ]) {
                return .unavailable(provider: .omlxLocal, reason: "Doplňte \(reason).")
            }
            return .ready(provider: .omlxLocal)
        case .ollamaLocal:
            if let reason = missing([
                ("URL", validEndpoint(settings.ollamaURL)),
                ("model", !settings.ollamaModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            ]) {
                return .unavailable(provider: .ollamaLocal, reason: "Doplňte \(reason).")
            }
            return .ready(provider: .ollamaLocal)
        case .customAPIKey:
            if let reason = missing([
                ("Base URL", validEndpoint(settings.openAICompatibleBaseURL)),
                ("model", !settings.openAICompatibleModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                ("API kľúč v Kľúčenke", !(KeychainStore.load(account: "ai.apikey") ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            ]) {
                return .unavailable(provider: .customAPIKey, reason: "Doplňte \(reason).")
            }
            return .ready(provider: .customAPIKey)
        }
    }

    /// The registry's active model, loaded once per model id. A missing or
    /// unloadable model means detection runs without the learned source:
    /// detection must never break because of an optional stage.
    private func loadActiveLearnedSource() async -> LearnedCandidateSource? {
        let bankDir = await exampleBank.directory
        let registry = ModelRegistry(root: ModelRegistry.modelsDirectory(in: bankDir))
        guard let id = try? registry.activeModelID() else { return nil }
        if let cached = learnedSourceCache, cached.id == id { return cached.source }
        guard let model = try? LearnedModelLoader.load(at: registry.activeCompiledURL()) else { return nil }
        let source = LearnedCandidateSource(modelID: id,
                                            predict: LearnedCandidateSource.coreMLPredictor(model: model))
        learnedSourceCache = (id, source)
        return source
    }

    /// Drops the cached source so the next analysis picks up a newly
    /// promoted or rolled-back model.
    func forgetLearnedSourceCache() { learnedSourceCache = nil }

    static func buildPipeline(settings: AppSettings, bank: ExampleBank) -> DetectionPipeline {
        let llmProvider: (any SecurityElementsProviding)?
        switch settings.aiMode {
        case .omlxLocal:
            if case .ready = aiVisionReadiness(for: settings),
               let endpoint = URL(string: settings.omlxURL) {
                llmProvider = OpenAIVisionProvider(
                    baseURL: endpoint,
                    model: settings.omlxModel,
                    apiKey: "",
                    promptOverride: settings.aiPrompt)
            } else {
                llmProvider = nil
            }
        case .ollamaLocal:
            if case .ready = aiVisionReadiness(for: settings),
               let endpoint = URL(string: settings.ollamaURL) {
                llmProvider = OllamaVisionProvider(
                    endpoint: endpoint,
                    model: settings.ollamaModel,
                    promptOverride: settings.aiPrompt)
            } else {
                llmProvider = nil
            }
        case .customAPIKey:
            if case .ready = aiVisionReadiness(for: settings),
               let apiKey = KeychainStore.load(account: "ai.apikey"),
               let baseURL = URL(string: settings.openAICompatibleBaseURL) {
                llmProvider = OpenAIVisionProvider(
                    baseURL: baseURL,
                    model: settings.openAICompatibleModel,
                    apiKey: apiKey,
                    promptOverride: settings.aiPrompt)
            } else {
                llmProvider = nil
            }
        case .builtInOnDevice, .disabled:
            llmProvider = nil
        }
        let layered = LayeredDetectionProvider.makeDefault(bank: bank, useFoundationModel: settings.useFoundationModelClassifier)
        return DetectionPipeline(builtin: layered, llmProvider: llmProvider)
    }

    var effectiveSheetCount: Int {
        switch sheetMethod {
        case .manual:
            return max(manualSheetCount ?? 0, 0)
        case .oneSheetPerPage:
            return analysis.nonEmptyPages
        case .duplexEstimate:
            return analysis.estimatedSheetsDuplex
        }
    }

    func loadDocument(at url: URL,
                      outputDirectory: URL? = nil,
                      sourceName: String? = nil) async {
        lastError = nil
        resetSession(keepingProfile: true)
        sourceAccessIsActive = url.startAccessingSecurityScopedResource()
        outputDirectoryOverride = outputDirectory
        sourceNameOverride = sourceName

        let document: PDFDocument?
        if url.pathExtension.lowercased() == "asice",
           let data = try? Data(contentsOf: url),
           let pdfData = ASiCEContainerVerifier.extractPDFData(data) {
            document = PDFDocument(data: pdfData)
        } else {
            document = PDFDocument(url: url)
        }
        guard let document else {
            if sourceAccessIsActive {
                url.stopAccessingSecurityScopedResource()
                sourceAccessIsActive = false
            }
            lastError = "Súbor sa nepodarilo otvoriť ako PDF."
            return
        }
        self.document = document
        self.documentData = (try? Data(contentsOf: url)).flatMap {
            url.pathExtension.lowercased() == "asice" ? ASiCEContainerVerifier.extractPDFData($0) : $0
        }
        self.sourceURL = url
        step = .analysis
        await runAnalysis(recallingReviewedPages: true)
    }

    /// Detects security elements on the loaded document. Opening a document
    /// recalls its complete page reviews from the example bank in place of fresh
    /// detection on those pages; "Znova analyzovať AI" asks the detector again.
    func runAnalysis(recallingReviewedPages: Bool = false) async {
        guard let document else { return }
        let analysisRecordID = currentRecordID
        attestation.noSecurityElementsConfirmed = false
        isAnalyzing = true
        analysisProgressText = "Analyzujem stránky…"
        let doc = UncheckedSendable(document)
        let baseAnalysis = await Task.detached(priority: .userInitiated) {
            let engine = PDFAnalysisEngine()
            return engine.analyze(document: doc.value)
        }.value ?? .empty()
        guard analysisRecordID == currentRecordID, !Task.isCancelled else { return }

        analysisProgressText = "Detegujem bezpečnostné prvky…"
        let selectedSettings = settings
        let readiness = Self.aiVisionReadiness(for: selectedSettings)
        analysisWarning = {
            if case .unavailable = readiness {
                return readiness.message
            }
            return nil
        }()
        var pipeline = detectionPipelineFactory(selectedSettings, exampleBank)
        if var layered = pipeline.builtin as? LayeredDetectionProvider {
            layered = layered.withLearnedSource(await loadActiveLearnedSource())
            detectorIdentifier = layered.identifier
            // `buildPipeline` is static and cannot capture the store, so the
            // per-page progress hook is attached here on a copy.
            var reporting = layered
            reporting.progress = { [weak self] processed, total in
                Task { @MainActor in
                    self?.analysisProgressText =
                        "Detegujem bezpečnostné prvky… strana \(processed) z \(total)"
                }
            }
            pipeline = DetectionPipeline(builtin: reporting, llmProvider: pipeline.llmProvider)
        }
        let detectionOutcome = await Task.detached(priority: .userInitiated) { [doc, pipeline] in
            await pipeline.detectWithStatus(in: doc.value, pageAnalyses: baseAnalysis.pageAnalyses)
        }.value
        guard analysisRecordID == currentRecordID, !Task.isCancelled else { return }
        if let failureMessage = detectionOutcome.failureMessage {
            analysisWarning = "\(failureMessage) Vstavaná detekcia zostáva aktívna."
        }
        if let bankLoadError = await exampleBank.loadError, !bankWarningShown {
            showBankWarningOnce(bankLoadError)
        }
        var detected = detectionOutcome.elements
        if recallingReviewedPages, selectedSettings.learnFromReviews, let documentData,
           let reviewedPages = try? await exampleBank.reviewedPages() {
            detected = ReviewedPageRecall.apply(
                to: detected, documentSHA256: AttestationClauseGenerator.sha256Hex(of: documentData),
                reviewedPages: reviewedPages)
        }

        let manualElements = securityElements.filter { !$0.detectedByAI }
        var merged = enrich(detected)
        for manual in manualElements where !merged.contains(where: { $0.id == manual.id }) {
            merged.append(manual)
        }

        blankPagesWithConfirmedElements = []
        analysis = DocumentAnalysis(
            totalPages: baseAnalysis.totalPages,
            nonEmptyPages: baseAnalysis.nonEmptyPages,
            estimatedSheetsDuplex: baseAnalysis.estimatedSheetsDuplex,
            pageAnalyses: baseAnalysis.pageAnalyses,
            securityElements: merged,
            suggestedTitle: baseAnalysis.suggestedTitle,
            analyzedAt: Date())
        // A new analysis replaces the suggestions; it is not a reviewer's edit, so
        // it must neither erase review decisions from the bank nor invalidate
        // stored page reviews (see `securityElementsChanged`).
        resettingSecurityReview = true
        securityElements = merged
        resettingSecurityReview = false
        reconcileBlankPagesWithConfirmedElements()
        reviewedNonEmptyPages = []
        reviewUpdatedAt = nil
        sheetMethod = .duplexEstimate
        manualSheetCount = nil
        prepareAttestationPrefill()
        await suggestDocumentKindFromScan(document: UncheckedSendable(document), recordID: analysisRecordID)
        // The OCR above suspends: a newer document may have run meanwhile, so
        // never touch shared state (not even .unavailable) when stale.
        guard analysisRecordID == currentRecordID, !Task.isCancelled else { return }
        inputSignatureInspection = .unavailable(
            detail: "Kontrola vstupných elektronických podpisov prebieha.")
        if let sourceURL {
            let inspection = await InputSignatureVerificationService(
                provider: signingProvider).inspect(inputURL: sourceURL)
            guard SessionResultGuard.accepts(
                resultFor: analysisRecordID,
                currentRecordID: currentRecordID,
                taskIsCancelled: Task.isCancelled) else { return }
            inputSignatureInspection = inspection
            recomputePreflight()
        }
        isAnalyzing = false
        analysisProgressText = ""
    }

    private func enrich(_ elements: [SecurityElement]) -> [SecurityElement] {
        elements.map { element in
            var copy = element
            if copy.verbalDescription.isEmpty && !copy.kind.requiresHumanDescription {
                copy.verbalDescription = copy.locationDescription(pageSizePt: .zero) + "."
            }
            return copy
        }
    }

    func prepareAttestationPrefill() {
        let profile = activeProfile()
        var data = attestation
        data.performingPerson = profile
        data.originalDocumentOrder = 1
        data.originalDocumentName = ConversionOutputNaming.readableName(sourceNameOverride
            ?? sourceURL?.deletingPathExtension().lastPathComponent
            ?? analysis.suggestedTitle ?? "")
        data.newDocumentName = (data.originalDocumentName.isEmpty ? "dokument" : data.originalDocumentName) + ".pdf"
        data.numberOfSheets = effectiveSheetCount
        data.sheetCountingMethod = sheetMethod
        data.nonEmptyPageCount = analysis.nonEmptyPages
        data.originalDocumentTypeLabel = "Iný dokument"
        suggestedDocumentKind = document.flatMap(DocumentKindClassifier.suggestKind(in:))
        data.newDocumentFormatLabel = "PDF/A-2"
        data.usedDeviceDescription = "Skenovanie / import do aplikácie Chevron7"
        var breakdown: [AttestationData.PaperSizeGroup] = []
        for (sizeClass, pages) in analysis.paperSizeSummary.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            breakdown.append(.init(sizeClass: sizeClass, sheets: Int(ceil(Double(pages) / 2.0))))
        }
        data.paperSizeBreakdown = breakdown
        attestation = data
    }

    /// Scan fallback for the kind suggestion: embedded text already ran in the
    /// prefill, so this OCRs only when it stayed silent. Stale runs (a newer
    /// document meanwhile) drop their result.
    func suggestDocumentKindFromScan(document: UncheckedSendable<PDFDocument>, recordID: UUID) async {
        guard suggestedDocumentKind == nil else { return }
        guard let text = await DocumentKindClassifier.recognizedFirstPageText(in: document.value) else { return }
        guard recordID == currentRecordID, !Task.isCancelled, self.document === document.value else { return }
        if suggestedDocumentKind == nil {
            suggestedDocumentKind = DocumentKindClassifier.suggestKind(firstPageText: text)
        }
    }

    func applySheetMethodChange() {
        attestation.numberOfSheets = effectiveSheetCount
        attestation.sheetCountingMethod = sheetMethod
        var breakdown: [AttestationData.PaperSizeGroup] = []
        for (sizeClass, pages) in analysis.paperSizeSummary.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let sheets: Int
            switch sheetMethod {
            case .manual: sheets = manualSheetCount ?? Int(ceil(Double(pages) / 2.0))
            case .oneSheetPerPage: sheets = pages
            case .duplexEstimate: sheets = Int(ceil(Double(pages) / 2.0))
            }
            breakdown.append(.init(sizeClass: sizeClass, sheets: sheets))
        }
        attestation.paperSizeBreakdown = breakdown
    }

    func addSecurityElement(kind: SecurityElement.Kind, pageIndex: Int, rect: NormalizedRect) {
        let element = SecurityElement(
            kind: kind,
            pageIndex: pageIndex,
            boundingBox: rect,
            confidence: 1.0,
            verbalDescription: "",
            detectedByAI: false,
            reviewState: .pending)
        securityElements.append(enrich([element]).first!)
        touchReview()
        unmarkPageReviewed(pageIndex)
        selectedElementID = element.id
    }

    func confirmSecurityElement(id: UUID) {
        updateReviewState(id: id, state: .confirmed)
    }

    /// A rejected finding no longer reacts on the canvas, so it also leaves the selection.
    func rejectSecurityElement(id: UUID) {
        updateReviewState(id: id, state: .rejected)
        if selectedElementID == id { selectedElementID = nil }
    }

    func returnSecurityElementToReview(id: UUID) {
        updateReviewState(id: id, state: .pending)
    }

    func markPageReviewed(_ pageIndex: Int) {
        guard analysis.pageAnalyses.contains(where: { $0.pageIndex == pageIndex && !$0.isEmpty }) else {
            return
        }
        guard !securityElements.contains(where: { $0.pageIndex == pageIndex && $0.reviewState == .pending }) else { return }
        reviewedNonEmptyPages.insert(pageIndex)
        recordReviewedTrainingPage(pageIndex)
        touchReview()
        recomputePreflight()
    }

    /// Marks the page reviewed and moves the preview to the next page that still
    /// needs a look, so a long document is one click per page.
    func markPageReviewedAndAdvance(_ pageIndex: Int) {
        markPageReviewed(pageIndex)
        let remaining = unconfirmedNonEmptyPages
        if let next = remaining.first(where: { $0 > pageIndex }) ?? remaining.first {
            previewPageIndex = next
        }
    }

    /// Confirms every pending finding on one page after the advocate checked
    /// them on the canvas.
    func confirmAllPendingElements(onPage pageIndex: Int) {
        for element in securityElements where element.pageIndex == pageIndex && element.reviewState == .pending {
            confirmSecurityElement(id: element.id)
        }
    }

    func pendingElementCount(onPage pageIndex: Int?) -> Int {
        securityElements.filter { $0.reviewState == .pending && (pageIndex == nil || $0.pageIndex == pageIndex) }.count
    }

    /// Rejects every finding still waiting for review, on one page or (nil) in the whole
    /// document, when the detector proposed nonsense. Each rejection teaches the learning
    /// bank like a single one, and a rejected finding can be returned to review from its row.
    @discardableResult
    func rejectAllPendingElements(onPage pageIndex: Int? = nil) -> Int {
        let ids = securityElements
            .filter { $0.reviewState == .pending && (pageIndex == nil || $0.pageIndex == pageIndex) }
            .map(\.id)
        for id in ids {
            rejectSecurityElement(id: id)
        }
        return ids.count
    }

    func unmarkPageReviewed(_ pageIndex: Int) {
        reviewedNonEmptyPages.remove(pageIndex)
        invalidateTrainingPage(pageIndex)
        touchReview()
        recomputePreflight()
    }

    private func updateReviewState(id: UUID, state: SecurityElementReviewState) {
        guard let index = securityElements.firstIndex(where: { $0.id == id }) else { return }
        securityElements[index].reviewState = state
        touchReview()
        recomputePreflight()
        recordReviewDecision(securityElements[index], state: state)
    }

    /// Index of an element whose content may change. A rejected element is locked: any
    /// edit would drop its negative example from the bank (`securityElementsChanged`),
    /// so only "Vrátiť na kontrolu" may touch it.
    private func editableIndex(of id: UUID) -> Int? {
        guard let index = securityElements.firstIndex(where: { $0.id == id }),
              !securityElements[index].isLockedByRejection else { return nil }
        return index
    }

    private func enqueueBankWork(_ operation: @escaping @Sendable () async throws -> Void) {
        let previous = bankWork
        bankWork = Task { [weak self] in
            await previous?.value
            do { try await operation() }
            catch { self?.showBankWarningOnce(error) }
        }
    }

    private func invalidateTrainingPage(_ pageIndex: Int) {
        guard let documentData else { return }
        let hash = AttestationClauseGenerator.sha256Hex(of: documentData)
        let bank = exampleBank
        enqueueBankWork { try await bank.invalidateReviewedPage(documentSHA256: hash, pageIndex: pageIndex) }
    }

    private func securityElementsChanged(from old: [SecurityElement]) {
        guard !resettingSecurityReview, old != securityElements else { return }
        attestation.noSecurityElementsConfirmed = false
        reconcileBlankPagesWithConfirmedElements()
        let pages = Set((old + securityElements).flatMap { [$0.pageIndex] + ($0.newDocumentPageIndex.map { [$0] } ?? []) })
        func affects(_ element: SecurityElement, page: Int) -> Bool {
            element.pageIndex == page || (element.observation == .physicalOriginal && element.newDocumentPageIndex == page)
        }
        for page in pages where old.filter({ affects($0, page: page) }) != securityElements.filter({ affects($0, page: page) }) {
            reviewedNonEmptyPages.remove(page)
            invalidateTrainingPage(page)
        }
        // Changed or deleted crops must not continue teaching their previous label or geometry.
        let changed = old.filter { prior in !securityElements.contains(prior) }
        let bank = exampleBank
        if !changed.isEmpty {
            enqueueBankWork { for element in changed { try await bank.remove(id: element.id) } }
        }
        // An edit that keeps a finding confirmed (numeric box, snap or refine)
        // must still teach the detector: record it again with its new content. Review-state
        // changes record themselves in `updateReviewState`.
        for prior in changed where prior.reviewState == .confirmed {
            if let current = securityElements.first(where: { $0.id == prior.id }), current.reviewState == .confirmed {
                recordReviewDecision(current, state: .confirmed)
            }
        }
    }

    /// A confirmed finding is content even when the low-ink scan was classified blank.
    /// Restore the automatic result when that finding is removed or returned to review.
    private func reconcileBlankPagesWithConfirmedElements() {
        let confirmedPages = Set(confirmedSecurityElements.map(\.pageIndex))
        for index in analysis.pageAnalyses.indices {
            let page = analysis.pageAnalyses[index].pageIndex
            if blankPagesWithConfirmedElements.remove(page) != nil { analysis.pageAnalyses[index].isEmpty = true }
            if analysis.pageAnalyses[index].isEmpty && confirmedPages.contains(page) {
                blankPagesWithConfirmedElements.insert(page)
                analysis.pageAnalyses[index].isEmpty = false
            }
        }
        let count = analysis.pageAnalyses.filter { !$0.isEmpty }.count
        if count != analysis.nonEmptyPages {
            analysis.nonEmptyPages = count
            analysis.estimatedSheetsDuplex = max((count + 1) / 2, analysis.totalPages == 0 ? 0 : 1)
            attestation.nonEmptyPageCount = count
            applySheetMethodChange()
        }
    }

    private func recordReviewDecision(_ element: SecurityElement, state: SecurityElementReviewState) {
        guard settings.learnFromReviews, let document, let documentData else { return }
        let recorder = bankRecorderFactory(exampleBank, detectorIdentifier)
        let doc = UncheckedSendable(document)
        enqueueBankWork {
            switch state {
            case .confirmed:
                try await recorder.record(document: doc.value, documentData: documentData,
                                          element: element, label: .kind(element.kind))
            case .rejected:
                try await recorder.record(document: doc.value, documentData: documentData,
                                          element: element, label: .negative)
            case .pending:
                try await recorder.forget(elementID: element.id)
            }
        }
    }

    private func recordReviewedTrainingPage(_ pageIndex: Int) {
        guard settings.learnFromReviews, let document, let documentData else { return }
        let recorder = bankRecorderFactory(exampleBank, detectorIdentifier)
        let doc = UncheckedSendable(document)
        // An unboxed physical observation must not become an unlabelled object in a training image.
        guard !securityElements.contains(where: { $0.observation == .physicalOriginal && $0.reviewState != .rejected
            && ($0.pageIndex == pageIndex || $0.newDocumentPageIndex == pageIndex) }) else {
            invalidateTrainingPage(pageIndex)
            return
        }
        let elements = securityElements.filter { $0.pageIndex == pageIndex }
        enqueueBankWork {
            try await recorder.recordReviewedPage(document: doc.value, documentData: documentData,
                                                   pageIndex: pageIndex, elements: elements)
        }
    }

    var canConfirmNoSecurityElements: Bool {
        !isAnalyzing && analysis.nonEmptyPages > 0 && unreviewedNonEmptyPages.isEmpty
            && pendingSecurityElementCount == 0 && confirmedSecurityElements.isEmpty
    }

    func confirmNoSecurityElements() {
        guard canConfirmNoSecurityElements else { return }
        attestation.noSecurityElementsConfirmed = true
        reviewUpdatedAt = Date()
        recomputePreflight()
    }

    @discardableResult
    func addPhysicalSecurityElement(kind: SecurityElement.Kind, pageIndex: Int,
                                    description: String, location: String,
                                    newDocumentPageIndex: Int?) -> UUID {
        let element = SecurityElement(kind: kind, pageIndex: pageIndex, boundingBox: .zero,
            confidence: 1, verbalDescription: description, detectedByAI: false, reviewState: .pending,
            observation: .physicalOriginal, originalLocation: location, newDocumentPageIndex: newDocumentPageIndex)
        securityElements.append(element)
        selectedElementID = element.id
        touchReview()
        recomputePreflight()
        return element.id
    }

    func updatePhysicalElement(id: UUID, location: String, newDocumentPageIndex: Int?) {
        guard let index = editableIndex(of: id) else { return }
        securityElements[index].originalLocation = location
        securityElements[index].newDocumentPageIndex = newDocumentPageIndex
        invalidateReview(for: index)
    }

    private func showBankWarningOnce(_ error: Error) {
        guard !bankWarningShown else { return }
        bankWarningShown = true
        analysisWarning = "Lokálny dataset sa nepodarilo aktualizovať (\(error.localizedDescription)). Kontrola pokračuje."
    }

    /// Synchronizes dataset export and deletion with pending review writes.
    func waitForBankWrites() async {
        while let work = bankWork {
            await work.value
            if bankWork == work { return }
        }
    }

    private func invalidateReview(for index: Int) {
        guard securityElements.indices.contains(index) else { return }
        securityElements[index].reviewState = .pending
        touchReview()
        recomputePreflight()
    }

    private func touchReview() {
        attestation.noSecurityElementsConfirmed = false
        reviewUpdatedAt = Date()
    }

    @discardableResult
    func duplicateElement(id: UUID) -> UUID? {
        guard let index = editableIndex(of: id) else { return nil }
        var copy = securityElements[index]
        copy.id = UUID()
        copy.detectedByAI = false
        copy.reviewState = .pending
        copy.boundingBox = ElementGeometry.moved(copy.boundingBox, center:
            NormalizedPoint(x: copy.boundingBox.midX + 0.04,
                            y: copy.boundingBox.midY + 0.06))
        securityElements.insert(copy, at: index + 1)
        unmarkPageReviewed(copy.pageIndex)
        selectedElementID = copy.id
        return copy.id
    }

    func removeSecurityElement(id: UUID) {
        guard editableIndex(of: id) != nil else { return }
        if lastDeletedElement == nil, let removed = securityElements.first(where: { $0.id == id }) {
            lastDeletedElement = (removed, securityElements.firstIndex(where: { $0.id == id }) ?? 0)
        }
        securityElements.removeAll { $0.id == id }
        touchReview()
        recomputePreflight()
    }

    enum DeleteOutcome: Equatable { case removed, rejected, ignored }

    /// The delete action of the Nálezy row and the Delete key. A pending AI suggestion is
    /// rejected instead, so the detector learns from the mistake; a rejected finding stays
    /// as the negative example it is; anything else (hand-drawn, or an AI finding the
    /// advocate already confirmed) is removed and can be restored with undo.
    @discardableResult
    func deleteOrRejectSecurityElement(id: UUID) -> DeleteOutcome {
        guard let element = securityElements.first(where: { $0.id == id }) else { return .ignored }
        switch element.deleteAction {
        case .none:
            return .ignored
        case .reject:
            rejectSecurityElement(id: id)
            return .rejected
        case .remove:
            removeSecurityElement(id: id)
            return .removed
        }
    }

    /// Scan boxes of one page that react to clicks and drags on the canvas. Rejected
    /// findings are drawn beneath the rest but never hit-tested, resized or snapped.
    func interactiveCanvasElements(onPage pageIndex: Int) -> [SecurityElement] {
        securityElements.filter { $0.pageIndex == pageIndex && $0.hasScanRegion && !$0.isLockedByRejection }
    }

    func undoDelete() {
        guard let (element, index) = lastDeletedElement else { return }
        var restored = element
        if !securityElements.contains(where: { $0.id == restored.id }) {
            let insertAt = min(index, securityElements.count)
            securityElements.insert(restored, at: insertAt)
            touchReview()
            unmarkPageReviewed(restored.pageIndex)
        }
        lastDeletedElement = nil
        recomputePreflight()
    }

    private func ensureSnapAssets() async -> Bool {
        if snapAssetsReady { return true }
        snapAssetProgress = 0
        defer { snapAssetProgress = nil }
        do {
            try await snapper.ensureAssets { fraction in
                Task { @MainActor in self.snapAssetProgress = fraction }
            }
            snapAssetsReady = true
            snapUnavailableReason = nil
            return true
        } catch {
            snapUnavailableReason = "Presný výber prvku nie je dostupný (model sa nepodarilo stiahnuť). Rámec nakreslite ručne."
            return false
        }
    }

    private func renderedPage(_ pageIndex: Int) -> CGImage? {
        guard let document, let page = document.page(at: pageIndex) else { return nil }
        return BuiltInVisionProvider.render(page: page, targetWidth: 1200)?.cgImage
    }

    /// Click without drag on a freshly placed element: segment at the point and
    /// tighten that element's box in place. On failure the placeholder stays so
    /// the advocate can adjust it by hand.
    @discardableResult
    func snapPlacedElement(id: UUID, at point: NormalizedPoint) async -> Bool {
        guard let element = editableIndex(of: id).map({ securityElements[$0] }), element.hasScanRegion,
              await ensureSnapAssets(), let image = renderedPage(element.pageIndex) else { return false }
        let box = UncheckedSendableImage(image)
        guard let rect = try? await snapper.snap(pageImage: box.image, seed: point) else { return false }
        updateElementBoundingBox(id: id, boundingBox: rect)
        return true
    }

    func refineElement(id: UUID) async {
        guard let element = editableIndex(of: id).map({ securityElements[$0] }), element.hasScanRegion,
              await ensureSnapAssets(), let image = renderedPage(element.pageIndex) else { return }
        let box = UncheckedSendableImage(image)
        guard let rect = try? await snapper.refine(pageImage: box.image, box: element.boundingBox) else { return }
        updateElementBoundingBox(id: id, boundingBox: rect)
    }

    func placeElement(kind: SecurityElement.Kind, at center: NormalizedPoint, pageIndex: Int? = nil) -> UUID {
        let targetPage = pageIndex ?? previewPageIndex
        let element = SecurityElement(
            kind: kind,
            pageIndex: targetPage,
            boundingBox: ElementGeometry.clampedCentered(center: center),
            confidence: 1.0,
            verbalDescription: "",
            detectedByAI: false,
            reviewState: .pending)
        securityElements.append(enrich([element]).first!)
        touchReview()
        unmarkPageReviewed(targetPage)
        selectedElementID = element.id
        return element.id
    }

    func drawElement(id: UUID, from anchor: NormalizedPoint, to corner: NormalizedPoint) {
        guard let index = editableIndex(of: id) else { return }
        securityElements[index].boundingBox = ElementGeometry.resized(from: anchor, to: corner)
        invalidateReview(for: index)
    }

    func moveElement(id: UUID, center: NormalizedPoint) {
        guard let index = editableIndex(of: id) else { return }
        let previous = securityElements[index]
        securityElements[index].boundingBox =
            ElementGeometry.moved(securityElements[index].boundingBox, center: center)
        if previous.verbalDescription == previous.locationDescription(pageSizePt: .zero) + "." {
            securityElements[index].verbalDescription = securityElements[index].locationDescription(pageSizePt: .zero) + "."
        }
        invalidateReview(for: index)
    }

    func elementID(at point: NormalizedPoint, pageIndex: Int) -> UUID? {
        ElementGeometry.hitTest(
            elements: interactiveCanvasElements(onPage: pageIndex).map { ($0.id, $0.pageIndex, $0.boundingBox) },
            point: point,
            pageIndex: pageIndex)
    }

    func isResizeHandle(_ id: UUID, at point: NormalizedPoint) -> Bool {
        guard let index = editableIndex(of: id) else { return false }
        let element = securityElements[index]
        return ElementGeometry.isInResizeHandle(element.boundingBox, point)
    }

    func updateElementPage(id: UUID, pageIndex: Int) {
        if let index = editableIndex(of: id) {
            let previous = securityElements[index]
            securityElements[index].pageIndex = pageIndex
            if previous.verbalDescription == previous.locationDescription(pageSizePt: .zero) + "." {
                securityElements[index].verbalDescription = securityElements[index].locationDescription(pageSizePt: .zero) + "."
            }
            invalidateReview(for: index)
        }
    }

    func updateElementKind(id: UUID, kind: SecurityElement.Kind) {
        if let index = editableIndex(of: id) {
            let previous = securityElements[index]
            if previous.verbalDescription == previous.locationDescription(pageSizePt: .zero) + "." { securityElements[index].verbalDescription = "" }
            securityElements[index].kind = kind
            invalidateReview(for: index)
        }
    }

    func updateElementDescription(id: UUID, text: String) {
        if let index = editableIndex(of: id) {
            securityElements[index].verbalDescription = text
            invalidateReview(for: index)
        }
    }

    func updateElementBoundingBox(id: UUID, boundingBox: NormalizedRect) {
        guard let index = editableIndex(of: id) else { return }
        let clamped = NormalizedRect(
            x: min(max(boundingBox.x, 0), 1),
            y: min(max(boundingBox.y, 0), 1),
            width: min(max(boundingBox.width, 0.01), 1),
            height: min(max(boundingBox.height, 0.01), 1))
        securityElements[index].boundingBox = NormalizedRect(
            x: min(clamped.x, 1 - clamped.width),
            y: min(clamped.y, 1 - clamped.height),
            width: min(clamped.width, 1),
            height: min(clamped.height, 1))
    }

    func refreshIdentities() async {
        guard !isRefreshingIdentities else { return }
        isRefreshingIdentities = true
        defer { isRefreshingIdentities = false }

        applyReaderIdentities(await signingProvider.availableIdentities())
        if !identities.isEmpty, !signingPIN.isEmpty, !hasResolvedCertificate {
            await resolveCertificateForAuthorization()
        }
    }

    /// Takes what the reader reports, from `refreshIdentities` or the shared
    /// `CardReaderStatus` poll, so the clause step knows the card too.
    func refreshMandateCardState() {
        mandateCardState = readMandateCardState()
    }

    func applyReaderIdentities(_ discovered: [SigningIdentityInfo]) {
        refreshMandateCardState()
        guard !isAuthorizing, !isResolvingCertificate else { return }
        if identities != discovered { identities = discovered }
        if identities.isEmpty {
            if !signingPIN.isEmpty { signingPIN = "" }
            certificateLoadError = nil
            lastCertificateLoadPIN = nil
            selectedIdentityID = nil
            return
        }
        if selectedIdentityID == nil || !identities.contains(where: { $0.id == selectedIdentityID }) {
            selectedIdentityID = identities.first(where: { $0.isMandateCertificate })?.id
                ?? identities.first?.id
        }
    }

    var hasResolvedCertificate: Bool {
        signingProviderIsDemo || identities.contains {
            $0.id.hasPrefix(EngineBridgeSigningProvider.certificateIdentityPrefix)
        }
    }

    func resolveCertificateForAuthorization(force: Bool = false) async {
        guard !signingProviderIsDemo, !signingPIN.isEmpty || !cardNeedsTypedPIN,
              !isResolvingCertificate else { return }
        guard force || !hasResolvedCertificate else { return }
        guard force || lastCertificateLoadPIN != signingPIN else { return }

        let pin = signingPIN
        isResolvingCertificate = true
        lastCertificateLoadPIN = pin
        let resolved = await signingProvider.resolveIdentities(pin: pin)
        isResolvingCertificate = false

        guard !Task.isCancelled else { return }
        guard pin == signingPIN else {
            lastCertificateLoadPIN = nil
            guard !signingPIN.isEmpty else { return }
            await resolveCertificateForAuthorization(force: true)
            return
        }

        if let resolved, !resolved.isEmpty {
            identities = resolved
            selectedIdentityID = resolved.first(where: { $0.isMandateCertificate })?.id
                ?? resolved.first?.id
            certificateLoadError = nil
        } else {
            certificateLoadError = (signingProvider as? EngineBridgeSigningProvider)?.lastResolveError
                ?? "Načítanie certifikátov z karty zlyhalo."
        }
    }

    /// An eID asks for its BOK in the eID client's own window; other cards take the PIN here.
    var cardNeedsTypedPIN: Bool {
        !(identities.first?.usesProtectedAuthenticationPath ?? false)
    }

    /// Synthetic identita = typ certifikátu ešte nie je overený (čaká na PIN).
    var isCertificateTypePending: Bool {
        selectedIdentity?.id.hasPrefix("engine:") == true
    }

    var selectedIdentity: SigningIdentityInfo? {
        identities.first(where: { $0.id == selectedIdentityID })
    }

    var mandateRequirementSatisfied: Bool {
        guard let identity = selectedIdentity else { return false }
        return identity.isMandateCertificate && identity.isQualified && identity.hasPrivateKey
    }

    /// Only the Demo signing provider, whose identities are never mandate certificates,
    /// may go on without one. A real card signs a conversion with its MQC or not at all.
    var requiresMandateOverride: Bool {
        signingProviderIsDemo && !hasValidMandateOverride
    }

    var hasValidMandateOverride: Bool {
        signingProviderIsDemo && allowNonMandateOverride && mandateOverrideIdentityID == selectedIdentityID
    }

    func setMandateOverride(_ enabled: Bool) {
        allowNonMandateOverride = enabled
        mandateOverrideIdentityID = enabled ? selectedIdentityID : nil
        recomputePreflight()
    }

    var signingProviderIsDemo: Bool {
        signingProvider is DemoSigningProvider
    }

    func recomputePreflight() {
        let result = AttestationPreflight.evaluate(
            attestation,
            securityElements: securityElements,
            hasSelectedIdentity: selectedIdentityID != nil,
            mandateRequirementSatisfied: mandateRequirementSatisfied
                || hasValidMandateOverride
                || isCertificateTypePending,
            inputSignatureInspection: inputSignatureInspection,
            unreviewedNonEmptyPages: unreviewedNonEmptyPages, documentPageCount: analysis.totalPages)
        // The evidence number is not the person's to fetch: authorization allocates it.
        let errors = result.errors.filter { $0 != .missingEvidenceNumber }
        preflightErrors = errors
        validationErrors = errors
    }

    func preparePreflight() {
        evidenceNumberError = nil
        recomputePreflight()
    }

    func fetchEvidenceNumber() async {
        guard !fetchingEvidenceNumber else { return }
        let requestID = currentRecordID
        evidenceRequestID = requestID
        evidenceNumberError = nil
        fetchingEvidenceNumber = true
        defer {
            if evidenceRequestID == requestID {
                fetchingEvidenceNumber = false
                evidenceRequestID = nil
            }
        }
        // The register is the legal record of every number already in use; if this build
        // could not read it, allocating or reusing a number could produce a duplicate the
        // app has no way to notice.
        if let loadError = evidenceStore.loadError {
            evidenceNumberError = loadError
            lastError = loadError
            recomputePreflight()
            return
        }
        // A number from one mode is never valid in another, so a reply that arrives after the
        // mode changed is dropped without an error.
        let mode = settingsStore.ezzkAccountController.mode
        // Outside Demo a real number must be backed by a real signature: the Demo signing
        // provider (no bundled engine or no card identity) would leave it without a record.
        if mode != .demo, signingProviderIsDemo {
            evidenceNumberError = EZZKError.demoSignatureOutsideDemo.errorDescription
            lastError = evidenceNumberError
            recomputePreflight()
            return
        }
        // A real number is allocated only for someone who can sign it with an MQC: an unused
        // one lapses at midnight. `requestEvidenceNumber` walks the card flow first.
        if mode != .demo, !signingProviderIsDemo { refreshMandateCardState() }
        if mode != .demo, let refusal = mandateGate.evidenceNumberRefusal {
            evidenceNumberError = refusal
            lastError = refusal
            recomputePreflight()
            return
        }
        // Demo numbers are a local simulation with no EZZK-side limit, so the pool (which
        // exists only to avoid asking the real EZZK again) plays no part there.
        if mode != .demo {
            let usedNumbers = EvidenceRecord.usedEvidenceNumbers(in: evidenceStore.records, mode: mode)
            if let entry = evidenceNumberPool.reusable(mode: mode, at: Date(), excluding: usedNumbers) {
                attestation.evidenceNumber = entry.number
                attestation.evidenceNumberAllocatedAt = entry.allocatedAt
                attestation.evidenceNumberMode = entry.mode
                evidenceNumberRequested = true
                lastError = nil
                evidenceNumberError = nil
                recomputePreflight()
                return
            }
        }
        do {
            let service = ezzkService
            var numbers = try await service.requestEvidenceNumbers(count: 1)
            if mode == .demo {
                // The Demo simulator counts from 1 again after every launch, so skip the
                // numbers the register already holds (bounded, in case it ever repeats).
                let usedNumbers = EvidenceRecord.usedEvidenceNumbers(in: evidenceStore.records, mode: mode)
                var attempts = 0
                while let candidate = numbers.first, usedNumbers.contains(candidate), attempts < 10_000 {
                    numbers = try await service.requestEvidenceNumbers(count: 1)
                    attempts += 1
                }
            }
            guard requestID == currentRecordID, !Task.isCancelled,
                  mode == settingsStore.ezzkAccountController.mode else { return }
            guard let number = numbers.first else {
                throw EZZKError.invalidResponse
            }
            // EZZK consumes an unused number at midnight of its allocation day.
            let allocatedAt = try await service.serverTime()
            guard requestID == currentRecordID, !Task.isCancelled,
                  mode == settingsStore.ezzkAccountController.mode else { return }
            attestation.evidenceNumber = number
            attestation.evidenceNumberAllocatedAt = allocatedAt
            attestation.evidenceNumberMode = mode
            if mode != .demo {
                evidenceNumberPool.add(EvidenceNumberPool.Entry(number: number, mode: mode, allocatedAt: allocatedAt))
            }
            evidenceNumberRequested = true
            lastError = nil
            evidenceNumberError = nil
            recomputePreflight()
        } catch {
            guard requestID == currentRecordID, !Task.isCancelled,
                  mode == settingsStore.ezzkAccountController.mode else { return }
            if let ezzkError = error as? EZZKError, case .serviceRejected(113, _) = ezzkError {
                evidenceNumberError = EZZKError.numberLimitMessage
                lastError = EZZKError.numberLimitMessage
            } else {
                evidenceNumberError = error.localizedDescription
                lastError = error.localizedDescription
            }
            recomputePreflight()
        }
    }

    func validate() -> [AttestationValidationError] {
        let stampTime: Date? = usesQualifiedTimestamp ? serverTimeUsed : nil
        let errors = AttestationValidator.validate(attestation,
                                                   securityElements: confirmedSecurityElements,
                                                   qualifiedTimestampTime: stampTime)
        let reviewResult = AttestationPreflight.evaluate(
            attestation,
            securityElements: securityElements,
            hasSelectedIdentity: selectedIdentityID != nil,
            mandateRequirementSatisfied: mandateRequirementSatisfied,
            inputSignatureInspection: inputSignatureInspection,
            unreviewedNonEmptyPages: unreviewedNonEmptyPages, documentPageCount: analysis.totalPages)
        let reviewErrors = reviewResult.errors.filter { !errors.contains($0) }
        let allErrors = errors + reviewErrors
        validationErrors = allErrors
        return allErrors
    }
    func authorizeAndSign(viaMobile: Bool = false) async {
        guard !isAuthorizing else { return }
        isAuthorizing = true
        isAuthorizingViaMobile = viaMobile
        defer {
            isAuthorizing = false
            isAuthorizingViaMobile = false
            analysisProgressText = ""
        }

        lastError = nil
        validationErrors = []
        preparePreflight()
        if viaMobile, !settingsStore.ezzkAccountController.isDemoMode {
            lastError = Self.mobileOutsideDemoMessage
            return
        }
        // Local precondition before any EZZK call: a number from another EZZK mode (a demo
        // number on Produkcia, for example) was never allocated there, so nothing is signed.
        if let modeError = evidenceNumberModeError {
            evidenceNumberError = modeError
            lastError = modeError
            // Nothing is signed now; the next "Autorizovať" allocates a number in this mode.
            attestation.evidenceNumber = nil
            attestation.evidenceNumberAllocatedAt = nil
            attestation.evidenceNumberMode = nil
            recomputePreflight()
            return
        }
        // Outside Demo a real number must be backed by a real signature: the Demo signing
        // provider (no bundled engine or no card identity) would leave it without a record.
        if !settingsStore.ezzkAccountController.isDemoMode, signingProviderIsDemo {
            let message = EZZKError.demoSignatureOutsideDemo.errorDescription
            evidenceNumberError = message
            lastError = message
            recomputePreflight()
            return
        }
        // The register is the legal record of this conversion; a register this build could
        // not read would keep the row only in memory, so nothing is signed or sent.
        if let loadError = evidenceStore.loadError {
            lastError = loadError
            return
        }
        // A real card authorizes only with its mandate certificate (the phone's is checked
        // after it signs).
        if !viaMobile, !signingProviderIsDemo, !mandateRequirementSatisfied {
            lastError = Self.noMandateMessage
            return
        }
        // The number is allocated here, after the card and its MQC, right before the
        // signature: never for a conversion that is not signed, so none lapses at midnight.
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
        guard viaMobile ? isMobilePreflightComplete : isPreflightComplete else { return }
        let confirmedElementsSnapshot = confirmedSecurityElements
        let securityReviewSnapshot = securityReviewStamp

        do {
            analysisProgressText = "Zisťujem dôveryhodný čas…"
            let conversionTime = try await ezzkService.serverTime()
            guard EZZKEvidenceNumberPolicy.isUsable(allocatedAt: attestation.evidenceNumberAllocatedAt,
                                                    at: conversionTime) else {
                evidenceNumberError = EZZKError.evidenceNumberExpired.errorDescription
                recomputePreflight()
                throw EZZKError.evidenceNumberExpired
            }
            serverTimeUsed = conversionTime
            attestation.conversionExecutionDateTime = conversionTime
            selectedFormPack = try formPackRepository.pack(
                for: .paperToElectronic,
                at: conversionTime,
                policy: .allowUnverifiedPilot)

            // § 3 vyhlášky č. 70/2021 Z. z.: formát listiny je povinnou náležitosťou doložky.
            // Ak klasifikácia analýzy nevyplnila rozpad (napr. netypická veľkosť strany),
            // doplň A4 na výšku s odhadom počtu listov, aby validácia neprepadla.
            if attestation.paperSizeBreakdown.isEmpty {
                attestation.paperSizeBreakdown = [AttestationData.PaperSizeGroup(
                    sizeClass: .a4Portrait,
                    sheets: max(effectiveSheetCount, 1))]
            }
            let errors = validate()
            guard errors.isEmpty else {
                analysisProgressText = ""
                return
            }

            analysisProgressText = "Konvertujem do PDF/A…"
            guard let document else { throw PDFAError.emptyDocument }
            let pdfaData = try pdfaConverter.convert(document: document,
                                                     profile: selectedFormPack.outputProfile,
                                                     mode: settings.pdfaMode,
                                                     title: attestation.newDocumentName)

            // The clause fingerprints the exact bytes the client receives, so nothing may be
            // embedded or rewritten after this point (spec: Facts, fingerprint and embedding).
            let finalPDF = try pdfaConverter.normalizeForDelivery(pdfaData, title: attestation.newDocumentName)
            let pdfaCheck = PDFAValidator().validate(finalPDF, profile: selectedFormPack.outputProfile)
            guard pdfaCheck.isValid else {
                throw ComplianceValidationError(domain: "PDF/A-2b", issues: pdfaCheck.issues)
            }
            let fingerprint = AttestationClauseGenerator.sha256Hex(of: finalPDF)
            let nonEmptyPageIndices = analysis.pageAnalyses.filter { !$0.isEmpty }.map(\.pageIndex)

            analysisProgressText = "Vytváram osvedčovaciu doložku…"
            // One value names the PDF/A inside the signed container and in the clause and the
            // record (NewDocumentName), so the two are equal by construction, as in the
            // podpisuj.sk reference.
            let containerDocumentName = ConversionOutputNaming.containerDocumentName(
                newDocumentName: attestation.newDocumentName,
                fallback: attestation.originalDocumentName)
            var deliveredAttestation = attestation
            deliveredAttestation.newDocumentName = containerDocumentName
            let clause = try ZakoClauseDeliveryBuilder().build(
                finalPDF: finalPDF,
                attestation: deliveredAttestation,
                securityElements: confirmedElementsSnapshot,
                originalNonEmptyPageIndices: nonEmptyPageIndices,
                usedDevice: attestation.usedDeviceDescription)

            // The record EZZK receives, validated before anything is signed: an invalid record
            // stops the conversion before the client container exists.
            let recordDelivery = try ZakoRecordDeliveryBuilder().build(model: clause.model)

            analysisProgressText = viaMobile ? "Čakám na podpis z mobilu…" : "Autorizujem kvalifikovaným podpisom…"
            if !viaMobile, isCertificateTypePending {
                analysisProgressText = "Overujem certifikát na karte…"
                let resolved = await signingProvider.resolveIdentities(pin: signingPIN)
                guard let resolved, !resolved.isEmpty else {
                    throw SigningError.identityUnavailable
                }
                identities = resolved
                selectedIdentityID = resolved.first(where: { $0.isMandateCertificate })?.id
                    ?? resolved.first?.id
            }
            if !viaMobile, requiresMandateOverride {
                lastError = "Zvolený certifikát nie je mandátnym certifikátom pre zaručenú konverziu. Pokračovanie je možné len s výslovným override (audit záznam)."
                return
            }
            // Outside Demo the timestamp is qualified by construction: the engine gets only the
            // built-in qualified authorities for both signatures (spec Revision 5, ruling 3).
            let stampsSignatures = usesQualifiedTimestamp
            let timestampServers: [String]?
            let tsaURL: String?
            if settingsStore.ezzkAccountController.isDemoMode {
                if stampsSignatures,
                   settings.selectedTSAURL.trimmingCharacters(in: .whitespaces).isEmpty {
                    throw SigningError.timestampFailed
                }
                timestampServers = nil
                tsaURL = stampsSignatures ? settings.activeTSA.url : nil
            } else {
                let qualified = TimestampAuthority.qualifiedURLs.map(\.absoluteString)
                guard let first = qualified.first else { throw SigningError.timestampFailed }
                timestampServers = qualified
                tsaURL = first
            }

            let directory = ConversionOutputNaming.outputDirectory(
                sourceURL: sourceURL,
                preferredDirectory: outputDirectoryOverride,
                fallback: settingsStore.outputDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            // The card's container follows the podpisuj.sk reference: the PDF/A under its new
            // document name and the clause as "<number>.xml.xdcf". The loose names below are
            // used only by the phone route, which writes the PDF/A and the clause next to it.
            let containerFiles = ASiCEPackager().zakoContainer(
                pdfData: finalPDF,
                pdfFileName: containerDocumentName,
                dolozkaXML: clause.clauseXDCF,
                dolozkaFileName: ConversionOutputNaming.containerClauseName(evidenceNumber: attestation.evidenceNumber))
            let docFileName = ConversionOutputNaming.deliveryPDFFileName(
                in: directory,
                preferredName: outputPDFFileName())
            let xdcfTarget = ConversionOutputNaming.uniqueURL(
                in: directory,
                fileName: ConversionOutputNaming.xdcfFileName(
                    originalDocumentName: attestation.originalDocumentName,
                    pdfFileName: docFileName,
                    evidenceNumber: attestation.evidenceNumber))
            let signed: SignedConversionResult
            if viaMobile {
                // avm-server rejects unsigned ASiC-E input (422 "Level can't be empty if document
                // is not signed yet"), so the phone signs only the final PDF/A and the server wraps
                // it into a fresh ASiC-E. The clause XDC is not part of that container: it is written
                // next to it below, unsigned, with the PDF/A. Carrying the clause on the mobile
                // route is still open. The PDF/A goes up under the name the clause gives it.
                let upload = AVMUploadRequest(
                    filename: containerDocumentName,
                    data: finalPDF,
                    mimeType: AVMUploadRequest.pdfMimeType,
                    level: .xades(timestamp: includeQualifiedTimestamp),
                    container: .asicE)
                let document = try await mobileSigning.sign(upload)
                guard AVMResultMapper.isMandate(signers: document.signers ?? []) else {
                    lastError = Self.mobileMandateRefusalMessage
                    return
                }
                signed = try AVMResultMapper.conversionResult(from: document,
                                                              outputFormat: .attachedASIC,
                                                              uploadedPDF: finalPDF)
            } else {
                guard let identityID = selectedIdentityID else {
                    throw SigningError.identityUnavailable
                }
                signed = try await signingProvider.sign(SigningRequest(
                    pdfData: finalPDF,
                    identityID: identityID,
                    includeTimestamp: stampsSignatures,
                    tsaURL: tsaURL,
                    pin: signingPIN.isEmpty ? nil : signingPIN,
                    extraFiles: containerFiles,
                    filename: containerDocumentName,
                    signsExtraFilesAsDataObjects: true,
                    timestampServers: timestampServers))
            }

            if let asic = signed.asicData {
                let containerCheck = ASiCEContainerVerifier().verify(asic)
                guard containerCheck.isValid else {
                    throw ComplianceValidationError(domain: "ASiC-E kontajner",
                                                    issues: containerCheck.issues)
                }
            }
            // The signed client documents carry the number in their clause from here on, so
            // it is used whatever happens to the record: the pool never offers it again.
            if let number = attestation.evidenceNumber {
                evidenceNumberPool.remove(number)
            }
            // The details just signed into the clause become the active profile, so the next
            // conversion starts with them instead of asking for them again.
            saveProfileFromForm()

            analysisProgressText = "Ukladám a zapisujem do evidencie…"
            // The card's ASiC-E holds the PDF/A and the clause, signed together, so it is the one
            // file the client gets. The phone's container holds the PDF/A alone, so there the
            // PDF/A and the clause are also written and the PDF/A is what is delivered.
            // Outputs are made unique, so neither the source nor an earlier output is replaced.
            let deliveredTarget: URL
            let pdfFileName: String
            if !viaMobile, let asic = signed.asicData {
                deliveredTarget = ConversionOutputNaming.uniqueURL(
                    in: directory,
                    fileName: ConversionOutputNaming.asicFileName(pdfFileName: containerDocumentName))
                try asic.write(to: deliveredTarget, options: [.atomic])
                pdfFileName = containerDocumentName
            } else {
                deliveredTarget = directory.appendingPathComponent(docFileName)
                try signed.pdfData.write(to: deliveredTarget, options: [.atomic])
                try clause.clauseXDCF.write(to: xdcfTarget, options: [.atomic])
                if let asic = signed.asicData {
                    let asicTarget = ConversionOutputNaming.uniqueURL(
                        in: directory,
                        fileName: ConversionOutputNaming.asicFileName(pdfFileName: docFileName))
                    try asic.write(to: asicTarget, options: [.atomic])
                }
                pdfFileName = docFileName
            }
            outputDirectory = directory

            var record = EvidenceRecord(
                id: currentRecordID,
                status: .signed,
                direction: .paperToElectronic,
                originalName: attestation.originalDocumentName,
                newDocumentName: containerDocumentName,
                evidenceNumber: attestation.evidenceNumber,
                fingerprintSHA256Hex: fingerprint,
                attestationXML: recordDelivery.recordXML,
                conversionTime: conversionTime,
                performingPersonName: attestation.performingPerson.fullName,
                securityElementCount: confirmedElementsSnapshot.count,
                totalPages: analysis.totalPages,
                totalSheets: attestation.numberOfSheets,
                pdfFileName: pdfFileName,
                deliveredFileName: deliveredTarget.lastPathComponent,
                formPack: FormPackStamp(pack: selectedFormPack),
                securityReview: securityReviewSnapshot,
                ezzkMode: attestation.evidenceNumberMode ?? settingsStore.ezzkAccountController.mode,
                evidenceNumberAllocatedAt: attestation.evidenceNumberAllocatedAt)

            // The row is registered before the record is signed, so a crash or force-quit
            // during the second signature still leaves it in the register. The status
            // checker holds it until the record is signed or has failed (see
            // `EZZKStatusChecker.hold`); every later write updates this same row.
            let rowID = record.id
            let held = settingsStore.statusChecker.hold(rowID)
            evidenceStore.upsert(record)

            // The record is signed with the same card into its own container. The phone route
            // (Demo only) has no card identity, so its row stays unsigned (the coordinator says so).
            do {
                defer { if held { settingsStore.statusChecker.release(rowID) } }
                if !viaMobile, let identityID = selectedIdentityID {
                    analysisProgressText = "Podpisujem záznam o konverzii…"
                    do {
                        let signedRecord = try await signingProvider.sign(SigningRequest(
                            pdfData: recordDelivery.recordXDCF,
                            identityID: identityID,
                            includeTimestamp: stampsSignatures,
                            tsaURL: tsaURL,
                            pin: signingPIN.isEmpty ? nil : signingPIN,
                            filename: recordDelivery.entryName,
                            timestampServers: timestampServers,
                            signsAsRecordContainer: true))
                        guard let asic = signedRecord.asicData else {
                            throw SigningError.signingFailed("Podpis záznamu nevrátil kontajner ASiC-E.")
                        }
                        let recordCheck = ASiCEContainerVerifier().verify(asic)
                        guard recordCheck.isValid else {
                            throw ComplianceValidationError(domain: "Kontajner záznamu o konverzii",
                                                            issues: recordCheck.issues)
                        }
                        // The register keeps the only copy: submission reads it, and the Register
                        // saves it for the advocate ("Uložiť záznam…"); without it the row cannot be sent.
                        record.recordContainerPath = try evidenceStore.storeRecordContainer(asic, for: record.id)
                    } catch {
                        // The client outputs above stay: the conversion is delivered, but its
                        // record must be signed again, so nothing is sent.
                        record.status = .recordUnsigned
                        record.ezzkResultDescription = error.localizedDescription
                        evidenceStore.upsert(record)
                        submissionStatus = .recordUnsigned
                        lastError = Self.recordUnsignedMessage(error)
                        result = signed
                        step = .done
                        return
                    }
                }
                evidenceStore.upsert(record)
            }

            analysisProgressText = "Odosielam záznam do EZZK…"
            await sendRecord(record.id)

            result = signed
            step = .done
        } catch {
            if let avmError = error as? AVMError, avmError == .cancelled {
                return
            }
            lastError = error.localizedDescription
        }
    }

    /// "Odoslať do EZZK" on the Done screen: sends this conversion's row again (an unknown
    /// outcome is looked up first, never resent blindly).
    func retryQueuedSubmission() async {
        await sendRecord(currentRecordID)
    }

    /// "Overiť v EZZK" on the Done screen: looks this conversion's record up in EZZK.
    func verifyRecordInEZZK() async {
        apply(await settingsStore.statusChecker.verify(id: currentRecordID))
    }

    /// Sends one register row through the app's status checker, which applies the
    /// submission coordinator's rules (late rows marked, unknown outcomes looked up first,
    /// a row only ever sent to the EZZK that allocated its number) and keeps the Register
    /// and the periodic check off the row meanwhile.
    private func sendRecord(_ id: UUID) async {
        apply(await settingsStore.statusChecker.submit(id: id))
    }

    private func apply(_ result: EZZKStatusChecker.RowResult) {
        switch result {
        case .refused(let reason):
            submissionStatus = evidenceStore.record(id: currentRecordID)?.status ?? submissionStatus
            lastError = reason
        case .row(let record):
            submissionStatus = record.status
            switch record.status {
            case .acceptedForProcessing, .processed:
                lastError = nil
            default:
                lastError = record.ezzkResultDescription
            }
        }
    }

    func saveTemplate() {
        let url = templatesDirectory().appendingPathComponent("\(sanitizedBaseName()).zako-template.json")
        do {
            let data = try JSONEncoder.pretty.encode(attestation)
            try data.write(to: url, options: [.atomic])
        } catch {
            lastError = "Šablónu sa nepodarilo uložiť: \(error.localizedDescription)"
        }
    }

    func loadLatestTemplate() {
        let directory = templatesDirectory()
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory,
                                                                       includingPropertiesForKeys: [.contentModificationDateKey]),
              let latest = files.filter({ $0.pathExtension == "json" })
                  .sorted(by: { lhs, rhs in
                      let l = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                      let r = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                      return l > r
                  }).first,
              let data = try? Data(contentsOf: latest),
              let template = try? JSONDecoder.standard.decode(AttestationData.self, from: data) else {
            return
        }
        attestation = template
        attestation.originConfirmed = false
        attestation.noSecurityElementsConfirmed = false
        attestation.evidenceNumber = nil
        attestation.evidenceNumberAllocatedAt = nil
        attestation.evidenceNumberMode = nil
        evidenceNumberRequested = false
        evidenceNumberError = nil
        preflightErrors = []
    }

    func saveProfileFromForm() {
        let profile = attestation.performingPerson
        profilePersister?(profile)
    }

    func activeProfile() -> AdvocateProfile {
        if let id = settings.activeProfileID,
           let profile = settings.profiles.first(where: { $0.id == id }) {
            return profile
        }
        return settings.profiles.first ?? .empty
    }

    var unconfirmedNonEmptyPages: [Int] {
        analysis.pageAnalyses
            .filter { !$0.isEmpty && !reviewedNonEmptyPages.contains($0.pageIndex) }
            .map(\.pageIndex)
    }

func resetSession(keepingProfile: Bool) {
        resettingSecurityReview = true
        defer { resettingSecurityReview = false }
        if sourceAccessIsActive, let sourceURL {
            sourceURL.stopAccessingSecurityScopedResource()
            sourceAccessIsActive = false
        }
        let profile = keepingProfile ? attestation.performingPerson : AdvocateProfile.empty
        step = .intake
        sourceURL = nil
        document = nil
        documentData = nil
        analysis = .empty()
        blankPagesWithConfirmedElements = []
        securityElements = []
        reviewedNonEmptyPages = []
        activeTool = nil
        previewPageIndex = 0
        lastDeletedElement = nil
        selectedElementID = nil
        attestation = AttestationData(performingPerson: profile)
        sheetMethod = .duplexEstimate
        manualSheetCount = nil
        identities = []
        selectedIdentityID = nil
        allowNonMandateOverride = false
        mandateOverrideIdentityID = nil
        evidenceNumberRequested = false
        evidenceNumberError = nil
        fetchingEvidenceNumber = false
        evidenceRequestID = nil
        isAuthorizing = false
        isAnalyzing = false
        analysisProgressText = ""
        suggestedDocumentKind = nil
        preflightErrors = []
        validationErrors = []
        submissionStatus = nil
        result = nil
        outputDirectory = nil
        outputDirectoryOverride = nil
        sourceNameOverride = nil
        lastError = nil
        analysisWarning = nil
        serverTimeUsed = nil
        inputSignatureInspection = .unavailable(
            detail: "Kontrola podpisov ešte neprebehla.")
        reviewUpdatedAt = nil
        currentRecordID = UUID()
    }

    private func sanitizedBaseName() -> String {
        let raw = attestation.newDocumentName.isEmpty
            ? attestation.originalDocumentName
            : attestation.newDocumentName
        let cleaned = ASiCEPackager.sanitizedFileName(raw)
        return cleaned.isEmpty ? "konverzia" : cleaned
    }

    func outputPDFFileName() -> String {
        ConversionOutputNaming.pdfFileName(
            originalDocumentName: sourceNameOverride
                ?? sourceURL?.deletingPathExtension().lastPathComponent
                ?? attestation.originalDocumentName,
            requestedDocumentName: attestation.newDocumentName)
    }

    func templatesDirectory() -> URL {
        let url = settingsStore.templatesDirectory
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Placeholder used only to compute the default identifier before the first analysis.
private struct NoOpClassifier: ElementClassifying {
    func classify(crop: CGImage, hint: SecurityElement.Kind?) async throws -> ElementJudgement { .unsure }
}

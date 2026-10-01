// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import PDFKit
import SwiftUI
import Chevron7Kit

@MainActor
@Observable
final class SigningSessionStore {
    enum Step: Int, CaseIterable { case intake = 0, prepare = 1, done = 2 }

    var step: Step = .intake
    var sourceURL: URL?
    var sourceBookmark: Data?
    var document: PDFDocument?
    var analysis: DocumentAnalysis = .empty()
    var isAnalyzing = false

    var identities: [SigningIdentityInfo] = []
    var selectedIdentityID: String?

    var includeQualifiedTimestamp = true
    var includeVisibleSignature = false
    var selectedVisualAppearanceID = VisualSignatureAppearance.textID
    var convertToPDFA = false
    var outputFormat: SigningOutputFormat = .attachedASIC
    var signingPIN = "" {
        didSet {
            guard oldValue != signingPIN, batchPhase == .ready else { return }
            batchSettingsSnapshot = nil
            batchOptionsError = nil
            batchPIN = nil
            batchPhase = .idle
            lastError = "PIN sa zmenil. Dávku znova skontrolujte pred spustením."
        }
    }
    var signaturePage: Int = 0
    var signatureRect = NormalizedRect(x: 0.58, y: 0.80, width: 0.30, height: 0.09)

    var isSigning = false
    var statusText = ""
    var result: SignedConversionResult?
    var outputDirectory: URL?
    var lastError: String?
    let mobileSigning: MobileSigningCoordinator
    var agpKeyStore: any AGPKeyStoring = AGPKeyStore()
    /// Which path the current `sign` run uses; drives the button labels.
    private(set) var isSigningViaMobile = false
    var existingSignatureState = SignatureTreeState()
    var resultSignatureState = SignatureTreeState()
    /// Top-level signatures, for callers that predate the tree.
    var existingSignatures: [DocumentSignatureInfo] { existingSignatureState.tree.signatures }
    var resultSignatures: [DocumentSignatureInfo] { resultSignatureState.tree.signatures }
    var isInspectingSignatures: Bool { existingSignatureState.phase == .inspecting }
    private(set) var existingValidationTask: Task<Void, Never>?
    private(set) var resultValidationTask: Task<Void, Never>?
    private var existingTreeRun = UUID()
    private var resultTreeRun = UUID()
    /// Read from the loaded file's bytes, so it holds with every provider.
    private(set) var sourceSignatureKind: ExistingSignatureGuard.Source = .unsignedPDF
    /// A signed PDF or a container is signed as it is: no PDF/A and no stamp baked into it.
    var preservesSourceBytes: Bool { sourceSignatureKind != .unsignedPDF }
    /// Only the engine draws a stamp without rewriting the PDF, as part of a PAdES signature.
    var bakedVisualStampIsBlocked: Bool {
        preservesSourceBytes && outputFormat == .attachedASIC
    }
    var signedOutputURL: URL?
    var signedPreviewDocument: PDFDocument?
    var pdfaPrepared = false
    var pdfaAfterSign = false

    /// Grafika zvolená v novej knižnici vizuálnych podpisov (Autogram macOS 2 štýl).
    var visualArtworkOverride: Data?
    var visualPlacement: VisibleSignaturePlacement?

    var queue: [SigningQueueItem] = []
    var selectedQueueID: UUID?

    var batchPhase: BatchPhase = .idle
    var batchItems: [BatchItem] = []
    var batchCompletedCount = 0
    var batchFailedCount = 0
    var batchCurrentIndex: Int?
    var batchErrorDecisionRequest: BatchFailureDecisionRequest?
    private(set) var batchSettingsSnapshot: BatchSettingsSnapshot?
    /// Name of the shared ASiC-E container, without extension. Empty means the default.
    var batchContainerName = ""
    /// The default `batchContainerName` of the current batch, `<first document>_podpisane`.
    private(set) var batchContainerDefaultName = ""
    /// Why the current options cannot be signed; the batch stays ready and cannot start.
    private(set) var batchOptionsError: String?
    private var batchPIN: String?
    private var batchGeneration = UUID()
    private var batchDecisionContinuation: CheckedContinuation<BatchFailureDecision, Never>?

    struct SigningQueueItem: Identifiable, Hashable {
        enum Status: Hashable {
            case ready
            case signing
            case signed
            case failed
        }
        let id: UUID
        var url: URL
        var displayName: String
        var status: Status
        var signedOutputURL: URL?
        var errorMessage: String?

        init(id: UUID = UUID(), url: URL, displayName: String? = nil,
             status: Status = .ready, signedOutputURL: URL? = nil, errorMessage: String? = nil) {
            self.id = id
            self.url = url
            self.displayName = displayName ?? url.lastPathComponent
            self.status = status
            self.signedOutputURL = signedOutputURL
            self.errorMessage = errorMessage
        }
    }
    enum BatchPhase: Equatable {
        case idle
        case preflighting
        case ready
        case signing
        case completed
        case cancelled
    }

    enum BatchFailureDecision {
        case continueBatch
        case stopBatch
    }

    enum BatchItemState: Equatable {
        case pending
        case signing
        case signed
        case failed
        case skipped
        case cancelled
    }

    struct BatchItem: Identifiable, Hashable {
        let id: UUID
        let displayName: String
        let url: URL
        var state: BatchItemState
        var errorMessage: String?
        var outputURL: URL?
        var plannedOutputURL: URL?
        var inputSignatureState: InputSignatureInspectionResult.State?
        var inputSignatureDetail: String?

        init(
            id: UUID,
            displayName: String,
            url: URL,
            state: BatchItemState = .pending,
            errorMessage: String? = nil,
            outputURL: URL? = nil,
            plannedOutputURL: URL? = nil,
            inputSignatureState: InputSignatureInspectionResult.State? = nil,
            inputSignatureDetail: String? = nil
        ) {
            self.id = id
            self.displayName = displayName
            self.url = url
            self.state = state
            self.errorMessage = errorMessage
            self.outputURL = outputURL
            self.plannedOutputURL = plannedOutputURL
            self.inputSignatureState = inputSignatureState
            self.inputSignatureDetail = inputSignatureDetail
        }

        var plannedOutputLabel: String? {
            plannedOutputURL?.lastPathComponent
        }
    }

    struct BatchFailureDecisionRequest: Identifiable, Equatable {
        let itemID: UUID
        let displayName: String
        let errorMessage: String

        var id: UUID { itemID }
    }

    struct BatchSettingsSnapshot: Sendable, Equatable {
        // The options below can change while the batch is ready (`refreshReadyBatchOptions`);
        // the certificate and the visual stamp are fixed by the preflight.
        var outputFormat: SigningOutputFormat
        var asicPackaging: AppSettings.BatchASiCPackaging
        /// The shared container's file name without extension, only for a combined ASiC-E.
        var containerStem: String?
        var includeQualifiedTimestamp: Bool
        var tsaURL: String?
        var convertToPDFA: Bool
        var pdfaMode: PDFAConversionMode
        let selectedIdentityID: String
        let identityLabel: String
        let identityIsQualified: Bool
        let includeVisibleSignature: Bool
        let selectedVisualAppearanceID: String
        let visualArtworkOverride: Data?
        let visualPlacement: VisibleSignaturePlacement?
        let signaturePage: Int
        let signatureRect: NormalizedRect
    }

    let signingProvider: any QualifiedSigningProviding
    let settingsStore: AppSettingsStore
    let recentDocumentStore: RecentDocumentStore
    /// Optional so existing tests can build the store without a history.
    var signedDocumentStore: SignedDocumentStore?
    let outputService = OutputService()
    let stamper = VisibleSignatureStamper()

    var settings: AppSettings { settingsStore.settings }

    var selectedTSAURL: String {
        get { settingsStore.settings.selectedTSAURL }
        set {
            var next = settingsStore.settings
            next.selectedTSAURL = newValue
            settingsStore.settings = next
        }
    }

    var batchASiCPackaging: AppSettings.BatchASiCPackaging {
        get { settingsStore.settings.batchASiCPackaging }
        set {
            var next = settingsStore.settings
            next.batchASiCPackaging = newValue
            settingsStore.settings = next
        }
    }

    /// Ready, with something to sign, nothing failed and options that can be signed.
    var batchCanStart: Bool {
        batchPhase == .ready
            && batchSettingsSnapshot != nil
            && batchOptionsError == nil
            && batchItems.contains { $0.state == .pending }
            && !batchItems.contains { $0.state == .failed }
    }

    var pdfaMode: PDFAConversionMode {
        get { settingsStore.settings.pdfaMode }
        set {
            var next = settingsStore.settings
            next.pdfaMode = newValue
            settingsStore.settings = next
        }
    }

    init(
        signingProvider: any QualifiedSigningProviding,
        settingsStore: AppSettingsStore,
        recentDocumentStore: RecentDocumentStore
    ) {
        self.signingProvider = signingProvider
        self.settingsStore = settingsStore
        self.recentDocumentStore = recentDocumentStore
        self.mobileSigning = MobileSigningCoordinator(settingsStore: settingsStore)
    }

    func loadDocument(at url: URL) async {
        await addDocuments(at: [url], selectLast: true)
    }

    func addDocuments(at urls: [URL], selectLast: Bool = true) async {
        lastError = nil
        var lastID: UUID?
        for url in urls {
            let standardized = url.standardizedFileURL
            if let existing = queue.first(where: { $0.url.standardizedFileURL == standardized }) {
                lastID = existing.id
                continue
            }
            let item = SigningQueueItem(url: url)
            queue.append(item)
            recentDocumentStore.record(url: url)
            lastID = item.id
        }
        if selectLast, let lastID {
            await selectQueueItem(lastID)
        }
    }

    /// A signed output can take a further signature: it joins the queue as its own
    /// document, and its signatures decide the format (`sourceSignatureKind`).
    var canAddFurtherSignature: Bool {
        !isSigning && batchPhase != .preflighting && batchPhase != .ready && batchPhase != .signing
    }

    func addFurtherSignature(to url: URL) async {
        guard canAddFurtherSignature else { return }
        await addDocuments(at: [url], selectLast: true)
    }

    func selectQueueItem(_ id: UUID) async {
        guard let item = queue.first(where: { $0.id == id }) else { return }
        selectedQueueID = id
        // The previous document's validation must not land while this one is being opened:
        // its own inspection (which issues the next token) comes after analysis and card refresh.
        existingTreeRun = UUID()
        existingSignatureState = SignatureTreeState()
        setValidationTask(nil, result: false)
        lastError = item.errorMessage
        signedOutputURL = item.signedOutputURL
        signedPreviewDocument = item.signedOutputURL.flatMap { previewDocument(for: $0) }
        resultTreeRun = UUID()
        resultSignatureState = SignatureTreeState()
        setValidationTask(nil, result: true)
        let secured = item.url.startAccessingSecurityScopedResource()
        defer { if secured { item.url.stopAccessingSecurityScopedResource() } }
        guard let document = previewDocument(for: item.url) else {
            lastError = "Súbor sa nepodarilo otvoriť ako PDF."
            return
        }
        self.document = document
        self.sourceURL = item.url
        sourceSignatureKind = ExistingSignatureGuard.classify(
            fileName: item.url.lastPathComponent,
            data: (try? Data(contentsOf: item.url)) ?? Data())
        switch sourceSignatureKind {
        case .asicContainer: outputFormat = .attachedASIC
        // A further PAdES signature sits next to the existing one in the same PDF.
        case .signedPDF: outputFormat = .embeddedPAdES
        case .unsignedPDF: break
        }
        self.sourceBookmark = try? item.url.bookmarkData(options: .withSecurityScope,
                                                         includingResourceValuesForKeys: nil,
                                                         relativeTo: nil)
        if item.status == .signed, item.signedOutputURL != nil {
            step = .done
            if let signed = item.signedOutputURL {
                await runSignatureTree(for: signed, result: true)
            }
            return
        }
        step = .prepare
        isAnalyzing = true
        let doc = UncheckedSendable(document)
        analysis = await Task.detached(priority: .userInitiated) {
            let engine = PDFAnalysisEngine()
            return engine.analyze(document: doc.value)
        }.value ?? .empty()
        signaturePage = max(analysis.totalPages - 1, 0)
        isAnalyzing = false
        await refreshIdentities()
        await inspectExistingSignatures()
    }
    func removeQueueItem(_ id: UUID) {
        guard batchPhase != .preflighting, batchPhase != .ready, batchPhase != .signing else { return }
        queue.removeAll { $0.id == id }
        if selectedQueueID == id {
            selectedQueueID = nil
            document = nil
            sourceURL = nil
            existingTreeRun = UUID()
            existingSignatureState = SignatureTreeState()
            setValidationTask(nil, result: false)
            if queue.isEmpty {
                step = .intake
            }
        }
    }

    func inspectExistingSignatures() async {
        guard let sourceURL else {
            existingTreeRun = UUID()
            existingSignatureState = SignatureTreeState()
            setValidationTask(nil, result: false)
            return
        }
        await runSignatureTree(for: sourceURL, result: false)
    }

    func revalidateExistingSignatures() async {
        guard let sourceURL, existingSignatureState.phase != .inspecting else { return }
        await revalidate(url: sourceURL, result: false)
    }

    func revalidateResultSignatures() async {
        guard let signedOutputURL, resultSignatureState.phase != .inspecting else { return }
        await revalidate(url: signedOutputURL, result: true)
    }

    /// Structural tree first (awaited), then full validation in the background, so signing
    /// and document switches never wait for the trusted lists. A run token drops results
    /// that arrive after the user moved to another document.
    private func runSignatureTree(for url: URL, result: Bool) async {
        let run = UUID()
        setTreeRun(run, result: result)
        setTreeState(SignatureTreeState(tree: SignatureTree(), phase: .inspecting), result: result)
        let inspected = await signingProvider.inspectSignatureTree(in: url)
        guard treeRun(result: result) == run else { return }
        switch inspected {
        case .failed(let reason):
            setTreeState(SignatureTreeState(tree: SignatureTree(), phase: .failed(reason)), result: result)
            setValidationTask(nil, result: result)
        case .tree(let tree):
            let summary = SignatureTreeSummary(tree: tree)
            guard summary.total > 0 || summary.unverifiedDocuments > 0 else {
                // No signatures and nothing unverified: there is nothing to validate.
                setTreeState(SignatureTreeState(tree: tree, phase: .validated), result: result)
                setValidationTask(nil, result: result)
                return
            }
            setTreeState(SignatureTreeState(tree: tree, phase: .structural), result: result)
            let task = Task<Void, Never> { [weak self] in
                guard let self else { return }
                await self.validate(url: url, run: run, result: result, keptTreeWasValidated: false)
            }
            setValidationTask(task, result: result)
        }
    }

    private func revalidate(url: URL, result: Bool) async {
        let run = UUID()
        setTreeRun(run, result: result)
        var state = treeState(result: result)
        let wasValidated = state.phase == .validated
        state.phase = .structural
        setTreeState(state, result: result)
        let task = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.validate(url: url, run: run, result: result, keptTreeWasValidated: wasValidated)
        }
        setValidationTask(task, result: result)
        await task.value
    }

    /// `keptTreeWasValidated`: the tree shown while this runs came from an earlier validation,
    /// so a failure must not leave its verdicts (green) under "the result is only structural".
    private func validate(url: URL, run: UUID, result: Bool, keptTreeWasValidated: Bool) async {
        let validated = await signingProvider.validateSignatureTree(in: url)
        guard treeRun(result: result) == run else { return }
        switch validated {
        case .tree(let tree):
            setTreeState(SignatureTreeState(tree: tree, phase: .validated), result: result)
        case .failed(let reason):
            var state = treeState(result: result)
            if keptTreeWasValidated {
                state.tree = state.tree.withoutValidationVerdicts()
            }
            state.phase = .validationUnavailable(reason)
            setTreeState(state, result: result)
        }
    }

    private func treeRun(result: Bool) -> UUID { result ? resultTreeRun : existingTreeRun }
    private func setTreeRun(_ run: UUID, result: Bool) {
        if result { resultTreeRun = run } else { existingTreeRun = run }
    }
    private func treeState(result: Bool) -> SignatureTreeState {
        result ? resultSignatureState : existingSignatureState
    }
    private func setTreeState(_ state: SignatureTreeState, result: Bool) {
        if result { resultSignatureState = state } else { existingSignatureState = state }
    }
    /// Cancels the validation being replaced, which also ends its engine request.
    private func setValidationTask(_ task: Task<Void, Never>?, result: Bool) {
        let replaced = result ? resultValidationTask : existingValidationTask
        if replaced != task { replaced?.cancel() }
        if result { resultValidationTask = task } else { existingValidationTask = task }
    }

    private func resetSignatureTrees() {
        existingTreeRun = UUID()
        resultTreeRun = UUID()
        existingSignatureState = SignatureTreeState()
        resultSignatureState = SignatureTreeState()
        setValidationTask(nil, result: false)
        setValidationTask(nil, result: true)
    }

    private var isRefreshingIdentities = false
    private(set) var isResolvingCertificate = false
    var certificateLoadError: String?
    private var lastCertificateLoadPIN: String?

    var signingProviderIsDemo: Bool {
        signingProvider is DemoSigningProvider
    }

    static let containerNeedsCardMessage =
        "Do existujúceho kontajnera ASiC-E sa podpis mobilom pridať nedá. Podpíšte ho kartou."
    static let containerNeedsEngineMessage =
        "Pridať podpis do existujúceho kontajnera ASiC-E vie iba podpisový engine s kartou."
    static let containerInBatchMessage =
        "Kontajner ASiC-E sa v dávke podpísať nedá. Otvorte ho samostatne a pridajte podpis."

    var hasResolvedCertificate: Bool {
        signingProviderIsDemo || identities.contains {
            $0.id.hasPrefix(EngineBridgeSigningProvider.certificateIdentityPrefix)
        }
    }

    /// Certifikát musí byť známy pred vykreslením grafického podpisu.
    func resolveCertificateForPreview(force: Bool = false) async {
        guard !signingProviderIsDemo, !signingPIN.isEmpty, !isResolvingCertificate else { return }
        guard force || !hasResolvedCertificate else { return }
        guard force || lastCertificateLoadPIN != signingPIN else { return }

        isResolvingCertificate = true
        lastCertificateLoadPIN = signingPIN
        defer { isResolvingCertificate = false }

        if let resolved = await signingProvider.resolveIdentities(pin: signingPIN), !resolved.isEmpty {
            identities = resolved
            selectedIdentityID = resolved.first(where: { $0.isMandateCertificate })?.id
                ?? resolved.first?.id
            certificateLoadError = nil
        } else {
            certificateLoadError = (signingProvider as? EngineBridgeSigningProvider)?.lastResolveError
                ?? "Načítanie certifikátu zlyhalo."
        }
    }

    func refreshIdentities() async {
        guard !isSigning, !isRefreshingIdentities else { return }
        isRefreshingIdentities = true
        defer { isRefreshingIdentities = false }
        applyReaderIdentities(await signingProvider.availableIdentities())
    }

    /// Takes what the reader reports: from `refreshIdentities` or from the shared
    /// `CardReaderStatus` poll, so the store never polls the reader on its own.
    func applyReaderIdentities(_ discovered: [SigningIdentityInfo]) {
        guard !isSigning else { return }
        if identities != discovered { identities = discovered }
        // Karta vybratá → vynúť nové overenie PIN (každá karta má iný PIN).
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

    var canSign: Bool {
        document != nil && selectedIdentityID != nil && !isSigning
    }

    /// Mobile signing always uses the qualified certificate on the eID, which is known only
    /// after the phone signs, so the baked stamp describes the channel instead of the card.
    static let mobileStampCertificateName = "Občiansky preukaz (eID) cez Autogram v mobile"
    static let qualifiedSignatureLabel = "Kvalifikovaný elektronický podpis"
    static let eidentitaSignatureLabel = "Podpis z eIdentity"
    static let eidentitaStampCertificateName = "Občiansky preukaz (eID) cez eIdentitu"
    func stampCertificateName(viaMobile: Bool, mobileMethod: MobileSigningMethod = .autogramMobile) -> String? {
        if viaMobile {
            return mobileMethod == .eidentita ? Self.eidentitaStampCertificateName : Self.mobileStampCertificateName
        }
        return identities.first(where: { $0.id == selectedIdentityID })?.label
    }

    func stampQualification(viaMobile: Bool) -> String? {
        if viaMobile { return Self.qualifiedSignatureLabel }
        return identities.first(where: { $0.id == selectedIdentityID })?.isQualified == true
            ? Self.qualifiedSignatureLabel : nil
    }

    var isMobileSigningAvailable: Bool {
        settings.mobileSigningEnabled && !signingProviderIsDemo
    }

    var canSignViaMobile: Bool {
        document != nil && !isSigning && isMobileSigningAvailable
            && sourceSignatureKind != .asicContainer
            // The phone path can only bake a stamp into the PDF, which a signed PDF refuses.
            && !(preservesSourceBytes && includeVisibleSignature)
    }

    /// Portal client for eIdentita signing, minted from the Keychain key and the
    /// user id in settings. Missing pieces are a settings error, not a transport one.
    private func eidentitaClient() throws -> AGPClient {
        try AGPClient.configured(userID: settingsStore.settings.agpUserID,
                                 baseURL: settingsStore.settings.agpBaseURLValue,
                                 keyStore: agpKeyStore)
    }

    func sign(viaMobile: Bool = false, mobileMethod: MobileSigningMethod = .autogramMobile) async {
        guard let document else { return }
        // The panel switches this off too; a stamp that cannot be drawn must not
        // make signing wait for the card's certificate.
        if bakedVisualStampIsBlocked { includeVisibleSignature = false }
        lastError = nil
        isSigning = true
        isSigningViaMobile = viaMobile
        statusText = includeVisibleSignature ? "Pripravujem vizuálny podpis…" : "Podpisujem…"

        do {
            if !viaMobile, includeVisibleSignature, !signingProviderIsDemo, !hasResolvedCertificate {
                statusText = "Načítavam certifikát pre vizuálny podpis…"
                await resolveCertificateForPreview(force: true)
                guard hasResolvedCertificate else {
                    throw SigningError.signingFailed(
                        certificateLoadError ?? "Pred vizuálnym podpisom sa nepodarilo načítať certifikát.")
                }
            }
            // Pôvodné bajty súboru (ako v originálnom Autograme): PDFKit rewrite až keď je nutný.
            var pdfData: Data
            if let sourceURL, let original = try? Data(contentsOf: sourceURL), !original.isEmpty {
                pdfData = original
            } else {
                let doc = UncheckedSendable(document)
                pdfData = try await Task.detached(priority: .userInitiated) {
                    doc.value.dataRepresentation()
                }.get() ?? Data()
            }
            let originalPdfData = pdfData
            pdfaPrepared = false
            pdfaAfterSign = false
            // A document that already carries a signature is signed exactly as it is:
            // every rewrite below goes through PDFKit and would drop that signature.
            let sourceKind = ExistingSignatureGuard.classify(
                fileName: sourceURL?.lastPathComponent ?? "", data: pdfData)
            let preservesSourceBytes = sourceKind != .unsignedPDF
            if sourceKind == .asicContainer {
                guard !viaMobile else { throw SigningError.signingFailed(Self.containerNeedsCardMessage) }
                guard signingProvider.addsSignatureToExistingContainer else {
                    throw SigningError.signingFailed(Self.containerNeedsEngineMessage)
                }
                outputFormat = .attachedASIC
            }
            var visualStampWasPreapplied = false
            // The card path lets the Java engine draw the PAdES appearance; the AVM server
            // cannot, so signing with mobile bakes the stamp into the PDF like the ASiC-E path.
            let preappliesVisualStamp = !preservesSourceBytes
                && (outputFormat == .attachedASIC || (viaMobile && outputFormat == .embeddedPAdES))
            if convertToPDFA, includeVisibleSignature, preappliesVisualStamp {
                let imageData = visualArtworkOverride
                    ?? VisualSignatureStore.imageData(for: selectedVisualAppearanceID, in: settingsStore.signaturesDirectory)
                let stamp = VisibleSignatureStamper.StampData(
                    fullName: displayName(),
                    timestamp: Date(),
                    pageIndex: visualPlacement?.pageIndex ?? min(signaturePage, analysis.totalPages - 1),
                    normalizedRect: signatureRect,
                    imagePNG: imageData,
                    certificateName: stampCertificateName(viaMobile: viaMobile, mobileMethod: mobileMethod),
                    certificateQualification: stampQualification(viaMobile: viaMobile),
                    timestampAuthorityName: includeQualifiedTimestamp ? settings.activeTSA.name : nil)
                let stampedData = await Self.stampPDFData(
                    pdfData,
                    stamp: stamp,
                    includeTimestamp: includeQualifiedTimestamp,
                    stamper: stamper,
                    flattenAnnotations: true)
                visualStampWasPreapplied = stampedData != pdfData
                pdfData = stampedData
            }


            if convertToPDFA, !preservesSourceBytes, !pdfData.isEmpty {
                statusText = "Konvertujem do PDF/A…"
                let title = sourceURL?.deletingPathExtension().lastPathComponent ?? ""
                // PAdES DSS rozbije vektorový incremental PDF/A: raster je jediný spoľahlivý vstup.
                let mode: PDFAConversionMode =
                    outputFormat == .embeddedPAdES || visualStampWasPreapplied
                    ? .rasterGuaranteed
                    : pdfaMode
                let pdfaDocument = PDFDocument(data: pdfData) ?? document
                pdfData = try PDFAConverter().convert(document: pdfaDocument, mode: mode, title: title)
                var pdfaCheck = PDFAValidator().validate(pdfData)
                if !pdfaCheck.isValid {
                    pdfData = try PDFAConverter().convert(
                        document: PDFDocument(data: pdfData) ?? pdfaDocument,
                        mode: .rasterGuaranteed,
                        title: title)
                    pdfaCheck = PDFAValidator().validate(pdfData)
                }
                guard pdfaCheck.isValid else {
                    throw SigningError.signingFailed(
                        "Konverzia do PDF/A zlyhala: \(pdfaCheck.issues.joined(separator: "; ")).")
                }
                pdfaPrepared = true
                statusText = "PDF/A je pripravené, podpisujem…"
            }
            if !convertToPDFA, includeVisibleSignature, preappliesVisualStamp {
                let imageData = visualArtworkOverride
                    ?? VisualSignatureStore.imageData(for: selectedVisualAppearanceID, in: settingsStore.signaturesDirectory)
                let stamp = VisibleSignatureStamper.StampData(
                    fullName: displayName(),
                    timestamp: Date(),
                    pageIndex: visualPlacement?.pageIndex ?? min(signaturePage, analysis.totalPages - 1),
                    normalizedRect: signatureRect,
                    imagePNG: imageData,
                    certificateName: stampCertificateName(viaMobile: viaMobile, mobileMethod: mobileMethod),
                    certificateQualification: stampQualification(viaMobile: viaMobile),
                    timestampAuthorityName: includeQualifiedTimestamp ? settings.activeTSA.name : nil)
                pdfData = await Self.stampPDFData(
                    pdfData,
                    stamp: stamp,
                    includeTimestamp: includeQualifiedTimestamp,
                    stamper: stamper,
                    flattenAnnotations: true)
            }

            

            statusText = viaMobile ? "Čakám na podpis z mobilu…" : "Podpisujem kvalifikovaným podpisom…"
            let pdfName = sourceURL?.lastPathComponent ?? "dokument.pdf"
            let artworkPNG = visualArtworkOverride ?? VisualSignatureStore.imageData(for: selectedVisualAppearanceID, in: settingsStore.signaturesDirectory)
            let visualStamp: VisualStampSpec?
            if includeVisibleSignature, outputFormat == .embeddedPAdES {
                visualStamp = VisualStampSpec(
                    fullName: displayName(),
                    timestamp: Date(),
                    pageIndex: visualPlacement?.pageIndex ?? min(signaturePage, analysis.totalPages - 1),
                    normalizedRect: signatureRect,
                    imagePNG: artworkPNG,
                    // Po PDF/A rasteri sú iné rozmery strany: vždy mapovať z normalizovaného rectu na aktuálne PDF.
                    pdfPageRect: convertToPDFA ? nil : visualPlacement?.pageRect,
                    rotationDegrees: visualPlacement?.rotationDegrees ?? 0,
                    qualification: identities.first(where: { $0.id == selectedIdentityID })?.isQualified == true
                        ? "Kvalifikovaný elektronický podpis" : nil,
                    certificateName: identities.first(where: { $0.id == selectedIdentityID })?.label,
                    timestampAuthorityName: includeQualifiedTimestamp ? settings.activeTSA.name : nil)
            } else {
                visualStamp = nil
            }
            let signed: SignedConversionResult
            if viaMobile {
                switch mobileMethod {
                case .autogramMobile:
                    // The phone signs on the AVM server; only the final step differs from the card path.
                    let level: AVMSignatureLevel = outputFormat == .embeddedPAdES
                        ? .pades(timestamp: includeQualifiedTimestamp)
                        : .xades(timestamp: includeQualifiedTimestamp)
                    let upload = AVMUploadRequest(filename: pdfName,
                                                  data: pdfData,
                                                  mimeType: AVMUploadRequest.pdfMimeType,
                                                  level: level,
                                                  container: outputFormat == .attachedASIC ? .asicE : nil)
                    let document = try await mobileSigning.sign(upload)
                    signed = try AVMResultMapper.conversionResult(from: document,
                                                                  outputFormat: outputFormat,
                                                                  uploadedPDF: pdfData)
                case .eidentita:
                    // The phone signs on the portal; the QR comes from its eIdentita session page.
                    let request = AGPSigningRequest(filename: pdfName,
                                                    data: pdfData,
                                                    mimeType: AVMUploadRequest.pdfMimeType,
                                                    format: outputFormat == .embeddedPAdES ? .pades : .xades,
                                                    level: includeQualifiedTimestamp ? .baselineT : .baselineB)
                    let file = try await mobileSigning.signViaEidentita(request, client: eidentitaClient())
                    // The portal validates the upload, so a returned file is a qualified signature.
                    // No mandate check here: this is ordinary mobile signing, ZaKo keeps its own.
                    switch outputFormat {
                    case .embeddedPAdES:
                        signed = SignedConversionResult(pdfData: file.data, asicData: nil, signedAt: Date(),
                                                        signatureLabel: Self.eidentitaSignatureLabel,
                                                        isLegallyBinding: true)
                    case .attachedASIC:
                        signed = SignedConversionResult(pdfData: pdfData, asicData: file.data, signedAt: Date(),
                                                        signatureLabel: Self.eidentitaSignatureLabel,
                                                        isLegallyBinding: true)
                    }
                }
            } else {
                guard let identityID = selectedIdentityID else {
                    throw SigningError.identityUnavailable
                }
                func makeRequest(with data: Data) -> SigningRequest {
                    SigningRequest(pdfData: data,
                                   identityID: identityID,
                                   includeTimestamp: includeQualifiedTimestamp,
                                   tsaURL: includeQualifiedTimestamp ? selectedTSAURL : nil,
                                   outputFormat: outputFormat,
                                   pin: signingPIN.isEmpty ? nil : signingPIN,
                                   extraFiles: [ASiCEPackager.Entry(path: pdfName, data: data)],
                                   visualStamp: visualStamp,
                                   filename: pdfName,
                                   // The engine builds the ASiC-E around the document itself;
                                   // a container packaged here ended up nested in the signed one.
                                   signsExtraFilesAsDataObjects: true)
                }
                do {
                    signed = try await signingProvider.sign(makeRequest(with: pdfData))
                } catch {
                    let text = error.localizedDescription
                    if convertToPDFA, pdfaPrepared,
                       text.contains("SIGNING_UNAVAILABLE") || text.contains("SIGNING_FAILED") {
                        statusText = "PDF/A sa nepodarilo podpísať, skúšam pôvodný dokument…"
                        pdfaPrepared = false
                        signed = try await signingProvider.sign(makeRequest(with: originalPdfData))
                    } else {
                        throw error
                    }
                }
            }

            statusText = "Ukladám…"
            let (directory, stem) = resolveOutputLocation()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if outputFormat == .embeddedPAdES {
                try signed.pdfData.write(to: directory.appendingPathComponent("\(stem).pdf"),
                                         options: [.atomic])
            }
            if let asic = signed.asicData {
                try asic.write(to: directory.appendingPathComponent("\(stem).asice"),
                               options: [.atomic])
            }
            outputDirectory = directory
            if outputFormat == .embeddedPAdES {
                signedOutputURL = directory.appendingPathComponent("\(stem).pdf")
            } else if signed.asicData != nil {
                signedOutputURL = directory.appendingPathComponent("\(stem).asice")
            } else {
                signedOutputURL = directory.appendingPathComponent("\(stem).pdf")
            }
            signedDocumentStore?.record(
                displayName: signedOutputURL?.lastPathComponent ?? pdfName,
                origin: .app,
                method: viaMobile ? .mobile : .card,
                signatureLevel: outputFormat == .embeddedPAdES
                    ? (includeQualifiedTimestamp ? "PAdES_BASELINE_T" : "PAdES_BASELINE_B")
                    : (includeQualifiedTimestamp ? "XAdES_BASELINE_T" : "XAdES_BASELINE_B"),
                signedBy: signed.signatureLabel,
                url: signedOutputURL)
            if let index = queue.firstIndex(where: { $0.id == selectedQueueID }) {
                queue[index].status = .signed
                queue[index].signedOutputURL = signedOutputURL
                queue[index].errorMessage = nil
            }
            if let signedURL = signedOutputURL {
                signedPreviewDocument = PDFDocument(data: signed.pdfData)
                    ?? previewDocument(for: signedURL)
                await runSignatureTree(for: signedURL, result: true)
                pdfaAfterSign = PDFAValidator().validate(signed.pdfData).isValid
                    || (signed.asicData != nil && pdfaPrepared)
            }

            result = signed
            statusText = ""
            step = .done
        } catch {
            statusText = ""
            let wasCancelled = (error as? AVMError) == .cancelled || (error as? AGPError) == .cancelled
            if wasCancelled {
                // The user closed the QR sheet; the document stays ready for another attempt.
                if let index = queue.firstIndex(where: { $0.id == selectedQueueID }),
                   queue[index].status == .signing {
                    queue[index].status = .ready
                }
            } else {
                lastError = error.localizedDescription
                if let index = queue.firstIndex(where: { $0.id == selectedQueueID }) {
                    queue[index].status = .failed
                    queue[index].errorMessage = error.localizedDescription
                }
            }
        }
        isSigning = false
        isSigningViaMobile = false
    }

    var unsignedQueueItems: [SigningQueueItem] {
        queue.filter { $0.status == .ready || $0.status == .failed }
    }

    func signAllUnsigned() async {
        let ids = unsignedQueueItems.map(\.id)
        for id in ids {
            await selectQueueItem(id)
            if let index = queue.firstIndex(where: { $0.id == id }) {
                queue[index].status = .signing
            }
            await sign()
            if queue.first(where: { $0.id == id })?.status != .signed {
                break
            }
        }
    }

    func prepareBatch(ids: [UUID]) async {
        guard batchPhase != .preflighting, batchPhase != .signing else { return }
        invalidateBatchWork()
        let generation = batchGeneration
        batchPhase = .preflighting
        batchItems = []
        batchCompletedCount = 0
        batchFailedCount = 0
        batchCurrentIndex = nil
        batchErrorDecisionRequest = nil
        batchSettingsSnapshot = nil
        batchOptionsError = nil
        batchPIN = nil
        lastError = nil

        var seenURLs = Set<URL>()
        var selectedItems: [SigningQueueItem] = []
        var inputErrors: [String] = []
        for id in ids {
            guard let item = queue.first(where: { $0.id == id }) else {
                inputErrors.append("Dokument s identifikátorom \(id.uuidString) sa nenachádza vo fronte.")
                continue
            }
            guard item.status == .ready || item.status == .failed else {
                inputErrors.append("Dokument \(item.displayName) nie je pripravený na podpis.")
                continue
            }
            let standardizedURL = item.url.standardizedFileURL
            guard seenURLs.insert(standardizedURL).inserted else { continue }
            selectedItems.append(item)
        }

        guard !selectedItems.isEmpty, inputErrors.isEmpty else {
            if selectedItems.isEmpty, inputErrors.isEmpty {
                inputErrors.append("Na podpisovanie nebol vybraný žiadny dokument.")
            }
            batchItems = selectedItems.map {
                BatchItem(id: $0.id, displayName: $0.displayName, url: $0.url,
                          state: .failed, errorMessage: inputErrors.first)
            }
            batchFailedCount = batchItems.count
            batchPhase = .idle
            lastError = inputErrors.joined(separator: " ")
            return
        }

        batchItems = selectedItems.map {
            BatchItem(id: $0.id, displayName: $0.displayName, url: $0.url)
        }

        var blockingErrors: [String] = inputErrors
        guard batchGeneration == generation else { return }
        var documents: [UUID: PDFDocument] = [:]
        for item in selectedItems {
            let secured = item.url.startAccessingSecurityScopedResource()
            defer { if secured { item.url.stopAccessingSecurityScopedResource() } }
            guard item.url.isFileURL,
                  FileManager.default.isReadableFile(atPath: item.url.path),
                  let document = PDFDocument(url: item.url),
                  document.pageCount > 0 else {
                let message = "Dokument \(item.displayName) sa nepodarilo načítať ako PDF."
                if let batchIndex = batchItems.firstIndex(where: { $0.id == item.id }) {
                    batchItems[batchIndex].state = .failed
                    batchItems[batchIndex].errorMessage = message
                }
                continue
            }
            documents[item.id] = document
        }

        if documents.isEmpty {
            let messages = batchItems.compactMap(\.errorMessage)
            batchFailedCount = batchItems.count
            batchPhase = .idle
            lastError = messages.joined(separator: " ")
            return
        }

        let discovered = await signingProvider.availableIdentities()
        guard batchGeneration == generation else { return }
        identities = discovered
        if selectedIdentityID == nil {
            selectedIdentityID = discovered.first(where: { $0.isMandateCertificate })?.id
                ?? discovered.first?.id
        }
        guard batchGeneration == generation else { return }
        guard let discoveredIdentityID = selectedIdentityID,
              var identity = discovered.first(where: { $0.id == discoveredIdentityID }) else {
            blockingErrors.append("Nie je dostupný podpisový certifikát.")
            finishBatchPreflight(blockingErrors: blockingErrors)
            return
        }
        guard identity.hasPrivateKey else {
            blockingErrors.append("Vybraný certifikát nemá dostupný súkromný kľúč.")
            finishBatchPreflight(blockingErrors: blockingErrors)
            return
        }

        let inspectableItems = selectedItems.filter { documents[$0.id] != nil }
        let inspections = await signingProvider.inspectInputSignatures(
            in: inspectableItems.map(\.url))
        guard batchGeneration == generation else { return }
        for item in inspectableItems {
            guard let batchIndex = batchItems.firstIndex(where: { $0.id == item.id }) else {
                continue
            }
            let inspection = inspections[EnginePaths.canonical(item.url)]
                ?? .unavailable(detail: "Kontrola vstupného dokumentu nevrátila výsledok.")
            batchItems[batchIndex].inputSignatureState = inspection.state
            batchItems[batchIndex].inputSignatureDetail = inspection.detail
            guard inspection.state == .invalid else { continue }
            batchItems[batchIndex].state = .failed
            batchItems[batchIndex].errorMessage = inspection.detail
        }

        let pin = signingPIN
        let requiresCertificateResolution = identity.requiresPIN
            || discoveredIdentityID.hasPrefix(EngineBridgeSigningProvider.syntheticIdentityIDPrefix)
        guard !identity.requiresPIN || !pin.isEmpty else {
            blockingErrors.append("Pre vybraný certifikát je potrebný PIN.")
            finishBatchPreflight(blockingErrors: blockingErrors)
            return
        }
        if requiresCertificateResolution {
            let resolved = await signingProvider.resolveIdentities(pin: pin)
            guard batchGeneration == generation else { return }
            if let resolved, !resolved.isEmpty {
                identities = resolved
                if let matching = resolved.first(where: { $0.id == discoveredIdentityID }) {
                    identity = matching
                } else if discoveredIdentityID.hasPrefix(
                    EngineBridgeSigningProvider.syntheticIdentityIDPrefix) {
                    guard let authoritative = resolved.first(where: { $0.isMandateCertificate })
                        ?? resolved.first else {
                        blockingErrors.append("Po overení PIN nie je dostupný podpisový certifikát.")
                        finishBatchPreflight(blockingErrors: blockingErrors)
                        return
                    }
                    identity = authoritative
                    selectedIdentityID = authoritative.id
                } else {
                    blockingErrors.append("Vybraný certifikát sa po overení PIN nedal nájsť.")
                    finishBatchPreflight(blockingErrors: blockingErrors)
                    return
                }
            } else {
                identities = []
                blockingErrors.append("Po overení PIN nie je dostupný podpisový certifikát.")
            }
        }

        let identityID = identity.id
        let effectiveVisualPage = visualPlacement?.pageIndex ?? signaturePage
        if let firstItem = selectedItems.first(where: {
            !ExistingSignatureGuard.hasContainerExtension($0.url.lastPathComponent)
        }) ?? selectedItems.first {
            let defaultName = firstItem.url.deletingPathExtension().lastPathComponent + "_podpisane"
            // Keep a name the person typed; follow the default otherwise.
            if batchContainerName.isEmpty || batchContainerName == batchContainerDefaultName {
                batchContainerName = defaultName
            }
            batchContainerDefaultName = defaultName
        }
        var snapshot = BatchSettingsSnapshot(
            outputFormat: outputFormat,
            asicPackaging: batchASiCPackaging,
            containerStem: nil,
            includeQualifiedTimestamp: includeQualifiedTimestamp,
            tsaURL: includeQualifiedTimestamp ? selectedTSAURL : nil,
            convertToPDFA: convertToPDFA,
            pdfaMode: pdfaMode,
            selectedIdentityID: identityID,
            identityLabel: identity.label,
            identityIsQualified: identity.isQualified,
            includeVisibleSignature: includeVisibleSignature,
            selectedVisualAppearanceID: selectedVisualAppearanceID,
            visualArtworkOverride: visualArtworkOverride,
            visualPlacement: visualPlacement,
            signaturePage: effectiveVisualPage,
            signatureRect: signatureRect)
        applyCurrentBatchOptions(to: &snapshot)

        if let optionsError = Self.batchOptionsError(for: snapshot) {
            blockingErrors.append(optionsError)
        }

        if snapshot.includeVisibleSignature {
            if let placementError = Self.validateBatchVisualPlacement(
                placement: snapshot.visualPlacement,
                normalizedRect: snapshot.signatureRect,
                pageCount: nil) {
                blockingErrors.append(placementError)
            } else if let placement = snapshot.visualPlacement {
                for item in selectedItems {
                    guard let document = documents[item.id] else { continue }
                    guard let placementError = Self.validateBatchVisualPlacement(
                        placement: placement,
                        normalizedRect: snapshot.signatureRect,
                        pageCount: document.pageCount,
                        pageBounds: document.page(at: placement.pageIndex)?.bounds(for: .cropBox)) else {
                        continue
                    }
                    guard let batchIndex = batchItems.firstIndex(where: { $0.id == item.id }) else {
                        continue
                    }
                    batchItems[batchIndex].state = .failed
                    batchItems[batchIndex].errorMessage = placementError
                }
            }
            if !signingProviderIsDemo && snapshot.selectedIdentityID.isEmpty {
                blockingErrors.append("Certifikát pre vizuálny podpis nie je dostupný.")
            }
        }

        for item in selectedItems where documents[item.id] != nil {
            // A batch signs PDFs; a container's own signatures would be lost when its
            // PDF is extracted and signed again, so it is signed on its own instead.
            guard ExistingSignatureGuard.hasContainerExtension(item.url.lastPathComponent),
                  let batchIndex = batchItems.firstIndex(where: { $0.id == item.id }) else {
                continue
            }
            batchItems[batchIndex].state = .failed
            batchItems[batchIndex].errorMessage = Self.containerInBatchMessage
        }
        if let planningError = planBatchOutputs(for: snapshot) {
            blockingErrors.append(planningError)
        }

        guard blockingErrors.isEmpty else {
            finishBatchPreflight(blockingErrors: blockingErrors)
            return
        }

        batchSettingsSnapshot = snapshot
        batchPIN = pin.isEmpty ? nil : pin
        batchPhase = .ready
        }
    /// Takes the batch card's current options (format, packaging, container name,
    /// timestamp, PDF/A) into a ready batch without reading the card again: only the
    /// planned outputs change. Options that cannot be signed keep the batch ready but
    /// stop it from starting (`batchOptionsError`).
    func refreshReadyBatchOptions() {
        guard batchPhase == .ready, var snapshot = batchSettingsSnapshot else { return }
        applyCurrentBatchOptions(to: &snapshot)
        batchSettingsSnapshot = snapshot
        let planningError = planBatchOutputs(for: snapshot)
        batchOptionsError = Self.batchOptionsError(for: snapshot) ?? planningError
    }

    private func applyCurrentBatchOptions(to snapshot: inout BatchSettingsSnapshot) {
        snapshot.outputFormat = outputFormat
        snapshot.asicPackaging = batchASiCPackaging
        snapshot.containerStem = outputFormat == .attachedASIC && batchASiCPackaging == .combined
            ? (Self.containerStem(from: batchContainerName)
                ?? Self.containerStem(from: batchContainerDefaultName)
                ?? "podpisane")
            : nil
        snapshot.includeQualifiedTimestamp = includeQualifiedTimestamp
        snapshot.tsaURL = includeQualifiedTimestamp ? selectedTSAURL : nil
        snapshot.convertToPDFA = convertToPDFA
        snapshot.pdfaMode = pdfaMode
    }

    private static func batchOptionsError(for snapshot: BatchSettingsSnapshot) -> String? {
        guard snapshot.includeQualifiedTimestamp,
              snapshot.tsaURL.flatMap({ URL(string: $0)?.scheme }) == nil else { return nil }
        return "Adresa služby časovej pečiatky nie je platná."
    }

    /// A file name stem for the shared container: the typed name without ".asice",
    /// sanitized; nil when nothing usable is left.
    static func containerStem(from name: String) -> String? {
        var trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasSuffix(".asice") {
            trimmed = String(trimmed.dropLast(".asice".count))
        }
        let sanitized = ASiCEPackager.sanitizedFileName(trimmed)
        return sanitized.isEmpty ? nil : sanitized
    }

    /// Plans the output of every pending item: one shared container for a combined
    /// ASiC-E, else a `_podpisane` sibling each. Returns an error that blocks the batch.
    private func planBatchOutputs(for snapshot: BatchSettingsSnapshot) -> String? {
        var plannedURLs = Set<URL>()
        let pendingIndices = batchItems.indices.filter { batchItems[$0].state == .pending }
        if let containerStem = snapshot.containerStem {
            guard let firstIndex = pendingIndices.first else { return nil }
            let firstURL = batchItems[firstIndex].url
            do {
                let planned = try outputService.previewUniqueSibling(
                    for: firstURL,
                    in: outputLocation(for: firstURL).directory,
                    stem: containerStem,
                    stemSuffix: "",
                    outputExtension: "asice")
                for index in pendingIndices {
                    batchItems[index].plannedOutputURL = planned
                }
                return nil
            } catch {
                return "Cieľový spoločný ASiC-E výstup sa nepodarilo pripraviť."
            }
        }
        let outputExtension = snapshot.outputFormat == .embeddedPAdES ? "pdf" : "asice"
        for index in pendingIndices {
            let url = batchItems[index].url
            do {
                let planned = try outputService.previewUniqueSibling(
                    for: url,
                    in: outputLocation(for: url).directory,
                    stemSuffix: "_podpisane",
                    outputExtension: outputExtension,
                    occupiedURLs: plannedURLs)
                batchItems[index].plannedOutputURL = planned
                plannedURLs.insert(planned.standardizedFileURL)
            } catch {
                batchItems[index].plannedOutputURL = nil
                batchItems[index].state = .failed
                batchItems[index].errorMessage = "Cieľový výstup sa nepodarilo pripraviť."
            }
        }
        return nil
    }

    private func finishBatchPreflight(blockingErrors: [String]) {
        guard !blockingErrors.isEmpty else {
            batchPhase = .ready
            return
        }
        let message = blockingErrors.joined(separator: " ")
        for index in batchItems.indices {
            batchItems[index].state = .failed
            batchItems[index].errorMessage = message
        }
        batchFailedCount = batchItems.count
        batchPhase = .idle
        lastError = message
        batchSettingsSnapshot = nil
        batchOptionsError = nil
        batchPIN = nil
    }

    func startBatch() async {
        guard batchPhase == .ready,
              batchOptionsError == nil,
              let snapshot = batchSettingsSnapshot,
              !batchItems.isEmpty else { return }

        let generation = UUID()
        batchGeneration = generation
        batchErrorDecisionRequest = nil
        batchPhase = .signing
        lastError = nil
        let pin = batchPIN
        if snapshot.outputFormat == .attachedASIC, snapshot.containerStem != nil {
            await signCombinedASiCBatch(snapshot: snapshot, pin: pin, generation: generation)
            return
        }


        for index in batchItems.indices {
            guard batchGeneration == generation else { return }
            guard batchItems[index].state == .pending else { continue }
            batchCurrentIndex = index
            batchItems[index].state = .signing
            batchItems[index].errorMessage = nil
            if let queueIndex = queue.firstIndex(where: { $0.id == batchItems[index].id }) {
                queue[queueIndex].status = .signing
            }

            do {
                let output = try await signBatchItem(
                    batchItems[index], snapshot: snapshot, pin: pin, generation: generation)
                guard batchGeneration == generation else { return }
                batchItems[index].state = .signed
                batchItems[index].outputURL = output.outputURL
                batchItems[index].errorMessage = nil
                if let queueIndex = queue.firstIndex(where: { $0.id == batchItems[index].id }) {
                    queue[queueIndex].status = .signed
                    queue[queueIndex].signedOutputURL = output.outputURL
                    queue[queueIndex].errorMessage = nil
                }
                batchCompletedCount = batchItems.filter { $0.state == .signed }.count
                batchFailedCount = batchItems.filter { $0.state == .failed }.count
            } catch is BatchCancellationError {
                return
            } catch {
                guard batchGeneration == generation, batchPhase == .signing else { return }
                let message = error.localizedDescription
                batchItems[index].state = .failed
                batchItems[index].errorMessage = message
                if let queueIndex = queue.firstIndex(where: { $0.id == batchItems[index].id }) {
                    queue[queueIndex].status = .failed
                    queue[queueIndex].errorMessage = message
                }
                batchFailedCount = batchItems.filter { $0.state == .failed }.count
                batchErrorDecisionRequest = BatchFailureDecisionRequest(
                    itemID: batchItems[index].id,
                    displayName: batchItems[index].displayName,
                    errorMessage: message)
                let decision = await withCheckedContinuation { continuation in
                    batchDecisionContinuation = continuation
                }
                guard batchGeneration == generation else { return }
                batchErrorDecisionRequest = nil
                if decision == .stopBatch {
                    for remaining in (index + 1)..<batchItems.count
                    where batchItems[remaining].state == .pending {
                        batchItems[remaining].state = .skipped
                    }
                    break
                }
            }
        }

        guard batchGeneration == generation else { return }
        batchCurrentIndex = nil
        batchPhase = .completed
        batchCompletedCount = batchItems.filter { $0.state == .signed }.count
        batchFailedCount = batchItems.filter { $0.state == .failed }.count
        batchPIN = nil
    }

    func decideBatchFailure(_ decision: BatchFailureDecision) {
        guard batchErrorDecisionRequest != nil else { return }
        batchErrorDecisionRequest = nil
        batchDecisionContinuation?.resume(returning: decision)
        batchDecisionContinuation = nil
    }

    func cancelBatch() {
        guard batchPhase == .preflighting || batchPhase == .ready || batchPhase == .signing else { return }
        invalidateBatchWork()
        var cancelledIDs = Set<UUID>()
        for index in batchItems.indices where batchItems[index].state == .pending
            || batchItems[index].state == .signing {
            cancelledIDs.insert(batchItems[index].id)
            batchItems[index].state = .cancelled
        }
        for index in queue.indices where cancelledIDs.contains(queue[index].id)
            && queue[index].status != .signed {
            queue[index].status = .ready
            queue[index].errorMessage = nil
        }
        batchCurrentIndex = nil
        batchErrorDecisionRequest = nil
        batchPIN = nil
        batchPhase = .cancelled
        batchCompletedCount = batchItems.filter { $0.state == .signed }.count
        batchFailedCount = batchItems.filter { $0.state == .failed }.count
    }

    func retryFailedBatchItems() async {
        guard batchPhase == .completed || batchPhase == .cancelled else { return }
        let previousItems = batchItems
        let failedIDs = previousItems.filter { $0.state == .failed }.map(\.id)
        guard !failedIDs.isEmpty else { return }
        await prepareBatch(ids: failedIDs)
        guard batchPhase == .ready else { return }
        let preparedByID = Dictionary(uniqueKeysWithValues: batchItems.map { ($0.id, $0) })
        batchItems = previousItems.map { preparedByID[$0.id] ?? $0 }
        batchCompletedCount = batchItems.filter { $0.state == .signed }.count
        batchFailedCount = batchItems.filter { $0.state == .failed }.count
        await startBatch()
    }

    private func invalidateBatchWork() {
        batchGeneration = UUID()
        batchDecisionContinuation?.resume(returning: .stopBatch)
        batchDecisionContinuation = nil
    }

    private func signCombinedASiCBatch(
        snapshot: BatchSettingsSnapshot,
        pin: String?,
        generation: UUID
    ) async {
        do {
            try checkBatchGeneration(generation)
            let selectedItems = batchItems.filter { $0.state == .pending }
            guard let firstItem = selectedItems.first else {
                throw SigningError.signingFailed("Na podpisovanie nebol vybraný žiadny dokument.")
            }

            var entries: [ASiCEPackager.Entry] = []
            var usedNames = Set<String>()
            for item in selectedItems {
                try checkBatchGeneration(generation)
                let document = try loadBatchPDF(item.url)
                var pdfData = try batchPDFData(for: item.url, document: document)
                // A signed PDF goes in untouched: the stamp and PDF/A rewrite would drop its signature.
                let keepsBytes = ExistingSignatureGuard.pdfContainsSignature(pdfData)
                if snapshot.includeVisibleSignature, !keepsBytes {
                    let stamp = VisibleSignatureStamper.StampData(
                        fullName: snapshot.identityLabel,
                        timestamp: Date(),
                        pageIndex: snapshot.visualPlacement?.pageIndex ?? snapshot.signaturePage,
                        normalizedRect: snapshot.signatureRect,
                        imagePNG: snapshot.visualArtworkOverride
                            ?? VisualSignatureStore.imageData(for: snapshot.selectedVisualAppearanceID, in: settingsStore.signaturesDirectory),
                        certificateName: snapshot.identityLabel,
                        certificateQualification: snapshot.identityIsQualified
                            ? "Kvalifikovaný elektronický podpis" : nil,
                        timestampAuthorityName: snapshot.includeQualifiedTimestamp
                            ? (settings.availableTSAServers.first { $0.url == snapshot.tsaURL }?.name ?? snapshot.tsaURL)
                            : nil)
                    pdfData = await Self.stampPDFData(
                        pdfData,
                        stamp: stamp,
                        includeTimestamp: snapshot.includeQualifiedTimestamp,
                        stamper: stamper,
                        flattenAnnotations: true)
                }
                if snapshot.convertToPDFA, !keepsBytes {
                    let pdfaDocument = PDFDocument(data: pdfData) ?? document
                    pdfData = try PDFAConverter().convert(
                        document: pdfaDocument,
                        mode: .rasterGuaranteed,
                        title: item.url.deletingPathExtension().lastPathComponent)
                    guard PDFAValidator().validate(pdfData).isValid else {
                        throw SigningError.signingFailed("Konverzia do PDF/A zlyhala pri súbore \(item.displayName).")
                    }
                }
                let baseName = item.url.deletingPathExtension().lastPathComponent
                var entryName = "\(baseName).pdf"
                var suffix = 2
                while !usedNames.insert(entryName).inserted {
                    entryName = "\(baseName) (\(suffix)).pdf"
                    suffix += 1
                }
                entries.append(.init(path: entryName, data: pdfData))
            }

            guard let firstData = entries.first?.data else {
                throw SigningError.signingFailed("Dávka neobsahuje žiadne PDF dáta.")
            }
            let signed = try await signingProvider.sign(SigningRequest(
                pdfData: firstData,
                identityID: snapshot.selectedIdentityID,
                includeTimestamp: snapshot.includeQualifiedTimestamp,
                tsaURL: snapshot.tsaURL,
                outputFormat: .attachedASIC,
                pin: pin,
                extraFiles: entries,
                filename: entries.first?.path,
                // One ASiC-E with every PDF as its own data object, not a packaged
                // container nested inside the signed one.
                signsExtraFilesAsDataObjects: true))
            guard let asicData = signed.asicData else {
                throw SigningError.signingFailed("Podpisový provider nevytvoril ASiC-E kontajner.")
            }
            let directory = outputLocation(for: firstItem.url).directory
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let reservation = try outputService.reserveUniqueSibling(
                for: firstItem.url,
                in: directory,
                stem: snapshot.containerStem,
                stemSuffix: snapshot.containerStem == nil ? "_podpisane" : "",
                outputExtension: "asice")
            do {
                try checkBatchGeneration(generation)
                try asicData.write(to: reservation.temporaryURL, options: [.atomic])
                try outputService.finalize(reservation)
            } catch {
                outputService.discard(reservation)
                throw error
            }

            for index in batchItems.indices where batchItems[index].state == .pending {
                batchItems[index].state = .signed
                batchItems[index].outputURL = reservation.finalURL
                batchItems[index].plannedOutputURL = reservation.finalURL
                batchItems[index].errorMessage = nil
                if let queueIndex = queue.firstIndex(where: { $0.id == batchItems[index].id }) {
                    queue[queueIndex].status = .signed
                    queue[queueIndex].signedOutputURL = reservation.finalURL
                    queue[queueIndex].errorMessage = nil
                }
            }
            batchCompletedCount = batchItems.filter { $0.state == .signed }.count
            batchFailedCount = batchItems.filter { $0.state == .failed }.count
            batchCurrentIndex = nil
            batchPhase = .completed
            batchPIN = nil
        } catch is BatchCancellationError {
            return
        } catch {
            guard batchGeneration == generation, batchPhase == .signing else { return }
            let message = error.localizedDescription
            for index in batchItems.indices where batchItems[index].state == .pending {
                batchItems[index].state = .failed
                batchItems[index].errorMessage = message
                if let queueIndex = queue.firstIndex(where: { $0.id == batchItems[index].id }) {
                    queue[queueIndex].status = .failed
                    queue[queueIndex].errorMessage = message
                }
            }
            batchFailedCount = batchItems.filter { $0.state == .failed }.count
            batchPhase = .completed
            batchPIN = nil
        }
    }

    private func loadBatchPDF(_ url: URL) throws -> PDFDocument {
        if url.pathExtension.lowercased() == "asice",
           let data = try? Data(contentsOf: url),
           let pdfData = ASiCEContainerVerifier.extractPDFData(data),
           let document = PDFDocument(data: pdfData) {
            return document
        }
        guard let document = PDFDocument(url: url) else {
            throw SigningError.signingFailed("Súbor \(url.lastPathComponent) sa nepodarilo otvoriť ako PDF.")
        }
        return document
    }

    private func batchPDFData(for url: URL, document: PDFDocument) throws -> Data {
        if url.pathExtension.lowercased() != "asice",
           let data = try? Data(contentsOf: url),
           !data.isEmpty {
            return data
        }
        guard let data = document.dataRepresentation(), !data.isEmpty else {
            throw SigningError.signingFailed("PDF dokument \(url.lastPathComponent) neobsahuje žiadne dáta.")
        }
        return data
    }

    private struct BatchCancellationError: Error {}

    private struct BatchSigningOutput {
        let result: SignedConversionResult
        let outputURL: URL
        let outputDirectory: URL
        let pdfaPrepared: Bool
        let pdfaAfterSign: Bool
    }

    private func signBatchItem(
        _ item: BatchItem,
        snapshot: BatchSettingsSnapshot,
        pin: String?,

        generation: UUID
    ) async throws -> BatchSigningOutput {
        try checkBatchGeneration(generation)
        let secured = item.url.startAccessingSecurityScopedResource()
        defer { if secured { item.url.stopAccessingSecurityScopedResource() } }
        guard let document = PDFDocument(url: item.url) else {
            throw SigningError.signingFailed("Súbor sa nepodarilo otvoriť ako PDF.")
        }
        var pdfData: Data
        if let original = try? Data(contentsOf: item.url), !original.isEmpty {
            pdfData = original
        } else {
            let doc = UncheckedSendable(document)
            pdfData = try await Task.detached(priority: .userInitiated) {
                doc.value.dataRepresentation()
            }.get() ?? Data()
        }
        guard !pdfData.isEmpty else {
            throw SigningError.signingFailed("PDF dokument neobsahuje žiadne dáta.")
        }
        let originalPDFData = pdfData
        // A signed PDF goes in untouched: the stamp and PDF/A rewrite would drop its signature.
        let rewritesPDF = !ExistingSignatureGuard.pdfContainsSignature(pdfData)
        var didPreparePDFA = false
        var didFallbackToOriginal = false
        var visualStampWasPreapplied = false
        var attachedStamp: VisibleSignatureStamper.StampData?
        if rewritesPDF,
           snapshot.convertToPDFA,
           snapshot.includeVisibleSignature,
           snapshot.outputFormat == .attachedASIC {
            let stamp = VisibleSignatureStamper.StampData(
                fullName: snapshot.identityLabel,
                timestamp: Date(),
                pageIndex: snapshot.visualPlacement?.pageIndex ?? snapshot.signaturePage,
                normalizedRect: snapshot.signatureRect,
                imagePNG: snapshot.visualArtworkOverride
                    ?? VisualSignatureStore.imageData(for: snapshot.selectedVisualAppearanceID, in: settingsStore.signaturesDirectory),
                certificateName: snapshot.identityLabel,
                certificateQualification: snapshot.identityIsQualified
                    ? "Kvalifikovaný elektronický podpis" : nil,
                timestampAuthorityName: snapshot.includeQualifiedTimestamp
                    ? (settings.availableTSAServers.first { $0.url == snapshot.tsaURL }?.name ?? snapshot.tsaURL)
                    : nil)
            try checkBatchGeneration(generation)
            let stampedData = await Self.stampPDFData(
                pdfData,
                stamp: stamp,
                includeTimestamp: snapshot.includeQualifiedTimestamp,
                stamper: stamper,
                flattenAnnotations: true)
            visualStampWasPreapplied = stampedData != pdfData
            if snapshot.outputFormat == .attachedASIC {
                attachedStamp = stamp
            }
            pdfData = stampedData
        }
        

        if rewritesPDF, snapshot.convertToPDFA {
            let mode: PDFAConversionMode =
                snapshot.outputFormat == .embeddedPAdES || visualStampWasPreapplied
                ? .rasterGuaranteed
                : snapshot.pdfaMode
            let pdfaDocument = PDFDocument(data: pdfData) ?? document
            pdfData = try PDFAConverter().convert(
                document: pdfaDocument, mode: mode,
                title: item.url.deletingPathExtension().lastPathComponent)
            var check = PDFAValidator().validate(pdfData)
            if !check.isValid {
                pdfData = try PDFAConverter().convert(
                    document: PDFDocument(data: pdfData) ?? pdfaDocument,
                    mode: .rasterGuaranteed,
                    title: item.url.deletingPathExtension().lastPathComponent)
                check = PDFAValidator().validate(pdfData)
            }
            guard check.isValid else {
                throw SigningError.signingFailed(
                    "Konverzia do PDF/A zlyhala: \(check.issues.joined(separator: "; ")).")
            }
            didPreparePDFA = true
        }
        if rewritesPDF,
           !snapshot.convertToPDFA,
           snapshot.includeVisibleSignature,
           snapshot.outputFormat == .attachedASIC {
            let imageData = snapshot.visualArtworkOverride
                ?? VisualSignatureStore.imageData(for: snapshot.selectedVisualAppearanceID, in: settingsStore.signaturesDirectory)
            let stamp = VisibleSignatureStamper.StampData(
                fullName: snapshot.identityLabel,
                timestamp: Date(),
                pageIndex: snapshot.signaturePage,
                normalizedRect: snapshot.signatureRect,
                imagePNG: imageData,
                certificateName: snapshot.identityLabel,
                certificateQualification: snapshot.identityIsQualified
                    ? "Kvalifikovaný elektronický podpis" : nil,
                timestampAuthorityName: snapshot.includeQualifiedTimestamp
                    ? (settings.availableTSAServers.first { $0.url == snapshot.tsaURL }?.name ?? snapshot.tsaURL)
                    : nil)
            attachedStamp = stamp
            try checkBatchGeneration(generation)
            pdfData = await Self.stampPDFData(
                pdfData,
                stamp: stamp,
                includeTimestamp: snapshot.includeQualifiedTimestamp,
                stamper: stamper,
                flattenAnnotations: true)
        }

        let visualStamp: VisualStampSpec?
        if snapshot.includeVisibleSignature,
           snapshot.outputFormat == .embeddedPAdES {
            visualStamp = VisualStampSpec(
                fullName: snapshot.identityLabel,
                timestamp: Date(),
                pageIndex: snapshot.visualPlacement?.pageIndex ?? snapshot.signaturePage,
                normalizedRect: snapshot.signatureRect,
                imagePNG: snapshot.visualArtworkOverride
                    ?? VisualSignatureStore.imageData(for: snapshot.selectedVisualAppearanceID, in: settingsStore.signaturesDirectory),
                // Batch placement is always relative to the current target page.
                pdfPageRect: nil,
                rotationDegrees: snapshot.visualPlacement?.rotationDegrees ?? 0,
                qualification: snapshot.identityIsQualified
                    ? "Kvalifikovaný elektronický podpis" : nil,
                certificateName: snapshot.identityLabel,
                timestampAuthorityName: snapshot.includeQualifiedTimestamp
                    ? (settings.availableTSAServers.first { $0.url == snapshot.tsaURL }?.name ?? snapshot.tsaURL)
                    : nil)
        } else {
            visualStamp = nil
        }
        let request = SigningRequest(
            pdfData: pdfData,
            identityID: snapshot.selectedIdentityID,
            includeTimestamp: snapshot.includeQualifiedTimestamp,
            tsaURL: snapshot.tsaURL,
            outputFormat: snapshot.outputFormat,
            pin: pin,
            extraFiles: [ASiCEPackager.Entry(path: item.url.lastPathComponent, data: pdfData)],
            visualStamp: visualStamp,
            filename: item.url.lastPathComponent,
            signsExtraFilesAsDataObjects: true)
        var signed: SignedConversionResult
        do {
            try checkBatchGeneration(generation)
            signed = try await signingProvider.sign(request)
            try checkBatchGeneration(generation)
        } catch {
            let text = error.localizedDescription
            if snapshot.convertToPDFA, didPreparePDFA,
               text.contains("SIGNING_UNAVAILABLE") || text.contains("SIGNING_FAILED") {
                didFallbackToOriginal = true
                var fallbackPDFData = originalPDFData
                if let attachedStamp {
                    try checkBatchGeneration(generation)
                    fallbackPDFData = await Self.stampPDFData(
                        fallbackPDFData, stamp: attachedStamp,
                        includeTimestamp: snapshot.includeQualifiedTimestamp,
                        stamper: stamper)
                }
                try checkBatchGeneration(generation)
                signed = try await signingProvider.sign(SigningRequest(
                    pdfData: fallbackPDFData,
                    identityID: snapshot.selectedIdentityID,
                    includeTimestamp: snapshot.includeQualifiedTimestamp,
                    tsaURL: snapshot.tsaURL,
                    outputFormat: snapshot.outputFormat,
                    pin: pin,
                    extraFiles: [ASiCEPackager.Entry(
                        path: item.url.lastPathComponent, data: fallbackPDFData)],
                    visualStamp: visualStamp,
                    filename: item.url.lastPathComponent,
                    signsExtraFilesAsDataObjects: true))
                try checkBatchGeneration(generation)
            } else {
                throw error
            }
        }

        try checkBatchGeneration(generation)
        let directory = outputLocation(for: item.url).directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try checkBatchGeneration(generation)
        let outputData: Data
        let outputExtension: String
        if snapshot.outputFormat == .embeddedPAdES {
            outputData = signed.pdfData
            outputExtension = "pdf"
        } else if let asic = signed.asicData {
            outputData = asic
            outputExtension = "asice"
        } else {
            outputData = signed.pdfData
            outputExtension = "pdf"
        }
        let reservation = try outputService.reserveUniqueSibling(
            for: item.url,
            in: directory,
            stemSuffix: "_podpisane",
            outputExtension: outputExtension)
        do {
            try checkBatchGeneration(generation)
            try outputData.write(to: reservation.temporaryURL, options: [.atomic])
            try checkBatchGeneration(generation)
            try outputService.finalize(reservation)
        } catch {
            outputService.discard(reservation)
            throw error
        }
        return BatchSigningOutput(
            result: signed,
            outputURL: reservation.finalURL,
            outputDirectory: directory,
            pdfaPrepared: didPreparePDFA && !didFallbackToOriginal,
            pdfaAfterSign: PDFAValidator().validate(signed.pdfData).isValid
                || (signed.asicData != nil && didPreparePDFA && !didFallbackToOriginal))
    }

    static func validateBatchVisualPlacement(
        placement: VisibleSignaturePlacement?,
        normalizedRect: NormalizedRect,
        pageCount: Int?,
        pageBounds: CGRect? = nil
    ) -> String? {
        guard let placement else {
            return "Vizuálny podpis vyžaduje explicitné umiestnenie."
        }
        guard placement.pageIndex >= 0,
              placement.rotationDegrees.isFinite else {
            return "Vizuálny podpis nemá platné umiestnenie."
        }
        guard normalizedRect.x.isFinite,
              normalizedRect.y.isFinite,
              normalizedRect.width.isFinite,
              normalizedRect.height.isFinite,
              normalizedRect.x >= 0,
              normalizedRect.y >= 0,
              normalizedRect.width > 0,
              normalizedRect.height > 0,
              normalizedRect.x + normalizedRect.width <= 1,
              normalizedRect.y + normalizedRect.height <= 1 else {
            return "Vizuálny podpis nemá platné relatívne umiestnenie."
        }
        if let pageCount, placement.pageIndex >= pageCount {
            return "Umiestnenie vizuálneho podpisu nie je dostupné na tejto strane."
        }
        if pageCount != nil {
            guard let pageBounds,
                  pageBounds.width.isFinite,
                  pageBounds.height.isFinite,
                  pageBounds.width > 0,
                  pageBounds.height > 0 else {

                return "Cieľová strana PDF nemá platné rozmery."
            }
        }
        return nil
    }
    private func previewDocument(for url: URL) -> PDFDocument? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        if url.pathExtension.lowercased() != "asice" {
            return PDFDocument(data: data)
        }
        guard let pdfData = ASiCEContainerVerifier.extractPDFData(data) else {
            return nil
        }
        return PDFDocument(data: pdfData)
    }

    private func checkBatchGeneration(_ generation: UUID) throws {
        guard batchGeneration == generation else { throw BatchCancellationError() }
    }

    static func stampPDFData(
        _ data: Data,
        stamp: VisibleSignatureStamper.StampData,
        includeTimestamp: Bool,
        stamper: VisibleSignatureStamper,
        flattenAnnotations: Bool = false
    ) async -> Data {
        guard let source = PDFDocument(data: data) else { return data }
        let sendableSource = UncheckedSendable(source)
        return await Task.detached(priority: .userInitiated) {
            if flattenAnnotations {
                return stamper.flattenedStamp(
                    document: sendableSource.value,
                    stamp: stamp,
                    includeTimestamp: includeTimestamp)
            }
            return stamper.stamp(
                document: sendableSource.value,
                stamp: stamp,
                includeTimestamp: includeTimestamp)
        }.value ?? data
    }

    private func outputLocation(for url: URL) -> (directory: URL, stem: String) {
        let directory = FileManager.default.isWritableFile(
            atPath: url.deletingLastPathComponent().path)
            ? url.deletingLastPathComponent() : settingsStore.outputDirectory
        return (directory, "\(url.deletingPathExtension().lastPathComponent)_podpisane")
    }


    var stampDisplayName: String {
        displayName()
    }

    func displayName() -> String {
        if let identity = identities.first(where: { $0.id == selectedIdentityID }),
           identity.label != "DEMO podpis (vývojový režim)" {
            return identity.label
        }
        return "Elektronický podpis Chevron7"
    }

    func addCustomTSA(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var next = settingsStore.settings
        if !next.customTSAServers.contains(where: { $0.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            next.customTSAServers.append(trimmed)
        }
        next.selectedTSAURL = trimmed
        settingsStore.settings = next
    }

    func reset(keepingIdentity: Bool = true) {
        let identity = keepingIdentity ? selectedIdentityID : nil
        selectedQueueID = nil
        step = queue.isEmpty ? .intake : .prepare
        sourceURL = nil
        sourceBookmark = nil
        document = nil
        analysis = .empty()
        result = nil
        outputDirectory = nil
        lastError = nil
        isAnalyzing = false
        visualArtworkOverride = nil
        visualPlacement = nil
        resetSignatureTrees()
        sourceSignatureKind = .unsignedPDF
        signedOutputURL = nil
        signedPreviewDocument = nil
        pdfaPrepared = false
        pdfaAfterSign = false
        certificateLoadError = nil
        lastCertificateLoadPIN = nil
        selectedIdentityID = identity
        batchContainerName = ""
        batchContainerDefaultName = ""
    }

    func resolveOutputLocation() -> (directory: URL, stem: String) {
        let fallback = settingsStore.outputDirectory
        let originalName = sourceURL?.deletingPathExtension().lastPathComponent ?? "dokument"
        let stem = "\(originalName)_podpisane"
        if let scoped = resolvedSourceURL() {
            let directory = scoped.deletingLastPathComponent()
            if FileManager.default.isWritableFile(atPath: directory.path) {
                return (directory, stem)
            }
        }
        return (fallback, stem)
    }

    private func resolvedSourceURL() -> URL? {
        if let bookmark = sourceBookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark,
                                  options: [.withSecurityScope],
                                  relativeTo: nil,
                                  bookmarkDataIsStale: &stale) {
                _ = url.startAccessingSecurityScopedResource()
                return url
            }
        }
        return sourceURL
    }
}

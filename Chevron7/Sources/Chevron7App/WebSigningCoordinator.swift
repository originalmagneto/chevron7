// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
import AppKit
import PDFKit
import Chevron7Identity
import Chevron7Kit
import Chevron7WebBridge
import Observation
import os

/// Drives one signing request that arrived from a state portal through the
/// browser extension.
///
/// A page may not sign silently, so every request raises the app and waits for
/// the person to pick a certificate and enter the PIN. Requests are handled one
/// at a time: a second one while the first is open is refused rather than
/// queued, which keeps it obvious which document a PIN belongs to.
@Observable
@MainActor
final class WebSigningCoordinator {
    struct Pending: Identifiable {
        let id: String
        let request: WebSignRequest
        let sizeDescription: String
        let kindDescription: String
        let pdfThumbnail: NSImage?
        /// The whole PDF, for the page preview and Quick Look.
        let pdfDocument: PDFDocument?
        let xmlExcerpt: String?
        /// The other documents of the same signature, in the portal's order.
        let attachments: [Attachment]
    }

    /// A further data object of the signature, listed in the panel so nothing is
    /// signed unseen.
    struct Attachment: Identifiable {
        let id: Int
        let filename: String
        let kindDescription: String
        let sizeDescription: String
        let data: Data
    }

    enum Failure: LocalizedError {
        case busy
        case cancelled
        case tooLarge(Int)
        case malformedPayload
        case identityUnavailable

        var errorDescription: String? {
            switch self {
            case .busy:
                return "Chevron7 už spracúva inú požiadavku na podpis."
            case .cancelled:
                return WebSigningBridge.cancelledMessage
            case .tooLarge(let bytes):
                let megabytes = Double(bytes) / 1_048_576
                return String(format: "Dokument má %.1f MB, čo je nad limitom pre podpis z prehliadača.", megabytes)
            case .malformedPayload:
                return "Obsah dokumentu sa nepodarilo prečítať."
            case .identityUnavailable:
                return "Nie je vybraný certifikát na podpisovanie."
            }
        }
    }

    private(set) var pending: Pending?
    var pin: String = ""
    var selectedIdentityID: String?
    var identities: [SigningIdentityInfo] = []
    private(set) var isWorking = false
    private(set) var errorText: String?
    /// True while certificates are read from the card, which for an eID means
    /// the eID client's BOK window is open.
    private(set) var isReadingCertificates = false
    /// Bumped whenever the PIN field should take the keyboard.
    private(set) var pinFocusRequest = 0
    private var cardPresent = false
    private var cardWatch: Task<Void, Never>?

    /// An eID takes its BOK in the eID client's own window; every other card
    /// needs the PIN typed here.
    var selectedIdentityRequiresPIN: Bool {
        !(identities.first(where: { $0.id == selectedIdentityID })?.usesProtectedAuthenticationPath ?? false)
    }

    /// Whether the certificates were already read from the card, rather than the
    /// placeholder that only says a card is connected.
    var certificatesResolved: Bool {
        identities.contains { $0.id.hasPrefix(EngineBridgeSigningProvider.certificateIdentityPrefix) }
    }

    private let log = Logger(subsystem: ProductIdentity.bundleIdentifier, category: "web-signing")

    /// Portals ask for Baseline B, which carries no timestamp, and the phone
    /// then offers only the handwritten-equivalent signature. Turning this on
    /// upgrades to Baseline T and adds a qualified timestamp.
    ///
    /// Off for every new request and never remembered: nove.slovensko.sk
    /// rejects a signature with a timestamp it did not ask for (detach 500,
    /// Asic join 422), and a switch left on from an earlier request broke every
    /// card signature there until it was noticed.
    var addsQualifiedTimestamp = false

    /// The level actually used, after the timestamp preference is applied.
    private func effectiveLevel(for request: WebSignRequest) -> String {
        guard addsQualifiedTimestamp, request.allowsAddedTimestamp, request.signatureLevel.hasSuffix("_B") else {
            return request.signatureLevel
        }
        // Only the trailing marker, never the "_B" inside "_BASELINE".
        return request.signatureLevel.dropLast(2) + "_T"
    }

    /// True when the switch adds a timestamp the page did not ask for.
    var addsUnrequestedTimestamp: Bool {
        addsQualifiedTimestamp && (pending?.request.signatureLevel.hasSuffix("_B") ?? false)
    }

    /// False on slovensko.sk, which accepts only the level it asked for.
    var timestampSwitchAvailable: Bool {
        pending?.request.allowsAddedTimestamp ?? true
    }

    /// Shown in the sheet so the consequence of the toggle is visible before signing.
    var effectiveLevelDescription: String {
        guard let pending else { return "" }
        return effectiveLevel(for: pending.request).replacingOccurrences(of: "_", with: " ")
    }

    /// The open request and its token: a signature that finishes after its request
    /// was cancelled must not answer the page's next request.
    private let session = WebSignSessionGate<WebSignResponse>()
    private let settingsStore: AppSettingsStore
    private let signedDocumentStore: SignedDocumentStore
    private let prompt = WebSigningPrompt()
    let mobileSigning: MobileSigningCoordinator

    init(settingsStore: AppSettingsStore, signedDocumentStore: SignedDocumentStore) {
        self.settingsStore = settingsStore
        self.signedDocumentStore = signedDocumentStore
        self.mobileSigning = MobileSigningCoordinator(settingsStore: settingsStore)
    }

    /// Keeps a copy of what was signed and lists it among recent documents.
    ///
    /// The page gets its own copy over the bridge, so without this the signature
    /// would leave no trace on the Mac at all: nothing to re-check later, and
    /// nothing in the sidebar.
    @discardableResult
    private func archive(_ data: Data, for request: WebSignRequest) -> URL? {
        guard settingsStore.settings.webSigningSavesLocally else { return nil }
        let configured = settingsStore.settings.webSigningOutputPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let directory = configured.isEmpty
            ? settingsStore.outputDirectory
            : URL(fileURLWithPath: (configured as NSString).expandingTildeInPath, isDirectory: true)
        let base = (request.filename as NSString).deletingPathExtension
        let stem = (base.isEmpty ? "dokument" : base) + "_podpisane"
        let ext = Self.archiveExtension(for: request)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var url = directory.appendingPathComponent(stem).appendingPathExtension(ext)
            if FileManager.default.fileExists(atPath: url.path) {
                let stamp = Self.fileStampFormatter.string(from: Date())
                url = directory.appendingPathComponent("\(stem)-\(stamp)").appendingPathExtension(ext)
            }
            try data.write(to: url, options: [.atomic])
            return url
        } catch {
            // A failed archive must not fail the signature: the page already has
            // a valid signed document either way.
            log.error("Web signature archive failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    private static let fileStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    var mobileSigningAvailable: Bool {
        guard settingsStore.settings.mobileSigningEnabled else { return false }
        return pending.map({ Self.mobileRefusal(for: $0.request) == nil }) ?? true
    }

    /// The Autogram Portal is set up for eIDENTITA: an organization id and a key in
    /// the Keychain. Read once per request, so the panel never touches the Keychain
    /// while it redraws.
    private(set) var eidentitaConfigured = false

    /// eIDENTITA is offered next to Autogram v mobile only when the portal is set
    /// up and the request is one it signs.
    var eidentitaAvailable: Bool {
        guard eidentitaConfigured, mobileSigningAvailable, let pending else { return false }
        return Self.eidentitaRefusal(for: pending.request) == nil
    }

    private let agpKeyStore: any AGPKeyStoring = AGPKeyStore()

    private func readEidentitaConfiguration() -> Bool {
        let organization = settingsStore.settings.agpUserID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard settingsStore.settings.mobileSigningEnabled, !organization.isEmpty else { return false }
        return ((try? agpKeyStore.loadPrivateKey()) ?? nil) != nil
    }

    /// Why eIDENTITA cannot sign this request, nil when it can. On top of what the
    /// phone refuses anyway, eIDENTITA signs no electronic forms yet: the MV SR
    /// integration guide (v1.1, 2026-03-05) lists XML forms as planned only.
    nonisolated static func eidentitaRefusal(for request: WebSignRequest) -> String? {
        if let refusal = mobileRefusal(for: request) { return refusal }
        if request.eform != nil || request.payloadMimeType.lowercased().contains("xml") {
            return "Elektronický formulár aplikácia eIDENTITA zatiaľ nepodpisuje. Použite Autogram v mobile alebo kartu."
        }
        return nil
    }

    /// Why the phone cannot sign this request, nil when it can. The relay has only
    /// been shown PDFs and form XML: TXT/PNG, a finished container and several
    /// documents stay with the card until avm-probe verifies the relay takes them.
    nonisolated static func mobileRefusal(for request: WebSignRequest) -> String? {
        if plainFileExtension(for: request) != nil {
            return "Podpis textu a obrázkov mobilom zatiaľ nie je k dispozícii. Použite podpis kartou."
        }
        if request.isXMLDataContainer {
            return "Hotový formulár (XML Data Container) sa mobilom zatiaľ nepodpisuje. Použite podpis kartou."
        }
        if request.attachments?.isEmpty == false {
            return "Viac dokumentov naraz sa mobilom zatiaľ nepodpisuje. Použite podpis kartou."
        }
        return nil
    }

    private var provider: any QualifiedSigningProviding { settingsStore.signingProvider }

    /// Called from the XPC bridge. Suspends until the person signs or cancels.
    func handle(_ request: WebSignRequest) async throws -> WebSignResponse {
        // isWorking too: after a cancel the engine may still be signing the old
        // request, and it holds the card until it ends.
        guard pending == nil, !isWorking, !session.isOpen else { throw Failure.busy }

        let bytes = try Self.decode(request)
        let attachmentEntries = try Self.attachmentEntries(for: request)
        // Several documents are plain files next to a PDF; ditec.js never sends an
        // eForm with them, and the provider would ignore the attachments if it did.
        guard attachmentEntries.isEmpty || request.eform == nil else { throw Failure.malformedPayload }
        let totalBytes = attachmentEntries.reduce(bytes.count) { $0 + $1.data.count }
        guard totalBytes <= WebSigningBridge.maximumPayloadBytes else {
            throw Failure.tooLarge(totalBytes)
        }

        var pdfThumb: NSImage?
        var pdfDocument: PDFDocument?
        var xmlPreview: String?
        let plainExtension = Self.plainFileExtension(for: request)
        if request.eform != nil || request.payloadMimeType.contains("xml") {
            if let string = String(data: bytes.prefix(8192), encoding: .utf8) {
                let lines = string.components(separatedBy: .newlines).prefix(10)
                xmlPreview = lines.joined(separator: "\n")
            }
        } else if plainExtension == "txt", let string = String(data: bytes, encoding: .utf8) {
            let lines = string.components(separatedBy: .newlines).prefix(10)
            xmlPreview = lines.joined(separator: "\n")
        } else if plainExtension == "png", let image = NSImage(data: bytes) {
            pdfThumb = image
        } else if let doc = PDFDocument(data: bytes), let page = doc.page(at: 0) {
            pdfThumb = page.thumbnail(of: CGSize(width: 140, height: 180), for: .mediaBox)
            pdfDocument = doc
        }

        pending = Pending(id: request.requestID,
                          request: request,
                          sizeDescription: Self.describeSize(bytes.count),
                          kindDescription: Self.describeKind(request),
                          pdfThumbnail: pdfThumb,
                          pdfDocument: pdfDocument,
                          xmlExcerpt: xmlPreview,
                          attachments: zip(attachmentEntries, request.attachments ?? []).enumerated().map { index, pair in
                              Attachment(id: index,
                                         filename: pair.0.path,
                                         kindDescription: Self.describeKind(filename: pair.0.path,
                                                                            mimeType: pair.1.payloadMimeType),
                                         sizeDescription: Self.describeSize(pair.0.data.count),
                                         data: pair.0.data)
                          })
        pin = ""
        errorText = nil
        addsQualifiedTimestamp = false
        eidentitaConfigured = readEidentitaConfiguration()
        prompt.show(coordinator: self)
        startCardWatch()

        return try await withCheckedThrowingContinuation { continuation in
            if session.open(continuation) == nil {
                continuation.resume(throwing: Failure.busy)
            }
        }
    }

    /// Polls for the card while the prompt is open, so inserting one needs no
    /// button: an eID opens the BOK window at once, other cards focus the PIN.
    private func startCardWatch() {
        cardWatch?.cancel()
        cardPresent = false
        identities = []
        selectedIdentityID = nil
        cardWatch = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshIdentities()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func refreshIdentities() async {
        guard pending != nil, !isWorking, !isReadingCertificates else { return }
        let discovered = await provider.availableIdentities()
        guard pending != nil, !isWorking, !isReadingCertificates else { return }
        let wasPresent = cardPresent
        cardPresent = !discovered.isEmpty
        guard cardPresent else {
            if wasPresent {
                pin = ""
                errorText = nil
            }
            identities = []
            selectedIdentityID = nil
            return
        }
        identities = discovered
        if selectedIdentityID == nil || !discovered.contains(where: { $0.id == selectedIdentityID }) {
            selectedIdentityID = Self.preferredIdentity(in: discovered)
        }
        // An eID signs without reading its certificates first: every read opens the
        // eID client's BOK window, and the engine picks the card's signing key itself.
        // Other cards need the PIN typed here, so the keyboard goes to the PIN field.
        if !wasPresent && selectedIdentityRequiresPIN {
            await readCertificates()
        }
    }

    /// Reads the certificates from the connected card. An eID asks for the BOK in
    /// the eID client's window; any other card needs the PIN first, so without one
    /// this only moves the keyboard to the PIN field.
    func readCertificates() async {
        guard pending != nil, cardPresent, !isWorking, !isReadingCertificates else { return }
        let needsPIN = selectedIdentityRequiresPIN
        guard !needsPIN || !pin.isEmpty else {
            requestPINFocus()
            return
        }
        let token = session.currentToken
        isReadingCertificates = true
        errorText = nil
        if !needsPIN { prompt.beginMiddlewareInput() }
        let resolved = await provider.resolveIdentities(pin: needsPIN ? pin : "")
        if !needsPIN { prompt.endMiddlewareInput() }
        isReadingCertificates = false
        guard session.isCurrent(token) else { return }

        if let resolved, !resolved.isEmpty {
            identities = resolved
            selectedIdentityID = Self.preferredIdentity(in: resolved)
        } else {
            errorText = (provider as? EngineBridgeSigningProvider)?.lastResolveError
                ?? "Certifikáty z karty sa nepodarilo načítať."
            if needsPIN { requestPINFocus() }
        }
    }

    /// Return in the PIN field reads the certificates first and signs once they are known.
    func submitPIN() async {
        if certificatesResolved {
            await confirm()
        } else {
            await readCertificates()
        }
    }

    private func requestPINFocus() {
        pinFocusRequest += 1
        prompt.focus()
    }

    private static func preferredIdentity(in identities: [SigningIdentityInfo]) -> String? {
        (identities.first(where: \.isQualified) ?? identities.first)?.id
    }

    func cancel() {
        // A phone signature in progress would otherwise keep the panel's slot
        // busy until the relay times out; the card's engine call cannot be
        // stopped, and its late result is dropped by the session token.
        mobileSigning.cancel()
        mobileSigning.cancelEidentita()
        finish(.failure(Failure.cancelled), token: session.currentToken)
    }

    /// Signs with the eID over NFC on a phone, through the Autogram v mobile relay
    /// or through eIDENTITA on the Autogram Portal. Needs no card reader and no PIN
    /// here: the phone collects both. The relay accepts the same eForm attributes as
    /// the local engine, so a state-portal form works there; eIDENTITA signs PDFs.
    func confirmViaMobile(method: MobileSigningMethod = .autogramMobile) async {
        guard let pending else { return }
        let refusal = method == .eidentita
            ? Self.eidentitaRefusal(for: pending.request)
            : Self.mobileRefusal(for: pending.request)
        if let refusal {
            errorText = refusal
            return
        }
        let token = session.currentToken
        isWorking = true
        errorText = nil
        defer { isWorking = false }

        do {
            let bytes = try Self.decode(pending.request)
            let isEForm = pending.request.eform != nil
            let wantsContainer = pending.request.wantsASiCContainer
            let requested = effectiveLevel(for: pending.request)
            let wantsTimestamp = requested.hasSuffix("_T")
            // The relay rejects a XAdES level on a PDF without a container, so
            // level and container are decided together.
            let level: AVMSignatureLevel = wantsContainer
                ? (wantsTimestamp ? .xadesT : .xadesB)
                : (wantsTimestamp ? .padesT : .padesB)

            let content: Data
            let signedBy: String
            let issuedBy: String
            switch method {
            case .autogramMobile:
                let upload = AVMUploadRequest(
                    filename: pending.request.filename,
                    data: bytes,
                    mimeType: isEForm ? AVMUploadRequest.xmlMimeType : AVMUploadRequest.pdfMimeType,
                    level: level,
                    container: wantsContainer ? .asicE : nil,
                    eform: pending.request.eform)
                let document = try await mobileSigning.sign(upload)
                // Cancelled while the phone signed: this result belongs to no one.
                guard session.isCurrent(token) else { return }
                guard let data = document.data else {
                    throw Failure.malformedPayload
                }
                let signers = document.signers ?? []
                content = data
                signedBy = AVMResultMapper.signatureLabel(signers: signers)
                issuedBy = signers.first?.issuedBy ?? ""
            case .eidentita:
                // The portal builds the container around the PDF for a XAdES request,
                // as the relay does; Baseline B is eIDENTITA's signature without a timestamp.
                let request = AGPSigningRequest(filename: pending.request.filename,
                                                data: bytes,
                                                mimeType: AVMUploadRequest.pdfMimeType,
                                                format: wantsContainer ? .xades : .pades,
                                                level: wantsTimestamp ? .baselineT : .baselineB)
                let client = try AGPClient.configured(userID: settingsStore.settings.agpUserID,
                                                      baseURL: settingsStore.settings.agpBaseURLValue,
                                                      keyStore: agpKeyStore)
                let file = try await mobileSigning.signViaEidentita(request, client: client)
                guard session.isCurrent(token) else { return }
                content = file.data
                signedBy = SigningSessionStore.eidentitaSignatureLabel
                // The portal returns the file only; the issuer would need the
                // certificate, which an eID signature on this path never reads here.
                issuedBy = ""
            }
            let saved = archive(content, for: pending.request)
            signedDocumentStore.record(displayName: pending.request.filename,
                                       origin: .browser,
                                       method: .mobile,
                                       signatureLevel: requested,
                                       signedBy: signedBy,
                                       url: saved)
            signedDocumentStore.purgeBrowserCopies(olderThanDays: settingsStore.settings.webSigningRetentionDays)
            finish(.success(WebSignResponse(
                requestID: pending.request.requestID,
                content: content.base64EncodedString(),
                signedBy: signedBy,
                issuedBy: issuedBy)), token: token)
        } catch is CancellationError {
            guard session.isCurrent(token) else { return }
            errorText = "Podpisovanie mobilom ste zrušili."
        } catch {
            guard session.isCurrent(token) else { return }
            errorText = error.localizedDescription
        }
    }

    func confirm() async {
        guard let pending, let identityID = selectedIdentityID else {
            errorText = Failure.identityUnavailable.errorDescription
            return
        }
        let needsPIN = selectedIdentityRequiresPIN
        guard !needsPIN || !pin.isEmpty else {
            errorText = "Zadajte PIN karty."
            requestPINFocus()
            return
        }
        let token = session.currentToken
        isWorking = true
        errorText = nil
        defer { isWorking = false }

        do {
            let bytes = try Self.decode(pending.request)
            let attachments = try Self.attachmentEntries(for: pending.request)
            let level = effectiveLevel(for: pending.request)
            let wantsTimestamp = level.hasSuffix("_T")
            let wantsContainer = pending.request.wantsASiCContainer
            guard Self.plainFileExtension(for: pending.request) == nil || wantsContainer else {
                errorText = "Text a obrázky sa podpisujú len do ASiC-E kontajnera."
                return
            }
            // The PDF goes to the engine as it is: XAdES on a PDF makes the engine
            // build the ASiC-E around it. A container packaged here first ended up
            // nested inside the signed one, which the portal could neither open nor join.
            // Further documents become data objects of that same container.
            let signingRequest = SigningRequest(
                pdfData: bytes,
                identityID: identityID,
                includeTimestamp: wantsTimestamp,
                tsaURL: wantsTimestamp ? settingsStore.settings.activeTSA.url : nil,
                outputFormat: wantsContainer ? .attachedASIC : .embeddedPAdES,
                pin: pin.isEmpty ? nil : pin,
                extraFiles: attachments,
                eform: pending.request.eform,
                signatureLevelOverride: level,
                filename: pending.request.filename,
                signsExtraFilesAsDataObjects: !attachments.isEmpty)

            // An eID opens the eID client's BOK window for the signature itself.
            if !needsPIN { prompt.beginMiddlewareInput() }
            let signed: SignedConversionResult
            do {
                signed = try await provider.sign(signingRequest)
                if !needsPIN { prompt.endMiddlewareInput() }
            } catch {
                if !needsPIN { prompt.endMiddlewareInput() }
                throw error
            }
            // Cancelled while the card signed: neither archived nor handed to the
            // page's next request.
            guard session.isCurrent(token) else { return }
            let payload = wantsContainer ? (signed.asicData ?? signed.pdfData) : signed.pdfData
            let saved = archive(payload, for: pending.request)
            signedDocumentStore.record(displayName: pending.request.filename,
                                       origin: .browser,
                                       method: .card,
                                       signatureLevel: level,
                                       signedBy: signed.signatureLabel,
                                       url: saved)
            signedDocumentStore.purgeBrowserCopies(olderThanDays: settingsStore.settings.webSigningRetentionDays)
            finish(.success(WebSignResponse(
                requestID: pending.request.requestID,
                content: payload.base64EncodedString(),
                signedBy: signed.signatureLabel,
                issuedBy: signed.issuerName(fallback: identities.first(where: { $0.id == identityID })))), token: token)
        } catch {
            guard session.isCurrent(token) else { return }
            // Kept open so a mistyped PIN can be corrected without the page
            // having to start over.
            errorText = error.localizedDescription
            if needsPIN { requestPINFocus() }
        }
    }

    private func finish(_ result: Result<WebSignResponse, Error>, token: UUID?) {
        guard session.isCurrent(token) else { return }
        cardWatch?.cancel()
        cardWatch = nil
        cardPresent = false
        pending = nil
        pin = ""
        prompt.hide()
        session.close(token, with: result)
    }

    private static func decode(_ request: WebSignRequest) throws -> Data {
        guard let data = Data(base64Encoded: request.content) ?? request.content.data(using: .utf8) else {
            throw Failure.malformedPayload
        }
        return data
    }

    private static func describeSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }

    nonisolated static func describeKind(_ request: WebSignRequest) -> String {
        if request.isXMLDataContainer { return "Hotový formulár (XML Data Container)" }
        if request.eform != nil { return "Elektronický formulár (XML Data Container)" }
        return describeKind(filename: request.filename, mimeType: request.payloadMimeType)
    }

    nonisolated static func describeKind(filename: String, mimeType: String) -> String {
        let mime = mimeType.replacingOccurrences(of: " ", with: "").lowercased()
        let ext = (filename as NSString).pathExtension.lowercased()
        if ext == "xdcf" || mime.hasPrefix("application/vnd.gov.sk.xmldatacontainer+xml") {
            return "Hotový formulár (XML Data Container)"
        }
        if ext == "txt" || mime.hasPrefix("text/plain") { return "Textový dokument (TXT)" }
        if ext == "png" || mime.hasPrefix("image/png") { return "Obrázok (PNG)" }
        if mime.contains("pdf") { return "Dokument PDF" }
        return mimeType
    }

    /// The further documents as data objects for the engine, in the portal's order.
    ///
    /// The provider writes them into one folder beside the PDF, on a volume that
    /// ignores case, and skips one named like the PDF, so every name is reduced to
    /// a plain file name and made unique against the PDF and the others; a clash
    /// would otherwise drop a document from the signature without a word. Names
    /// compare as the engine's request validator does (NFC, lowercase), and the
    /// container's own entry names count as taken.
    nonisolated static func attachmentEntries(for request: WebSignRequest) throws -> [ASiCEPackager.Entry] {
        guard let attachments = request.attachments, !attachments.isEmpty else { return [] }
        func key(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.lowercased() }
        var taken: Set<String> = ["mimetype", "meta-inf", key((request.filename as NSString).lastPathComponent)]
        return try attachments.map { attachment in
            guard let data = Data(base64Encoded: attachment.content) else { throw Failure.malformedPayload }
            var name = ASiCEPackager.sanitizedFileName((attachment.filename as NSString).lastPathComponent)
            if name.isEmpty { name = "priloha" }
            let stem = (name as NSString).deletingPathExtension
            let ext = (name as NSString).pathExtension
            var candidate = name
            var counter = 2
            while taken.contains(key(candidate)) {
                candidate = ext.isEmpty ? "\(stem)-\(counter)" : "\(stem)-\(counter).\(ext)"
                counter += 1
            }
            taken.insert(key(candidate))
            return ASiCEPackager.Entry(path: candidate, data: data)
        }
    }

    /// Extension the browser payload really is when it is plain text or an
    /// image, nil for PDF and eForms. ditec.js guarantees the filename carries
    /// it; the engine and the archive read the type from the name, never from
    /// `eform != nil`.
    nonisolated static func plainFileExtension(for request: WebSignRequest) -> String? {
        let fromName = (request.filename as NSString).pathExtension.lowercased()
        if fromName == "txt" || fromName == "png" { return fromName }
        let mime = request.payloadMimeType.replacingOccurrences(of: " ", with: "").lowercased()
        if mime.hasPrefix("text/plain") { return "txt" }
        if mime.hasPrefix("image/png") { return "png" }
        return nil
    }

    nonisolated static func archiveExtension(for request: WebSignRequest) -> String {
        if request.wantsASiCContainer { return "asice" }
        return plainFileExtension(for: request) ?? "pdf"
    }
}

// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Chevron7Identity
import Foundation
import PDFKit
@preconcurrency import AppKit
import os

/// Kvalifikované podpisovanie cez overený Java/DSS engine z Autogram macOS 2
/// (AutogramCLI-arm64 helper + machine protokol V1/V2) – port produkčnej cesty.
public final class EngineBridgeSigningProvider: QualifiedSigningProviding, @unchecked Sendable {
    public static let driverID = "eid"
    public static let syntheticIdentityIDPrefix = "engine:"
    public static let certificateIdentityPrefix = "engine-cert:"
    /// Sent to the engine for an eID when the app collected no BOK. eID tokens
    /// report CKF_PROTECTED_AUTHENTICATION_PATH, so SunPKCS11 logs in with a null
    /// PIN and the eID client asks for the BOK in its own window; this value
    /// never reaches the card. The engine only insists on a non-blank field.
    public static let protectedAuthenticationPathPIN = "protected-authentication-path"

    // `any SigningEngine` (not the concrete `AutogramCLIEngine`) so tests can
    // substitute a fake engine that captures the `EngineSigningRequest`.
    private let engine: any SigningEngine
    private let renderer: VisibleSignatureRenderer
    /// Upper bound for full signature validation (trusted lists can hang on a bad network).
    private let validationTimeout: Duration
    private let cachedCertificates = OSAllocatedUnfairLock<[SigningCertificate]>(initialState: [])
    /// Driver the cached certificates were read from, so signing can reuse them
    /// instead of asking the eID client for the BOK a second time.
    private let cachedCertificatesDriverID = OSAllocatedUnfairLock<String?>(initialState: nil)
    private let identityCache = OSAllocatedUnfairLock<(fingerprint: String, identities: [SigningIdentityInfo], fetchedAt: Date)?>(
        initialState: nil)
    private let identityCacheTTL: TimeInterval = 6
    private let driverProbeCache = OSAllocatedUnfairLock<(fingerprint: String, names: [String], at: Date)?>(initialState: nil)
    private let lastResolveErrorLock = OSAllocatedUnfairLock<String?>(initialState: nil)
    private let logger = Logger(subsystem: ProductIdentity.bundleIdentifier, category: "EngineBridge")

    init(engine: any SigningEngine = AutogramCLIEngine(),
         renderer: VisibleSignatureRenderer = VisibleSignatureRenderer(),
         validationTimeout: Duration = .seconds(90)) {
        self.engine = engine
        self.renderer = renderer
        self.validationTimeout = validationTimeout
    }

    // MARK: - QualifiedSigningProviding

    public func availableIdentities() async -> [SigningIdentityInfo] {
        let probe = await connectedDriversFingerprint()
        let fingerprint = probe?.fingerprint ?? ""
        if fingerprint.isEmpty {
            cachedCertificates.withLock { $0 = [] }
            cachedCertificatesDriverID.withLock { $0 = nil }
            identityCache.withLock { $0 = nil }
            return []
        }
        if let cached = identityCache.withLock({ $0 }),
           cached.fingerprint == fingerprint,
           Date().timeIntervalSince(cached.fetchedAt) < identityCacheTTL {
            return cached.identities
        }
        let identities = await computeIdentities(fingerprint: fingerprint, driverNames: probe?.names ?? [])
        identityCache.withLock { $0 = (fingerprint, identities, Date()) }
        return identities
    }

    /// Načíta certifikáty pred vykreslením grafického podpisu.
    public func resolveIdentities(pin: String) async -> [SigningIdentityInfo]? {
        do {
            let drivers = try await engine.drivers()
            let present = drivers.filter { $0.tokenPresent == true }
            let usable = present.isEmpty ? drivers.filter { $0.tokenPresent != false } : present
            guard let driverID = (usable.first(where: { $0.id == Self.driverID }) ?? usable.first)?.id else {
                lastResolveErrorLock.withLock { $0 = "Karta nie je dostupná — vložte ju do čítačky." }
                return []
            }
            // eID má chránenú autentizačnú cestu — BOK si vypýta eID klient vo vlastnom okne.
            // Komerčné karty (I.CA SecureStore a pod.) vyžadujú programovo zadaný PIN.
            guard let enginePIN = Self.enginePIN(entered: pin, driverID: driverID) else {
                lastResolveErrorLock.withLock { $0 = "Pre túto kartu zadajte PIN." }
                return nil
            }
            let discovery = try await engine.certificateDiscovery(driverID: driverID, pin: Secret(enginePIN))
            guard !discovery.certificates.isEmpty else {
                lastResolveErrorLock.withLock { $0 = "Na karte neboli nájdené podpisové certifikáty." }
                return []
            }
            cachedCertificates.withLock { $0 = discovery.certificates }
            cachedCertificatesDriverID.withLock { $0 = driverID }
            invalidateIdentityCache()
            lastResolveErrorLock.withLock { $0 = nil }
            return discovery.certificates.map { Self.identityInfo(from: $0, driverID: driverID) }
        } catch {
            let message = error.localizedDescription
            let friendly: String
            if message.contains("PIN_INVALID") {
                friendly = "PIN má neplatný formát pre túto kartu — skontrolujte jeho dĺžku a počet číslic."
            } else if message.contains("PIN_INCORRECT") {
                friendly = "Nesprávny PIN — overte ho a skúste znova."
            } else if message.contains("PIN_LOCKED") {
                friendly = "PIN karty je zablokovaný — odomknite ju PUK kódom cez nástroj výrobcu karty."
            } else if message.contains("TOKEN_NOT_PRESENT") {
                friendly = "V čítačke nie je karta: vložte ju, počkajte na kontrolku čítačky a skúste znova."
            } else if message.contains("TOKEN_NOT_RECOGNIZED") {
                friendly = "Karta v čítačke nezodpovedá zvolenému ovládaču: prepnite eID klient alebo I.CA SecureStore."
            } else if message.contains("OPERATION_CANCELLED") {
                friendly = "Operácia s kartou bola zrušená."
            } else if message.contains("DRIVER_UNAVAILABLE") || message.contains("DRIVER_NOT_FOUND") {
                friendly = "Karta nie je dostupná — vložte ju do čítačky."
            } else {
                friendly = "Načítanie certifikátu zlyhalo: \(message)"
            }
            lastResolveErrorLock.withLock { $0 = friendly }
            logger.info("Certificate discovery failed: \(message, privacy: .public)")
            return nil
        }
    }

    public var lastResolveError: String? {
        lastResolveErrorLock.withLock { $0 }
    }

    public func invalidateIdentityCache() {
        identityCache.withLock { $0 = nil }
    }

    /// An `.asice` source reaches the engine under its own name, and the machine
    /// service extends it (`SigningParameters.buildForExistingASiC`).
    public var addsSignatureToExistingContainer: Bool { true }

    public func inspectInputSignatures(in fileURL: URL) async -> InputSignatureInspectionResult {
        let canonical = EnginePaths.canonical(fileURL)
        return await inspectInputSignatures(in: [canonical])[canonical]
            ?? .unavailable(detail: "Kontrola vstupného dokumentu nevrátila výsledok.")
    }

    public func inspectInputSignatures(in fileURLs: [URL]) async -> [URL: InputSignatureInspectionResult] {
        var canonicalURLs: [URL] = []
        var seenURLs = Set<URL>()
        for fileURL in fileURLs {
            let canonical = EnginePaths.canonical(fileURL)
            if seenURLs.insert(canonical).inserted {
                canonicalURLs.append(canonical)
            }
        }
        let validURLs = canonicalURLs.filter {
            FileManager.default.fileExists(atPath: $0.path)
        }
        var results = Dictionary(
            canonicalURLs.map { url in
                (url, InputSignatureInspectionResult.unavailable(
                    detail: "Vstupný dokument nie je dostupný."))
            },
            uniquingKeysWith: { first, _ in first })
        guard !validURLs.isEmpty else { return results }

        let descriptors = validURLs.enumerated().map { index, url in
            PDFItemDescriptor(id: "inspect-\(index)", sourceURL: url)
        }
        do {
            let inspections = try await engine.inspect(files: descriptors)
            let inspectedByID = Dictionary(
                inspections.flatMap(\.files).map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first })
            for (index, url) in validURLs.enumerated() {
                guard let inspected = inspectedByID["inspect-\(index)"] else {
                    results[url] = .unavailable(
                        detail: "Kontrola vstupného dokumentu nevrátila výsledok.")
                    continue
                }
                results[url] = Self.inputSignatureInspection(from: inspected)
            }
        } catch {
            logger.info("Input signature validation failed: \(error.localizedDescription, privacy: .public)")
            for url in validURLs {
                results[url] = .unavailable(detail: error.localizedDescription)
            }
        }
        return results
    }

    public func inspectSignatures(in fileURL: URL) async -> [DocumentSignatureInfo] {
        let canonical = EnginePaths.canonical(fileURL)
        return (await inspectInputSignatures(in: [canonical])[canonical])?.signatures ?? []
    }

    public func inspectSignatureTree(in fileURL: URL) async -> SignatureTreeResult {
        await signatureTree(in: fileURL) { [engine] files in try await engine.inspect(files: files) }
    }

    public func validateSignatureTree(in fileURL: URL) async -> SignatureTreeResult {
        await signatureTree(in: fileURL) { [engine, validationTimeout] files in
            try await Self.withTimeLimit(validationTimeout) { try await engine.validate(files: files) }
        }
    }

    private func signatureTree(
        in fileURL: URL,
        run: @Sendable ([PDFItemDescriptor]) async throws -> [PDFInspection]
    ) async -> SignatureTreeResult {
        let canonical = EnginePaths.canonical(fileURL)
        guard FileManager.default.fileExists(atPath: canonical.path) else {
            return .failed("Dokument nie je dostupný.")
        }
        do {
            let inspections = try await run([PDFItemDescriptor(id: "tree", sourceURL: canonical)])
            guard let inspected = inspections.flatMap(\.files).first(where: { $0.id == "tree" }),
                  inspected.isSignable else {
                return .failed("Engine nevrátil výsledok kontroly podpisov.")
            }
            return .tree(inspected.tree)
        } catch {
            logger.info("Signature tree failed: \(error.localizedDescription, privacy: .public)")
            return .failed(Self.treeFailureReason(error))
        }
    }

    /// Races `operation` against `limit`. The loser is cancelled, so a hung engine request
    /// is cancelled too (the machine session cancels a request on task cancellation).
    private static func withTimeLimit<T: Sendable>(
        _ limit: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw CLIProcessFailure.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CLIProcessFailure.timedOut }
            return first
        }
    }

    static func treeFailureReason(_ error: Error) -> String {
        if case CLIProcessFailure.timedOut = error {
            return "Overenie podpisov trvalo príliš dlho. Výsledok je len štrukturálny."
        }
        let text = "\(error) \(error.localizedDescription)"
        if text.contains("TRUSTED_LIST_UNAVAILABLE") {
            return "Dôveryhodné zoznamy nie sú dostupné. Výsledok je len štrukturálny."
        }
        if text.contains("VALIDATION_FAILED") {
            return "Overenie podpisov zlyhalo. Výsledok je len štrukturálny."
        }
        return error.localizedDescription
    }

    static func requireInspectableFile(in inspections: [PDFInspection]) throws -> InspectedPDF {
        guard let inspected = inspections
            .flatMap(\.files)
            .first(where: { $0.id.hasPrefix("inspect") }),
              inspected.isSignable else {
            throw SigningFailure.engine("Engine nevrátil dokončenú kontrolu vstupného dokumentu.")
        }
        return inspected
    }

    private static func inputSignatureInspection(
        from inspected: InspectedPDF) -> InputSignatureInspectionResult {
        .completed(signatures: inspected.signatures.map { signature in
            let state: DocumentSignatureInfo.State
            switch signature.validationState {
            case .valid: state = .valid
            case .invalid: state = .invalid
            case .indeterminate: state = .indeterminate
            }
            return DocumentSignatureInfo(
                id: signature.id,
                signerDisplayName: signature.signerDisplayName ?? "Neznámy podpisovateľ",
                format: signature.format,
                signingTime: signature.signingTime,
                hasQualifiedTimestamp: signature.hasQualifiedTimestamp,
                state: state,
                detail: signature.validationReason ?? signature.subIndication)
        })
    }

    /// Odtlaček pripojených driverov + ich ľudské názvy (pre synthetic identitu).
    private func connectedDriversFingerprint() async -> (fingerprint: String, names: [String])? {
        if let cached = driverProbeCache.withLock({ $0 }),
           Date().timeIntervalSince(cached.at) < 2.5 {
            return cached.fingerprint.isEmpty ? nil : (cached.fingerprint, cached.names)
        }
        do {
            let drivers = try await engine.drivers()
            let present = drivers.filter { $0.tokenPresent == true }
            let usable = present.isEmpty
                ? drivers.filter { $0.tokenPresent != false }
                : present
            let fingerprint = usable.map(\.id).sorted().joined(separator: ",")
            let names = usable.sorted { $0.id < $1.id }.map(\.displayName)
            driverProbeCache.withLock { $0 = (fingerprint, names, Date()) }
            return fingerprint.isEmpty ? nil : (fingerprint, names)
        } catch {
            logger.info("Driver detection failed: \(error.localizedDescription, privacy: .public)")
            if let cached = driverProbeCache.withLock({ $0 }), !cached.fingerprint.isEmpty {
                return (cached.fingerprint, cached.names)
            }
            return nil
        }
    }

    private func computeIdentities(fingerprint: String, driverNames: [String]) async -> [SigningIdentityInfo] {
        guard let primaryDriverID = Self.primaryDriverID(fingerprint: fingerprint) else { return [] }
        let cached = cachedCertificates.withLock { $0 }
        let cachedDriverID = cachedCertificatesDriverID.withLock { $0 }
        if !cached.isEmpty {
            return cached.map { Self.identityInfo(from: $0, driverID: cachedDriverID ?? primaryDriverID) }
        }
        return [Self.syntheticIdentity(driverNames: driverNames, driverID: primaryDriverID)]
    }

    /// The driver certificate discovery and signing pick when several cards are
    /// connected: the eID first, as `resolveIdentities` and `sign` do.
    static func primaryDriverID(fingerprint: String) -> String? {
        let ids = fingerprint.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        return ids.contains(driverID) ? driverID : ids.first
    }

    /// Name of the PDF handed to the engine. For an ASiC-E the engine keeps this
    /// name inside the container, where a portal looks for the original document,
    /// so the browser path's real filename is used; a PAdES output is unaffected.
    static func pdfSourceName(for request: SigningRequest) -> String {
        guard request.outputFormat != .embeddedPAdES,
              let filename = request.filename.map({ ($0 as NSString).lastPathComponent }),
              (filename as NSString).pathExtension.lowercased() == "pdf",
              filename.count > 4 else {
            return "document.pdf"
        }
        return filename
    }

    /// Real filename for a browser TXT/PNG payload, nil otherwise. Mirrors
    /// `pdfSourceName`: the engine sniffs the payload type from the extension,
    /// so under document.pdf it would misread the bytes.
    static func plainSourceName(for request: SigningRequest) -> String? {
        guard let filename = request.filename.map({ ($0 as NSString).lastPathComponent }),
              ["txt", "png"].contains((filename as NSString).pathExtension.lowercased()),
              filename.count > 4 else {
            return nil
        }
        return filename
    }

    /// Serial the engine reads as "the signing key on this token".
    static let signingKeyOnToken = "*"
    static let eidSignerLabel = "Občiansky preukaz (eID)"

    /// An eID with no certificate chosen yet and no visible stamp signs without a
    /// certificate discovery first: the visible stamp needs the signer's name, and a
    /// certificate the person picked keeps its serial.
    static func signsWithoutCertificateDiscovery(driverID: String, preferredSerial: String?,
                                                 hasVisualStamp: Bool) -> Bool {
        !requiresPIN(driverID: driverID) && preferredSerial == nil && !hasVisualStamp
    }

    /// Whether the app has to collect the PIN for a card on this driver.
    public static func requiresPIN(driverID: String) -> Bool {
        driverID != Self.driverID
    }

    /// The PIN handed to the engine, or nil when the card needs one and none was entered.
    static func enginePIN(entered: String, driverID: String) -> String? {
        if !entered.isEmpty { return entered }
        return requiresPIN(driverID: driverID) ? nil : protectedAuthenticationPathPIN
    }

    public func sign(_ request: SigningRequest) async throws -> SignedConversionResult {
        let drivers = (try? await engine.drivers()) ?? []
        let present = drivers.filter { $0.tokenPresent == true }
        let usable = present.isEmpty ? drivers.filter { $0.tokenPresent != false } : present
        let connectedDriver = usable.first(where: { $0.id == Self.driverID }) ?? usable.first
        guard let driverID = connectedDriver?.id else {
            cachedCertificates.withLock { $0 = [] }
            invalidateIdentityCache()
            throw SigningError.identityUnavailable
        }
        guard let pin = Self.enginePIN(entered: request.pin ?? "", driverID: driverID) else {
            throw SigningError.identityUnavailable
        }

        let preferredSerial = request.identityID.hasPrefix(Self.certificateIdentityPrefix)
            ? String(request.identityID.dropFirst(Self.certificateIdentityPrefix.count))
            : nil
        let signingSerial: String
        let signerName: String
        let signerQualification: String?
        if Self.signsWithoutCertificateDiscovery(driverID: driverID, preferredSerial: preferredSerial,
                                                 hasVisualStamp: request.visualStamp != nil) {
            // The eID signing slot holds one qualified key. Reading its certificates
            // first would open the eID client's BOK window once more, so the engine
            // picks that key itself inside the signing session.
            signingSerial = Self.signingKeyOnToken
            signerName = Self.eidSignerLabel
            signerQualification = nil
        } else {
            // eID PKCS#11: every C_Login opens the eID client's BOK window. When the
            // certificates were already read from this eID, reuse them so signing asks
            // for the BOK once more (the signature itself), not twice. Other cards take
            // the PIN programmatically, so re-reading them costs nothing and re-checks the PIN.
            let reusable: [SigningCertificate] = {
                guard !Self.requiresPIN(driverID: driverID), let preferredSerial,
                      cachedCertificatesDriverID.withLock({ $0 }) == driverID else { return [] }
                let cached = cachedCertificates.withLock { $0 }
                return cached.contains(where: { $0.serialNumber == preferredSerial }) ? cached : []
            }()
            let certificates: [SigningCertificate]
            if !reusable.isEmpty {
                certificates = reusable
            } else {
                statusLog("Čítam podpisové certifikáty z karty…")
                let discovery: CertificateDiscovery
                do {
                    discovery = try await engine.certificateDiscovery(driverID: driverID, pin: Secret(pin))
                } catch {
                    cachedCertificates.withLock { $0 = [] }
                    cachedCertificatesDriverID.withLock { $0 = nil }
                    invalidateIdentityCache()
                    throw Self.mapAny(error)
                }
                guard !discovery.certificates.isEmpty else {
                    cachedCertificates.withLock { $0 = [] }
                    cachedCertificatesDriverID.withLock { $0 = nil }
                    invalidateIdentityCache()
                    throw SigningError.identityUnavailable
                }
                cachedCertificates.withLock { $0 = discovery.certificates }
                cachedCertificatesDriverID.withLock { $0 = driverID }
                certificates = discovery.certificates
            }
            guard let certificate = Self.selectCertificate(from: certificates,
                                                           preferredSerialNumber: preferredSerial) else {
                throw SigningError.identityUnavailable
            }
            signingSerial = certificate.serialNumber
            signerName = certificate.displayName
            signerQualification = certificate.certificateQualification
        }

        let workDirectory = try Self.makeWorkspace()
        defer { try? FileManager.default.removeItem(at: workDirectory) }

        let wantsPAdES = request.outputFormat == .embeddedPAdES
        var sourceURL: URL
        var attachmentURLs: [URL] = []
        if request.eform != nil, request.signsAsRecordContainer {
            // A conversion record is a plain XML Data Container with no attachments
            // and no eForm attributes; the two never combine.
            throw SigningError.signingFailed("Záznam nemôže mať eForm atribúty.")
        } else if request.eform != nil {
            // The engine decides how to treat the payload from the file extension,
            // so an eForm has to arrive as XML rather than under a .pdf name.
            let name = request.filename.map { ($0 as NSString).lastPathComponent } ?? "form.xml"
            let extensionIsXML = ["xml", "xdcf"].contains((name as NSString).pathExtension.lowercased())
            sourceURL = workDirectory.appendingPathComponent(extensionIsXML ? name : "form.xml")
            try request.pdfData.write(to: sourceURL, options: [.atomic])
        } else if request.signsAsRecordContainer {
            // EZZK's GetConversionRecord expects the signed record's data object
            // under its own "<number>.record.xml.xdcf" name, so the record keeps
            // its filename verbatim instead of a generic document name.
            guard let name = request.filename.map({ ($0 as NSString).lastPathComponent }),
                  name.lowercased().hasSuffix(".xdcf") else {
                throw SigningError.signingFailed("Záznam musí mať príponu .xdcf.")
            }
            sourceURL = workDirectory.appendingPathComponent(name)
            try request.pdfData.write(to: sourceURL, options: [.atomic])
        } else if !wantsPAdES, request.signsExtraFilesAsDataObjects {
            // ZaKo: the PDF/A and the clause XDC go into the engine as separate data
            // objects of one ASiC-E instead of a pre-packaged kontajner.asice.
            let name = request.filename.map { ($0 as NSString).lastPathComponent } ?? Self.pdfSourceName(for: request)
            sourceURL = workDirectory.appendingPathComponent(name)
            try request.pdfData.write(to: sourceURL, options: [.atomic])
            for entry in request.extraFiles
            where entry.path != "mimetype" && !entry.path.hasPrefix("META-INF/") && entry.path != name {
                let url = workDirectory.appendingPathComponent(ASiCEPackager.sanitizedFileName(entry.path))
                try entry.data.write(to: url, options: [.atomic])
                attachmentURLs.append(EnginePaths.canonical(url))
            }
        } else if !wantsPAdES, !request.extraFiles.isEmpty {
            sourceURL = workDirectory.appendingPathComponent("kontajner.asice")
            try Self.packageContainer(entries: request.extraFiles)
                .write(to: sourceURL, options: [.atomic])
        } else if !wantsPAdES, let plainName = Self.plainSourceName(for: request) {
            // Browser TXT/PNG: the engine reads the payload type from the
            // extension, so they keep their real name instead of document.pdf.
            sourceURL = workDirectory.appendingPathComponent(plainName)
            try request.pdfData.write(to: sourceURL, options: [.atomic])
        } else if wantsPAdES, Self.plainSourceName(for: request) != nil {
            throw SigningError.signingFailed("Text a obrázky sa podpisujú len do ASiC-E kontajnera.")
        } else {
            sourceURL = workDirectory.appendingPathComponent(Self.pdfSourceName(for: request))
            try request.pdfData.write(to: sourceURL, options: [.atomic])
        }

        var appearanceRequest: VisibleSignatureRequest?
        if wantsPAdES, let stamp = request.visualStamp {
            statusLog("Renderujem grafický podpis…")
            appearanceRequest = try self.visibleAppearance(for: stamp,
                                                           certificateDisplayName: signerName,
                                                           qualification: signerQualification,
                                                           pdfData: request.pdfData,
                                                           directory: workDirectory)
        }

        let signingFile = SigningFile(id: "document",
                                      sourceURL: EnginePaths.canonical(sourceURL),
                                      visibleAppearance: appearanceRequest,
                                      attachmentURLs: attachmentURLs)
        let engineRequest = EngineSigningRequest(
            sessionID: UUID(),
            driverID: driverID,
            certificateSerial: signingSerial,
            pin: Secret(pin),
            files: [signingFile],
            outputFormat: wantsPAdES ? .pades : .asiceXAdES,
            eform: request.eform,
            signatureLevelOverride: request.signatureLevelOverride,
            timestampServersOverride: request.timestampServers)

        statusLog("Podpisujem kvalifikovaným podpisom (DSS)…")
        var outputURL: URL?
        do {
            for try await event in engine.sign(request: engineRequest) {
                switch event {
                case .activity(let phase):
                    statusLog("Engine: \(phase.label)")
                case .completed(_, let url):
                    outputURL = url
                case .failed(_, let failure):
                    throw failure
                case .started, .fileSigning:
                    continue
                case .cancelled:
                    throw CancellationError()
                }
            }
        } catch {
            throw Self.mapAny(error)
        }

        guard let outputURL, FileManager.default.fileExists(atPath: outputURL.path) else {
            throw SigningError.signingFailed("Engine nevrátil podpísaný súbor.")
        }
        let signedData: Data
        do {
            signedData = try Data(contentsOf: outputURL)
        } catch {
            throw SigningError.signingFailed("Podpísaný výstup sa nepodarilo prečítať.")
        }
        guard !signedData.isEmpty else {
            throw SigningError.signingFailed("Engine nevrátil podpísaný súbor.")
        }

        if wantsPAdES {
            if appearanceRequest != nil, !Self.hasVisibleSignatureField(in: signedData) {
                throw SigningError.signingFailed(
                    "Podpis je v PDF, ale grafické pole ostalo neviditeľné (Rect 0×0). Skúste bez PDF/A alebo Reset placement.")
            }
            return SignedConversionResult(pdfData: signedData,
                                          asicData: nil,
                                          signedAt: Date(),
                                          signatureLabel: signerName,
                                          isLegallyBinding: true)
        }
        return SignedConversionResult(pdfData: request.pdfData,
                                      asicData: signedData,
                                      signedAt: Date(),
                                      signatureLabel: signerName,
                                      isLegallyBinding: true)
    }

    // MARK: - Vizuálny podpis (port VisibleSignatureRenderer + PDFCoordinateConverter)

    func visibleAppearance(for stamp: VisualStampSpec,
                           certificateDisplayName: String?,
                           qualification: String?,
                           pdfData: Data,
                           directory: URL) throws -> VisibleSignatureRequest {
        guard let document = PDFDocument(data: pdfData),
              document.pageCount > 0 else {
            throw SigningError.signingFailed("PDF sa nepodarilo otvoriť pre vizuálny podpis.")
        }
        let pageIndex = min(max(stamp.pageIndex, 0), document.pageCount - 1)
        guard let page = document.page(at: pageIndex) else {
            throw SigningError.signingFailed("Strana vizuálneho podpisu neexistuje.")
        }
        let cropBox = page.bounds(for: .cropBox)
        guard cropBox.width > 0, cropBox.height > 0 else {
            throw SigningError.signingFailed("Neplatný rozmer strany pre vizuálny podpis.")
        }

        let pageRect: CGRect
        if let explicit = stamp.pdfPageRect, explicit.width > 1, explicit.height > 1,
           cropBox.intersects(explicit) {
            pageRect = explicit.intersection(cropBox)
        } else {
            let width = max(stamp.normalizedRect.width * cropBox.width, 120)
            let height = max(stamp.normalizedRect.height * cropBox.height, 60)
            let originX = stamp.normalizedRect.x * cropBox.width
            let originY = (1 - stamp.normalizedRect.y - stamp.normalizedRect.height) * cropBox.height
            pageRect = CGRect(x: originX, y: originY, width: width, height: height)
                .intersection(cropBox)
        }
        guard pageRect.width > 8, pageRect.height > 8 else {
            throw SigningError.signingFailed("Vizuálny podpis je mimo stranu dokumentu (po PDF/A sa zmenili rozmery). Reset placement a skúste znova.")
        }
        let placement = VisibleSignaturePlacement(pageIndex: pageIndex,
                                                  pageRect: pageRect,
                                                  rotationDegrees: stamp.rotationDegrees)

        let store = SignatureAssetStore(applicationSupportRoot: directory)
        let artworkName = "artwork-\(UUID().uuidString).png"
        let asset = SignatureAsset(id: UUID(), kind: .png, managedFilename: artworkName)
        do {
            try FileManager.default.createDirectory(at: store.assetsDirectory,
                                                    withIntermediateDirectories: true)
            let artworkPNG = stamp.imagePNG.flatMap { Self.pngDataOrTextFallback(fullName: stamp.fullName, timestamp: stamp.timestamp, provided: $0) }
                ?? Self.textArtworkPNG(fullName: stamp.fullName, timestamp: stamp.timestamp)
            try artworkPNG.write(to: store.fileURL(for: asset), options: [.atomic])
        } catch {
            throw SigningError.signingFailed("Grafiku podpisu sa nepodarilo pripraviť.")
        }

        let content = VisibleSignatureCardContent(
            signerName: certificateDisplayName ?? stamp.fullName,
            certificateName: stamp.certificateName ?? certificateDisplayName,
            certificateQualification: qualification ?? stamp.qualification ?? "Kvalifikovaný elektronický podpis",
            timestampAuthorityName: stamp.timestampAuthorityName)
        let signingTime = stamp.timestamp
        let renderedURL: URL
        do {
            // Keep the injected renderer's cache root; only the artwork store is per call.
            renderedURL = try VisibleSignatureRenderer(assetStore: store,
                                                       cacheRoot: renderer.cacheRoot,
                                                       fileManager: renderer.fileManager)
                .render(asset: asset,
                        content: content,
                        signingTime: signingTime,
                        rotationDegrees: placement.rotationDegrees)
        } catch {
            throw SigningError.signingFailed("Náhľad grafického podpisu sa nepodarilo vyrenderovať.")
        }

        let field = PDFCoordinateConverter().dssField(placement,
                                                      cropBox: cropBox,
                                                      pageRotation: Int(page.rotation))
        return VisibleSignatureRequest(renderedPNGURL: EnginePaths.canonical(renderedURL),
                                       page: field.page,
                                       originX: Double(field.originX),
                                       originY: Double(field.originY),
                                       width: Double(field.width),
                                       height: Double(field.height),
                                       signingTime: signingTime)
    }

    static func pngDataOrTextFallback(fullName: String, timestamp: Date, provided: Data) -> Data? {
        guard provided.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { return nil }
        _ = fullName; _ = timestamp
        return provided
    }

    /// Textová grafika (meno + dátum) keď používateľ nemá vložený obrázok.
    static func textArtworkPNG(fullName: String, timestamp: Date) -> Data {
        let size = NSSize(width: 364, height: 84)
        let image = NSImage(size: size)
        image.lockFocusFlipped(false)
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 30, weight: .semibold),
            .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1),
            .paragraphStyle: paragraph
        ]
        let name = NSAttributedString(string: fullName, attributes: attributes)
        let bounds = name.boundingRect(with: NSSize(width: size.width, height: size.height - 8),
                                       options: [.usesLineFragmentOrigin])
        name.draw(in: NSRect(x: 0,
                             y: (size.height - bounds.height) / 2,
                             width: size.width,
                             height: ceil(bounds.height)))
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return Data()
        }
        return png
    }

    // MARK: - Kontajner (ZaKo)

    static func packageContainer(entries: [ASiCEPackager.Entry]) throws -> Data {
        var merged: [String: ASiCEPackager.Entry] = [:]
        for entry in entries {
            merged[entry.path] = entry
        }
        if merged["mimetype"] == nil {
            merged["mimetype"] = ASiCEPackager.Entry(path: "mimetype",
                                                     data: Data(ASiCEPackager.asicMimeType.utf8),
                                                     storeUncompressed: true)
        }
        if merged["META-INF/manifest.xml"] == nil {
            let manifestEntries = merged.values
                .filter { $0.path != "mimetype" && !$0.path.hasPrefix("META-INF/") }
                .sorted { $0.path < $1.path }
                .map { (path: $0.path, mediaType: ASiCEPackager.mediaType(forPath: $0.path)) }
            merged["META-INF/manifest.xml"] = ASiCEPackager.Entry(
                path: "META-INF/manifest.xml",
                data: Data(ASiCEPackager.manifestXML(entries: manifestEntries).utf8))
        }
        return try ASiCEPackager().package(files: Array(merged.values))
    }

    // MARK: - Pomocné

    /// eID SR → QES (nie mandate). Mandátny certifikát je na advokátskom/notárskom
    /// preukaze (I.CA SecureStore a pod.) – detekcia podľa vydávateľa/držiteľa.
    static func isCommercialIssuer(_ issuer: String) -> Bool {
        issuer.lowercased().contains("public ca")
    }

    static func isQualifiedCertificate(issuer: String, displayName: String, qualification: String?) -> Bool {
        if isCommercialIssuer(issuer) { return false }
        if qualification == "QESIG" { return true }
        let text = "\(issuer) \(displayName)".lowercased()
        return text.contains("qualified") || text.contains("qcp") || text.contains("eidas")
            || text.contains("oprávnenie") || text.contains("opravnenie")
    }

    /// Only the mandate token decides (`MandateCertificate`): a QESIG certificate from a
    /// qualified issuer is not a mandate certificate, so it no longer counts as one.
    static func isMandateCertificate(issuer: String, displayName: String, qualification: String? = nil) -> Bool {
        if isCommercialIssuer(issuer) { return false }
        return MandateCertificate.matches(subject: displayName, issuer: issuer)
    }

    static func syntheticIdentity(driverNames: [String] = [], driverID connectedDriverID: String? = nil) -> SigningIdentityInfo {
        let label: String
        if driverNames.isEmpty {
            label = "Podpisová karta (eID / advokátsky preukaz)"
        } else {
            label = "Karta pripojená: \(driverNames.joined(separator: " + "))"
        }
        let protectedPath = connectedDriverID.map { !requiresPIN(driverID: $0) } ?? false
        return SigningIdentityInfo(
            id: "\(syntheticIdentityIDPrefix)\(driverID)",
            label: label,
            issuerSummary: "Zadajte PIN pre načítanie certifikátov",
            isMandateCertificate: false,
            isQualified: true,
            hasPrivateKey: true,
            requiresPIN: true,
            usesProtectedAuthenticationPath: protectedPath)
    }

    static func identityInfo(from certificate: SigningCertificate, driverID connectedDriverID: String) -> SigningIdentityInfo {
        SigningIdentityInfo(
            id: "\(certificateIdentityPrefix)\(certificate.serialNumber)",
            label: certificate.displayName,
            issuerSummary: certificate.issuer,
            validUntil: certificate.validUntil,
            isMandateCertificate: isMandateCertificate(issuer: certificate.issuer,
                                                       displayName: certificate.displayName,
                                                       qualification: certificate.certificateQualification),
            isQualified: isQualifiedCertificate(issuer: certificate.issuer,
                                                displayName: certificate.displayName,
                                                qualification: certificate.certificateQualification),
            hasPrivateKey: true,
            requiresPIN: true,
            usesProtectedAuthenticationPath: !requiresPIN(driverID: connectedDriverID))
    }

    static func selectCertificate(from certificates: [SigningCertificate],
                                  preferredSerialNumber: String?) -> SigningCertificate? {
        if let preferredSerialNumber,
           let exact = certificates.first(where: { $0.serialNumber == preferredSerialNumber }) {
            return exact
        }
        return certificates.first { $0.certificateQualification == "QESIG" }
            ?? certificates.first
    }

    static func map(_ failure: SigningFailure) -> SigningError {
        switch failure {
        case .engine(let message):
            return .signingFailed(Self.localizedEngineMessage(message))
        case .fileFailed(let fileID):
            return .signingFailed("Súbor \(fileID) sa nepodarilo podpísať.")
        case .invalidTransition:
            return .signingFailed("Interná chyba podpisového stavu.")
        }
    }

    /// Zjednodušené čitateľné hlásenia pre známe kódy engine-u.
    static func localizedEngineMessage(_ message: String) -> String {
        func code(_ name: String) -> Bool { message.contains("[\(name)]") || message.contains(name) }
        if code("TOKEN_NOT_PRESENT") {
            return "V čítačke nie je karta: vložte ju a skúste znova."
        }
        if code("TOKEN_NOT_RECOGNIZED") {
            return "Karta v čítačke nezodpovedá zvolenému ovládaču (eID klient alebo I.CA SecureStore)."
        }
        if code("DRIVER_UNAVAILABLE") || code("DRIVER_NOT_FOUND") {
            return "Karta nie je dostupná: vložte ju do čítačky a skúste znova."
        }
        if code("PIN_INCORRECT") {
            return "Nesprávny PIN alebo BOK."
        }
        if code("PIN_LOCKED") {
            return "PIN karty je zablokovaný: odomknite ho PUK kódom cez nástroj výrobcu karty."
        }
        if code("OPERATION_CANCELLED") {
            return "Operácia s kartou bola zrušená."
        }
        if code("CERTIFICATE_NOT_FOUND") || code("CERTIFICATE_AMBIGUOUS") {
            return "Zvolený certifikát už nie je na karte: obnovte zoznam certifikátov."
        }
        if code("TIMESTAMP_FAILED") {
            return "Nepodarilo sa získať kvalifikovanú časovú pečiatku (TSA)."
        }
        if code("TIMESTAMP_QUALIFICATION_FAILED") {
            return "Časová pečiatka nie je kvalifikovaná. Skontrolujte TSA a internet."
        }
        if code("TRUSTED_LIST_UNAVAILABLE") {
            return "EU zoznam dôveryhodných CA sa nepodarilo stiahnuť. Zapnite internet a skúste znova; vizuálna pečiatka tento zoznam potrebuje."
        }
        if code("OUTPUT_VALIDATION_FAILED") {
            return "Engine odmietol výsledok podpisu (výstupná validácia)."
        }
        return message
    }

    /// Mapovanie ostatných chýb bridge vrstvy (session proces, launcher).
    static func mapAny(_ error: Error) -> SigningError {
        if let failure = error as? SigningFailure {
            return map(failure)
        }
        if let sessionFailure = error as? MachineSessionProcessFailure {
            switch sessionFailure {
            case .launchFailed:
                return .signingFailed("Engine sa nepodarilo spustiť (AutogramCLI helper).")
            case .malformedOutput:
                return .signingFailed("Engine vrátil nečitateľnú odpoveď.")
            case .helperExited(let status):
                return .signingFailed("Engine proces sa ukončil (exit \(status)).")
            case .requestFailed(let code):
                return .signingFailed(localizedEngineMessage("The machine request could not be completed. [\(code)]"))
            case .cancelled:
                return .signingFailed("Podpisovanie bolo zrušené.")
            }
        }
        if error is CancellationError {
            return .signingFailed("Podpisovanie bolo zrušené.")
        }
        return .signingFailed(error.localizedDescription)
    }

    static func hasVisibleSignatureField(in pdf: Data) -> Bool {
        guard let sig = pdf.range(of: Data("/FT /Sig".utf8)) else { return false }
        let window = pdf[sig.lowerBound..<min(pdf.endIndex, sig.lowerBound + 400)]
        let text = String(decoding: window, as: UTF8.self)
        if text.contains("[0.0 0.0 0.0 0.0]") || text.contains("[0 0 0 0]") { return false }
        return text.contains("/Rect")
    }

    static func makeWorkspace(fileManager: FileManager = .default) throws -> URL {
        let temporary = EnginePaths.canonical(URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true))
        let directory = temporary
            .appendingPathComponent("chevron7-engine", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func statusLog(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }
}

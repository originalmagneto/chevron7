// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import Foundation
@preconcurrency import Security
import CryptoKit
import os
import CryptoTokenKit

public struct SigningIdentityInfo: Identifiable, Hashable, Sendable {
    public var id: String
    public var label: String
    public var issuerSummary: String
    public var validUntil: Date?
    public var isMandateCertificate: Bool
    public var isQualified: Bool
    public var hasPrivateKey: Bool
    public var pkcs11CertSHA256Hex: String?
    public var pkcs11IsRSA: Bool
    public var requiresPIN: Bool
    /// The card takes its PIN in the middleware's own window (an eID reports
    /// CKF_PROTECTED_AUTHENTICATION_PATH), so a prompt may skip its PIN field.
    public var usesProtectedAuthenticationPath: Bool

    public init(id: String, label: String, issuerSummary: String,
                validUntil: Date? = nil, isMandateCertificate: Bool = false,
                isQualified: Bool = false, hasPrivateKey: Bool = true,
                pkcs11CertSHA256Hex: String? = nil, pkcs11IsRSA: Bool = true,
                requiresPIN: Bool = false, usesProtectedAuthenticationPath: Bool = false) {
        self.id = id
        self.label = label
        self.issuerSummary = issuerSummary
        self.validUntil = validUntil
        self.isMandateCertificate = isMandateCertificate
        self.isQualified = isQualified
        self.hasPrivateKey = hasPrivateKey
        self.pkcs11CertSHA256Hex = pkcs11CertSHA256Hex
        self.pkcs11IsRSA = pkcs11IsRSA
        self.requiresPIN = requiresPIN
        self.usesProtectedAuthenticationPath = usesProtectedAuthenticationPath
    }
}

extension SigningIdentityInfo {
    /// False for the engine's synthetic card identity, which stands for a card whose
    /// certificates were not read yet: its label and issuer are prompts, not certificate data.
    public var describesCertificate: Bool {
        !id.hasPrefix(EngineBridgeSigningProvider.syntheticIdentityIDPrefix)
    }

    /// Which kind of card holds the certificate, for the reader status.
    public var cardKindLabel: String? {
        if usesProtectedAuthenticationPath { return "Občiansky preukaz (eID)" }
        let text = "\(label) \(issuerSummary)"
        if text.contains("I.CA") { return "Karta I.CA" }
        if text.localizedCaseInsensitiveContains("eID") { return "Občiansky preukaz (eID)" }
        return nil
    }
}

public struct RawSigner: @unchecked Sendable {
    public var signatureMethodURI: String
    public var isRSA: Bool
    public var sign: @Sendable (Data) throws -> Data

    public static let rsaMethod = "http://www.w3.org/2001/04/xmldsig-more#rsa-sha256"
    public static let ecdsaMethod = "http://www.w3.org/2001/04/xmldsig-more#ecdsa-sha256"

    public static func secKey(_ key: SecKey) -> RawSigner {
        let rsa = SecKeyIsAlgorithmSupported(key, .sign, .rsaSignatureMessagePKCS1v15SHA256)
            || SecKeyIsAlgorithmSupported(key, .sign, .rsaSignatureDigestPKCS1v15SHA256)
            || SecKeyIsAlgorithmSupported(key, .sign, .rsaSignatureRaw)
        if rsa {
            return RawSigner(signatureMethodURI: RawSigner.rsaMethod, isRSA: true) { data in
                try signRSA(key: key, message: data)
            }
        }
        return RawSigner(signatureMethodURI: RawSigner.ecdsaMethod, isRSA: false) { data in
            try createSignature(key: key, algorithm: .ecdsaSignatureMessageX962SHA256, data: data)
        }
    }

    static func signRSA(key: SecKey, message: Data) throws -> Data {
        let digest = Data(SHA256.hash(data: message))
        let digestInfo = sha256DigestInfo(digest)
        let attempts: [(SecKeyAlgorithm, Data)] = [
            (.rsaSignatureMessagePKCS1v15SHA256, message),
            (.rsaSignatureDigestPKCS1v15SHA256, digest),
            (.rsaSignatureRaw, digestInfo)
        ]
        var lastError = "neznáma chyba"
        for (algorithm, payload) in attempts {
            if !SecKeyIsAlgorithmSupported(key, .sign, algorithm) { continue }
            do {
                return try createSignature(key: key, algorithm: algorithm, data: payload)
            } catch let error as XAdESError {
                if case .signingFailed(let detail) = error {
                    lastError = detail
                    if detail.localizedCaseInsensitiveContains("cancel")
                        || detail.localizedCaseInsensitiveContains("zruš") {
                        throw error
                    }
                } else {
                    throw error
                }
            }
        }
        if lastError.localizedCaseInsensitiveContains("code state")
            || lastError.localizedCaseInsensitiveContains("Invalid") {
            throw XAdESError.signingFailed(
                "Karta je v neplatnom stave. Otvorte eID_klient, zadajte BOK a skúste znova (prípadne kartu vyberte a vložte).")
        }
        throw XAdESError.signingFailed(lastError)
    }

    static func sha256DigestInfo(_ digest: Data) -> Data {
        DER.sequence([
            DER.sequence([DER.oid("2.16.840.1.101.3.4.2.1"), DER.tlv(0x05, Data())]),
            DER.octetString(digest)
        ])
    }

    static func createSignature(key: SecKey, algorithm: SecKeyAlgorithm, data: Data) throws -> Data {
        try runOnMain {
            var error: Unmanaged<CFError>?
            guard let signature = SecKeyCreateSignature(key, algorithm, data as CFData, &error) else {
                let detail = error?.takeRetainedValue().localizedDescription ?? "neznáma chyba"
                throw XAdESError.signingFailed(detail)
            }
            return signature as Data
        }
    }

    static func runOnMain<T>(_ work: () throws -> T) rethrows -> T {
        if Thread.isMainThread { return try work() }
        return try DispatchQueue.main.sync(execute: work)
    }

    public static func pkcs11(certSHA256Hex: String, isRSA: Bool, pin: String) -> RawSigner {
        RawSigner(signatureMethodURI: isRSA ? RawSigner.rsaMethod : RawSigner.ecdsaMethod,
                  isRSA: isRSA) { data in
            let digest = Data(SHA256.hash(data: data))
            let raw = try PKCS11BridgeClient.sign(certSHA256Hex: certSHA256Hex,
                                                  pin: pin, digest: digest)
            return isRSA ? raw : Self.derECDSA(fromConcatenated: raw)
        }
    }

    static func derECDSA(fromConcatenated raw: Data) -> Data {
        guard raw.count >= 2, raw.count % 2 == 0 else { return raw }
        let half = raw.count / 2
        func integer(_ bytes: ArraySlice<UInt8>) -> Data {
            var b = Array(bytes)
            while b.count > 1 && b.first == 0 { b.removeFirst() }
            if b.first ?? 0 >= 0x80 { b.insert(0x00, at: 0) }
            return DER.integerFromRaw(b)
        }
        let bytes = Array(raw)
        return DER.sequence([
            integer(bytes[0..<half]),
            integer(bytes[half...])
        ])
    }
}

public enum SigningError: LocalizedError, Equatable, Sendable {
    case identityUnavailable
    case signingFailed(String)
    case timestampFailed

    public var errorDescription: String? {
        switch self {
        case .identityUnavailable:
            return "Certifikát nie je dostupný: vložte kartu a overte PIN/BOK."
        case .signingFailed(let detail): return "Podpisovanie zlyhalo: \(detail)"
        case .timestampFailed: return "Nepodarilo sa získať kvalifikovanú časovú pečiatku."
        }
    }
}

/// Whether a new signature's timestamp is qualified, as the engine judged it against the EU
/// trusted lists right after signing. It informs; it never decides whether the signature is kept.
public enum TimestampQualification: Equatable, Sendable {
    case qualified
    case notQualified
    /// The list of the authority's country did not load, so qualification could not be checked.
    case unverified(country: String?)

    public init?(engineValue: String?, country: String?) {
        switch engineValue {
        case "qualified": self = .qualified
        case "notQualified": self = .notQualified
        case "unverified": self = .unverified(country: country)
        default: return nil
        }
    }

    /// One Slovak sentence for the result screen and the note under the authority picker.
    public var slovakDescription: String {
        switch self {
        case .qualified:
            return "Časová pečiatka je kvalifikovaná."
        case .notQualified:
            return "Časová pečiatka nie je kvalifikovaná: autorita nie je v dôveryhodnom zozname EÚ vedená ako kvalifikovaná. Podpis je platný."
        case .unverified(let country):
            let name = country.flatMap { Locale(identifier: "sk").localizedString(forRegionCode: $0) }
            let list = name.map { "dôveryhodný zoznam krajiny \($0)" } ?? "dôveryhodný zoznam autority"
            return "Kvalifikáciu časovej pečiatky sa nepodarilo overiť: \(list) sa nepodarilo stiahnuť. Podpis je platný."
        }
    }
}

public struct SignedConversionResult: Sendable {
    public var pdfData: Data
    public var asicData: Data?
    public var signedAt: Date
    public var signatureLabel: String
    public var isLegallyBinding: Bool
    public var timestampGenTime: Date?
    public var timestampToken: Data?
    public var timestampQualification: TimestampQualification?
    /// The issuer of the certificate that made the signature, when the provider knows it
    /// (the engine after reading the card's certificates, the phone from its signers).
    /// Nil when the engine picked the token's only key without reading it (an eID).
    public var signerIssuer: String?

    public init(pdfData: Data, asicData: Data?, signedAt: Date,
                signatureLabel: String, isLegallyBinding: Bool,
                timestampGenTime: Date? = nil, timestampToken: Data? = nil,
                timestampQualification: TimestampQualification? = nil,
                signerIssuer: String? = nil) {
        self.pdfData = pdfData
        self.asicData = asicData
        self.signedAt = signedAt
        self.signatureLabel = signatureLabel
        self.isLegallyBinding = isLegallyBinding
        self.timestampGenTime = timestampGenTime
        self.timestampToken = timestampToken
        self.timestampQualification = timestampQualification
        self.signerIssuer = signerIssuer
    }

    /// The issuer to name for this signature: the signed result's own, else the identity's
    /// when it describes a certificate read from the card, else empty. A synthetic card
    /// identity carries a prompt in `issuerSummary`, which is never an issuer.
    public func issuerName(fallback identity: SigningIdentityInfo?) -> String {
        if let signerIssuer = signerIssuer?.trimmingCharacters(in: .whitespacesAndNewlines),
           !signerIssuer.isEmpty {
            return signerIssuer
        }
        guard let identity, identity.describesCertificate else { return "" }
        return identity.issuerSummary
    }
}

public enum SigningOutputFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case attachedASIC = "ASiC-E kontajner (XAdES)"
    case embeddedPAdES = "PAdES podpis v PDF"

    public var id: String { rawValue }
}

public struct VisualStampSpec: Sendable {
    public var fullName: String
    public var timestamp: Date
    public var pageIndex: Int
    public var normalizedRect: NormalizedRect
    public var imagePNG: Data?
    public var pdfPageRect: CGRect?
    public var rotationDegrees: Double
    public var qualification: String?
    public var certificateName: String?
    public var timestampAuthorityName: String?

    public init(
        fullName: String,
        timestamp: Date,
        pageIndex: Int,
        normalizedRect: NormalizedRect,
        imagePNG: Data? = nil,
        pdfPageRect: CGRect? = nil,
        rotationDegrees: Double = 0,
        qualification: String? = nil,
        certificateName: String? = nil,
        timestampAuthorityName: String? = nil
    ) {
        self.fullName = fullName
        self.timestamp = timestamp
        self.pageIndex = pageIndex
        self.normalizedRect = normalizedRect
        self.imagePNG = imagePNG
        self.pdfPageRect = pdfPageRect
        self.rotationDegrees = rotationDegrees
        self.qualification = qualification
        self.certificateName = certificateName
        self.timestampAuthorityName = timestampAuthorityName
    }
}

public struct SigningRequest: Sendable {
    public var pdfData: Data
    public var identityID: String
    public var includeTimestamp: Bool
    public var tsaURL: String?
    public var outputFormat: SigningOutputFormat
    public var pin: String?
    public var extraFiles: [ASiCEPackager.Entry]
    public var visualStamp: VisualStampSpec?
    /// eForm and XDC attributes, set only for documents that came from a state
    /// portal. When present the engine builds an XML Data Container.
    public var eform: EFormSigningAttributes?
    /// Overrides the level implied by `outputFormat`. Portals ask for Baseline B.
    public var signatureLevelOverride: String?
    /// Filename the document should keep inside the container. The browser path
    /// knows the real name; the app path derives one from the source URL.
    public var filename: String?
    /// ZaKo: sign `pdfData` and the data entries of `extraFiles` as separate data objects of
    /// one ASiC-E the engine builds, instead of wrapping a packaged container.
    public var signsExtraFilesAsDataObjects: Bool
    /// Explicit timestamp endpoints for this signature. When set and non-empty the
    /// engine uses exactly these for a Baseline T signature instead of the user's
    /// own timestamp preferences; `nil` keeps today's behaviour.
    public var timestampServers: [String]?
    /// EZZK conversion record: sign `pdfData` (the record's XDC bytes) under
    /// `filename`, which must end in `.xdcf`, as a one-file ASiC-E.
    public var signsAsRecordContainer: Bool

    public init(pdfData: Data, identityID: String,
                includeTimestamp: Bool, tsaURL: String? = nil,
                outputFormat: SigningOutputFormat = .attachedASIC,
                pin: String? = nil,
                extraFiles: [ASiCEPackager.Entry] = [],
                visualStamp: VisualStampSpec? = nil,
                eform: EFormSigningAttributes? = nil,
                signatureLevelOverride: String? = nil,
                filename: String? = nil,
                signsExtraFilesAsDataObjects: Bool = false,
                timestampServers: [String]? = nil,
                signsAsRecordContainer: Bool = false) {
        self.pdfData = pdfData
        self.identityID = identityID
        self.includeTimestamp = includeTimestamp
        self.tsaURL = tsaURL
        self.outputFormat = outputFormat
        self.pin = pin
        self.extraFiles = extraFiles
        self.visualStamp = visualStamp
        self.eform = eform
        self.signatureLevelOverride = signatureLevelOverride
        self.filename = filename
        self.signsExtraFilesAsDataObjects = signsExtraFilesAsDataObjects
        self.timestampServers = timestampServers
        self.signsAsRecordContainer = signsAsRecordContainer
    }
}

public struct DocumentSignatureInfo: Sendable, Identifiable, Equatable {
    public var id: String
    public var signerDisplayName: String
    public var format: String?
    public var signingTime: Date?
    /// True only when full validation confirmed a qualified timestamp.
    public var hasQualifiedTimestamp: Bool
    /// A timestamp is present and cryptographically intact (structural knowledge only).
    public var hasTimestamp: Bool
    public var state: State
    public var detail: String?
    /// Names of the container's data objects this signature covers.
    public var coveredDocuments: [String]
    /// DSS SignatureQualification name from full validation, e.g. "QESIG".
    public var certificateQualification: String?
    /// Who issued the first intact timestamp, as the engine names it. After full
    /// validation that is the timestamp unit's own certificate name; the structural
    /// pass reports the issuer DN of that certificate instead, so only a validated
    /// value names the authority.
    public var timestampAuthority: String?
    /// When the first intact timestamp was produced.
    public var timestampTime: Date?

    public enum State: String, Sendable, Equatable {
        case valid
        case invalid
        case indeterminate
        case unknown
    }

    public init(id: String, signerDisplayName: String, format: String? = nil,
                signingTime: Date? = nil, hasQualifiedTimestamp: Bool = false,
                hasTimestamp: Bool = false, state: State = .unknown, detail: String? = nil,
                coveredDocuments: [String] = [], certificateQualification: String? = nil,
                timestampAuthority: String? = nil, timestampTime: Date? = nil) {
        self.id = id
        self.signerDisplayName = signerDisplayName
        self.format = format
        self.signingTime = signingTime
        self.hasQualifiedTimestamp = hasQualifiedTimestamp
        self.hasTimestamp = hasTimestamp || hasQualifiedTimestamp
        self.state = state
        self.detail = detail
        self.coveredDocuments = coveredDocuments
        self.certificateQualification = certificateQualification
        self.timestampAuthority = timestampAuthority
        self.timestampTime = timestampTime
    }
}

public protocol QualifiedSigningProviding: Sendable {
    func availableIdentities() async -> [SigningIdentityInfo]
    func resolveIdentities(pin: String) async -> [SigningIdentityInfo]?
    func sign(_ request: SigningRequest) async throws -> SignedConversionResult
    func inspectSignatures(in fileURL: URL) async -> [DocumentSignatureInfo]
    func inspectInputSignatures(in fileURL: URL) async -> InputSignatureInspectionResult
    func inspectInputSignatures(in fileURLs: [URL]) async -> [URL: InputSignatureInspectionResult]
    /// Structural signature tree of the file: fast, no trusted lists.
    func inspectSignatureTree(in fileURL: URL) async -> SignatureTreeResult
    /// The same tree validated against the EU trusted lists (informative validation).
    func validateSignatureTree(in fileURL: URL) async -> SignatureTreeResult
    /// Whether `sign` adds a signature to an ASiC-E handed over as the source (named by
    /// `SigningRequest.filename`) instead of wrapping that container in a new one.
    var addsSignatureToExistingContainer: Bool { get }
    /// Whether every signature from `sign` carries a qualified timestamp whatever
    /// `includeTimestamp` says, as the engine does for ordinary files.
    var alwaysAddsQualifiedTimestamp: Bool { get }
}

extension QualifiedSigningProviding {
    public func inspectSignatures(in fileURL: URL) async -> [DocumentSignatureInfo] { [] }

    public var addsSignatureToExistingContainer: Bool { false }

    public var alwaysAddsQualifiedTimestamp: Bool { false }

    public func inspectSignatureTree(in fileURL: URL) async -> SignatureTreeResult {
        let result = await inspectInputSignatures(in: fileURL)
        if result.state == .unavailable {
            return .failed(result.detail)
        }
        return .tree(SignatureTree(signatures: result.signatures))
    }

    public func validateSignatureTree(in fileURL: URL) async -> SignatureTreeResult {
        .failed("Plné overenie vyžaduje podpisový engine.")
    }

    public func inspectInputSignatures(in fileURL: URL) async -> InputSignatureInspectionResult {
        InputSignatureVerificationService.structuralInspection(at: fileURL)
    }

    /// Načíta reálne certifikáty z vloženej karty ešte pred podpisom.
    public func resolveIdentities(pin: String) async -> [SigningIdentityInfo]? { nil }

    public func sign(pdf: Data, identityID: String,
                     includeTimestamp: Bool) async throws -> SignedConversionResult {
        try await sign(SigningRequest(pdfData: pdf, identityID: identityID,
                                      includeTimestamp: includeTimestamp))
    }
    public func inspectInputSignatures(in fileURLs: [URL]) async -> [URL: InputSignatureInspectionResult] {
        var results: [URL: InputSignatureInspectionResult] = [:]
        for fileURL in fileURLs {
            let canonical = EnginePaths.canonical(fileURL)
            results[canonical] = await inspectInputSignatures(in: canonical)
        }
        return results
    }

    public func sign(pdf: Data, identityID: String, includeTimestamp: Bool,
                     extraFiles: [ASiCEPackager.Entry]) async throws -> SignedConversionResult {
        try await sign(SigningRequest(pdfData: pdf, identityID: identityID,
                                      includeTimestamp: includeTimestamp,
                                      extraFiles: extraFiles))
    }
}

public final class DemoSigningProvider: QualifiedSigningProviding, @unchecked Sendable {
    private let counter = OSAllocatedUnfairLock(initialState: 0)

    public init() {}

    public func availableIdentities() async -> [SigningIdentityInfo] {
        var result = KeychainIdentityScanner.scanAll()
        if !result.isEmpty { return result }

        result.append(SigningIdentityInfo(
            id: "demo",
            label: "DEMO podpis (vývojový režim)",
            issuerSummary: "Chevron7 Demo CA",
            validUntil: Calendar.current.date(byAdding: .year, value: 1, to: Date()),
            isMandateCertificate: false,
            isQualified: false))
        return result
    }

    public func sign(_ request: SigningRequest) async throws -> SignedConversionResult {
        let n = counter.withLock { state -> Int in
            state += 1
            return state
        }

        var timestampGenTime: Date?
        var timestampTokenData: Data?
        if request.includeTimestamp {
            guard let tsaURLString = request.tsaURL, !tsaURLString.isEmpty,
                  let tsaURL = URL(string: tsaURLString), tsaURL.scheme != nil else {
                throw SigningError.timestampFailed
            }
            let reply = try await RFC3161TimestampClient().requestToken(for: request.pdfData,
                                                                        tsaURL: tsaURL)
            timestampGenTime = reply.genTime
            timestampTokenData = reply.token
        }

        let digest = SHA256.hash(data: request.pdfData).map { String(format: "%02x", $0) }.joined()
        let manifest = """
        {
          "type": "chevron7-demo-signature",
          "legallyBinding": false,
          "note": "Vývojový podpis: nenahrádza KEP s mandátnym certifikátom.",
          "sequence": \(n),
          "identity": "\(request.identityID)",
          "sha256": "\(digest)",
          "timestampRequested": \(request.includeTimestamp),
          "timestampGenTimeISO": \(timestampGenTime.map { "\"\(AttestationClauseGenerator.isoFormatter.string(from: $0))\"" } ?? "null"),
          "signedAtISO": "\(AttestationClauseGenerator.isoFormatter.string(from: Date()))"
        }
        """
        guard let manifestData = manifest.data(using: .utf8) else {
            throw SigningError.signingFailed("Interná chyba manifestu.")
        }

        var merged: [String: ASiCEPackager.Entry] = [:]
        merged["mimetype"] = ASiCEPackager.Entry(
            path: "mimetype",
            data: Data(ASiCEPackager.asicMimeType.utf8),
            storeUncompressed: true)
        for entry in request.extraFiles where entry.path != "META-INF/demo-signature.json" {
            if entry.path == "mimetype" {
                merged["mimetype"] = entry.storeUncompressed ? entry : entry.asStored
            } else {
                merged[entry.path] = entry
            }
        }
        merged["META-INF/demo-signature.json"] =
            ASiCEPackager.Entry(path: "META-INF/demo-signature.json", data: manifestData)
        if let tokenData = timestampTokenData {
            merged["META-INF/timestamp.tsr"] =
                ASiCEPackager.Entry(path: "META-INF/timestamp.tsr", data: tokenData)
        }
        // ZaKo names its data objects: the client container already lists the PDF/A under
        // its own name, and the record keeps "<number>.record.xml.xdcf", as the engine does.
        if request.signsAsRecordContainer || request.signsExtraFilesAsDataObjects,
           let filename = request.filename.map({ ($0 as NSString).lastPathComponent }), !filename.isEmpty {
            if merged[filename] == nil {
                merged[filename] = ASiCEPackager.Entry(path: filename, data: request.pdfData)
            }
        } else {
            merged["document.pdf"] = ASiCEPackager.Entry(path: "document.pdf", data: request.pdfData)
        }

        if merged["META-INF/manifest.xml"] == nil {
            let dataEntries = merged.values
                .filter { $0.path != "mimetype" && !$0.path.hasPrefix("META-INF/") }
                .map { (path: $0.path, mediaType: ASiCEPackager.mediaType(forPath: $0.path)) }
            merged["META-INF/manifest.xml"] = ASiCEPackager.Entry(
                path: "META-INF/manifest.xml",
                data: Data(ASiCEPackager.manifestXML(entries: dataEntries).utf8))
        }

        let asic = try ASiCEPackager().package(files: Array(merged.values))

        return SignedConversionResult(
            pdfData: request.pdfData,
            asicData: asic,
            signedAt: Date(),
            signatureLabel: "Demo podpis #\(n) (SHA-256 potvrdený)",
            isLegallyBinding: false,
            timestampGenTime: timestampGenTime,
            timestampToken: timestampTokenData)
    }
}

public enum SigningProviderFactory {
    public static func makeDefault() -> any QualifiedSigningProviding {
        if let installation = JavaEngineLocator().locate(),
           FileManager.default.isExecutableFile(atPath: installation.helperURL.path) {
            return EngineBridgeSigningProvider()
        }
        let hasRealIdentity = KeychainIdentityScanner.scanAll().contains { $0.hasPrivateKey }
        return hasRealIdentity ? KeychainXAdESSigningProvider() : DemoSigningProvider()
    }
}

public enum KeychainIdentityScanner {
    static let qualifiedIssuerHints = ["i.ca", "ica", "disig", "eid", "e-id", "nase", "nácionalna",
                                       "národná", "slovensko", "qcp", "qualified", "certum", "bok"]

    static let junkPatterns = ["apple development", "apple id", "apple webauthn", "kerberos",
                               "systemdefault", ".home", ".local", "codesigning",
                               "com.apple", "mac-studio", "macbook", "imac"]

    static let rootCAPatterns = ["certificate services", "content certificate", "certification authority",
                                 "worldwide developer", "public primary", "root ca", " root", " root ",
                                 " g2", " r2", " r3", " r2i3", " ca - ", "client authentication and secure"]

    public static func isJunk(_ summary: String) -> Bool {
        let lowered = summary.lowercased()
        return junkPatterns.contains { lowered.contains($0) }
    }

    public static func looksLikeRootCA(_ summary: String) -> Bool {
        let lowered = " " + summary.lowercased() + " "
        return rootCAPatterns.contains { lowered.contains($0) }
    }

    public static func hasConnectedToken() -> Bool {
        let watcher = TKTokenWatcher()
        return watcher.tokenIDs.contains { !$0.lowercased().hasPrefix("apple.") && !$0.lowercased().hasPrefix("com.apple") }
    }

    public static func connectedTokenIDs() -> [String] {
        TKTokenWatcher().tokenIDs.filter { id in
            let lowered = id.lowercased()
            return !lowered.hasPrefix("apple.") && !lowered.hasPrefix("com.apple")
        }
    }

    public static func scanAll() -> [SigningIdentityInfo] {
        guard hasConnectedToken() else { return [] }
        var result = scanTokenIdentities()
        var existing = Set(result.map(\.label))
        for pair in certificateKeyPairs() where existing.insert(pair.label).inserted {
            result.append(pair)
        }
        if result.contains(where: \.hasPrivateKey) {
            return result.sorted { $0.label < $1.label }
        }
        existing = Set(result.map(\.label))
        for identity in PKCS11BridgeClient.listIdentities() {
            guard existing.insert(identity.subjectSummary).inserted,
                  !identity.certificateDER.isEmpty else { continue }
            result.append(SigningIdentityInfo(
                id: "pkcs11:\(identity.subjectSummary)",
                label: identity.subjectSummary,
                issuerSummary: identity.issuerSummary,
                isMandateCertificate: identity.isMandateCertificate,
                isQualified: identity.isQualified,
                hasPrivateKey: true,
                pkcs11CertSHA256Hex: identity.certSHA256Hex,
                pkcs11IsRSA: identity.isRSA,
                requiresPIN: true))
        }
        return result.sorted { $0.label < $1.label }
    }

    public static func scanTokenIdentities() -> [SigningIdentityInfo] {
        var seen = Set<String>()
        var result: [SigningIdentityInfo] = []
        for tokenID in connectedTokenIDs() {
            result.append(contentsOf: identities(onToken: tokenID, seen: &seen))
        }
        return result
    }

    static func identities(onToken tokenID: String, seen: inout Set<String>) -> [SigningIdentityInfo] {
        let ders = certificateDERs(tokenID: tokenID)
        let tokenKey = privateKey(tokenID: tokenID)
        var infos: [SigningIdentityInfo] = []
        for der in ders {
            guard let cert = SecCertificateCreateWithData(nil, der as CFData),
                  let summary = SecCertificateCopySubjectSummary(cert) as String?,
                  !summary.isEmpty,
                  !isJunk(summary),
                  !looksLikeRootCA(summary),
                  seen.insert(summary).inserted else { continue }
            let key = privateKey(for: cert) ?? tokenKey.flatMap { candidate in
                keysMatch(candidate, certificate: cert) ? candidate : nil
            }
            guard key != nil else { continue }
            infos.append(info(for: cert, summary: summary))
        }
        return infos
    }

    static func certificateDERs(tokenID: String) -> [Data] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrTokenID as String: tokenID,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return [] }
        if let items = result as? [Data] { return items }
        if let data = result as? Data { return [data] }
        if let dicts = result as? [[String: Any]] {
            return dicts.compactMap { $0[kSecValueData as String] as? Data }
        }
        return []
    }

    static func privateKey(tokenID: String) -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecAttrTokenID as String: tokenID,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnRef as String: true
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let object = result, CFGetTypeID(object) == SecKeyGetTypeID() else { return nil }
        return (object as! SecKey)
    }

    static func keysMatch(_ privateKey: SecKey, certificate: SecCertificate) -> Bool {
        guard let certPublic = SecCertificateCopyKey(certificate),
              let keyPublic = SecKeyCopyPublicKey(privateKey) else { return false }
        var firstError: Unmanaged<CFError>?
        var secondError: Unmanaged<CFError>?
        guard let left = SecKeyCopyExternalRepresentation(certPublic, &firstError) as Data?,
              let right = SecKeyCopyExternalRepresentation(keyPublic, &secondError) as Data? else {
            return true
        }
        return left == right
    }

    static func info(for certificate: SecCertificate, summary: String) -> SigningIdentityInfo {
        let issuerText = X509Inspector.facts(certificateData: SecCertificateCopyData(certificate) as Data)?
            .issuerRFC2253 ?? ""
        let searchable = summary + " " + issuerText
        return SigningIdentityInfo(
            id: "certificate:\(summary)",
            label: summary,
            issuerSummary: issuerCN(fromRFC2253: issuerText) ?? Self.issuerHint(from: searchable),
            isMandateCertificate: Self.looksMandate(searchable),
            isQualified: Self.looksQualified(searchable) || !issuerText.isEmpty,
            hasPrivateKey: true)
    }

    public struct IdentityPair: @unchecked Sendable {
        public let certificate: SecCertificate
        public let privateKey: SecKey
        public let summary: String
    }

    public static func certificateKeyPairs() -> [SigningIdentityInfo] {
        var query = [String: Any]()
        query[kSecClass as String] = kSecClassCertificate
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnData as String] = true

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return [] }
        let blobs: [Data]
        if let items = result as? [Data] {
            blobs = items
        } else if let dicts = result as? [[String: Any]] {
            blobs = dicts.compactMap { $0[kSecValueData as String] as? Data }
        } else {
            return []
        }

        var seen = Set<String>()
        var pairs: [SigningIdentityInfo] = []
        for blob in blobs {
            guard let cert = SecCertificateCreateWithData(nil, blob as CFData),
                  let summary = SecCertificateCopySubjectSummary(cert) as String?,
                  !summary.isEmpty,
                  !isJunk(summary),
                  !looksLikeRootCA(summary),
                  seen.insert(summary).inserted,
                  privateKey(for: cert) != nil else { continue }
            pairs.append(info(for: cert, summary: summary))
        }
        return pairs.sorted { $0.label < $1.label }
    }

    static func issuerCN(fromRFC2253 issuer: String) -> String? {
        for part in issuer.split(separator: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("CN=") {
                return String(trimmed.dropFirst(3))
            }
        }
        return nil
    }

    public static func privateKey(for certificate: SecCertificate) -> SecKey? {
        guard let publicKey = SecCertificateCopyKey(certificate),
              let label = publicKeyHash(for: publicKey) else { return nil }
        var query = [String: Any]()
        query[kSecClass as String] = kSecClassKey
        query[kSecAttrApplicationLabel as String] = label
        query[kSecAttrKeyClass as String] = kSecAttrKeyClassPrivate
        query[kSecReturnRef as String] = true
        var item: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let key = item else { return nil }
        return key as! SecKey
    }

    static func publicKeyHash(for publicKey: SecKey) -> Data? {
        var error: Unmanaged<CFError>?
        guard let external = SecKeyCopyExternalRepresentation(publicKey, &error) as Data? else { return nil }

        var query = [String: Any]()
        query[kSecClass as String] = kSecClassKey
        query[kSecValueRef as String] = publicKey
        query[kSecReturnAttributes as String] = true
        var attrResult: AnyObject?
        var keyType = kSecAttrKeyTypeRSA as String
        if SecItemCopyMatching(query as CFDictionary, &attrResult) == errSecSuccess,
           let attrs = attrResult as? [String: Any],
           let type = attrs[kSecAttrKeyType as String] as? String {
            keyType = type
        }

        let algorithmOID: String
        let params: Data
        if keyType == (kSecAttrKeyTypeECSECPrimeRandom as String) {
            algorithmOID = "1.2.840.10045.2.1"
            let curveOID: String
            switch SecKeyGetBlockSize(publicKey) {
            case 32: curveOID = "1.2.840.10045.3.1.7"
            case 48: curveOID = "1.3.132.0.34"
            case 66: curveOID = "1.3.132.0.35"
            default: curveOID = "1.2.840.10045.3.1.7"
            }
            params = DER.oid(curveOID)
        } else {
            algorithmOID = "1.2.840.113549.1.1.1"
            params = DER.tlv(0x05, Data())
        }

        let spki = DER.sequence([
            DER.sequence([DER.oid(algorithmOID), params]),
            DER.tlv(0x03, Data([0x00]) + external)
        ])
        return Data(Insecure.SHA1.hash(data: spki))
    }

    public static func resolveIdentityPair(id: String) -> IdentityPair? {
        guard id.hasPrefix("certificate:") || id.hasPrefix("identity:") else { return nil }
        let wanted = id.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""

        for tokenID in connectedTokenIDs() {
            if let pair = resolveTokenPair(tokenID: tokenID, summary: wanted) {
                return pair
            }
        }

        var query = [String: Any]()
        query[kSecClass as String] = kSecClassCertificate
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnData as String] = true
        var result: AnyObject?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess {
            let blobs: [Data]
            if let items = result as? [Data] {
                blobs = items
            } else if let dicts = result as? [[String: Any]] {
                blobs = dicts.compactMap { $0[kSecValueData as String] as? Data }
            } else {
                blobs = []
            }
            for blob in blobs {
                guard let cert = SecCertificateCreateWithData(nil, blob as CFData),
                      let summary = SecCertificateCopySubjectSummary(cert) as String?,
                      summary == wanted,
                      let privateKey = privateKey(for: cert) else { continue }
                return IdentityPair(certificate: cert, privateKey: privateKey, summary: summary)
            }
        }

        var identityQuery = [String: Any]()
        identityQuery[kSecClass as String] = kSecClassIdentity
        identityQuery[kSecMatchLimit as String] = kSecMatchLimitAll
        identityQuery[kSecReturnRef as String] = true
        guard SecItemCopyMatching(identityQuery as CFDictionary, &result) == errSecSuccess,
              let identities = result as? [SecIdentity] else { return nil }
        for identity in identities {
            var cert: SecCertificate?
            var key: SecKey?
            guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess,
                  let certificate = cert,
                  let summary = SecCertificateCopySubjectSummary(certificate) as String?,
                  summary == wanted,
                  SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess,
                  let privateKey = key else { continue }
            return IdentityPair(certificate: certificate, privateKey: privateKey, summary: summary)
        }
        return nil
    }

    static func resolveTokenPair(tokenID: String, summary wanted: String) -> IdentityPair? {
        let tokenKey = privateKey(tokenID: tokenID)
        for der in certificateDERs(tokenID: tokenID) {
            guard let cert = SecCertificateCreateWithData(nil, der as CFData),
                  let summary = SecCertificateCopySubjectSummary(cert) as String?,
                  summary == wanted else { continue }
            if let key = privateKey(for: cert) {
                return IdentityPair(certificate: cert, privateKey: key, summary: summary)
            }
            if let key = tokenKey, keysMatch(key, certificate: cert) {
                return IdentityPair(certificate: cert, privateKey: key, summary: summary)
            }
        }
        return nil
    }

    public static func scanCodeSigningIdentities() -> [SigningIdentityInfo] {
        var query = [String: Any]()
        query[kSecClass as String] = kSecClassIdentity
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnRef as String] = true

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess || status == errSecItemNotFound else { return [] }
        guard let refs = result as? [SecIdentity], !refs.isEmpty else { return [] }

        return refs.compactMap { ref in
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(ref, &certificate) == errSecSuccess,
                  let cert = certificate else { return nil }

            let summary = SecCertificateCopySubjectSummary(cert) as String? ?? "Certifikát"
            return SigningIdentityInfo(
                id: "identity:\(summary)",
                label: summary,
                issuerSummary: Self.issuerHint(from: summary),
                isMandateCertificate: Self.looksMandate(summary),
                isQualified: Self.looksQualified(summary))
        }
    }

    public static func resolveIdentity(id: String) -> (identity: SecIdentity, summary: String)? {
        guard id.hasPrefix("identity:") else { return nil }
        let wanted = String(id.dropFirst("identity:".count))

        var query = [String: Any]()
        query[kSecClass as String] = kSecClassIdentity
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnRef as String] = true

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let refs = result as? [SecIdentity] else { return nil }

        for identity in refs {
            var certificate: SecCertificate?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
                  let cert = certificate,
                  let summary = SecCertificateCopySubjectSummary(cert) as String?,
                  summary == wanted else { continue }
            return (identity, summary)
        }
        return nil
    }

    public static func scanTokenCertificates() -> [SigningIdentityInfo] {
        var query = [String: Any]()
        query[kSecClass as String] = kSecClassCertificate
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecReturnRef as String] = true

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let refs = result as? [SecCertificate] else { return [] }

        return refs.compactMap { cert -> SigningIdentityInfo? in
            let summary = SecCertificateCopySubjectSummary(cert) as String? ?? ""
            guard !summary.isEmpty else { return nil }
            let lowered = summary.lowercased()

            let relevant = lowered.contains("qcp") ||
                           qualifiedIssuerHints.contains { lowered.contains($0) } ||
                           lowered.contains("advok") || lowered.contains("notár") ||
                           lowered.contains("podpis")
            guard relevant else { return nil }

            return SigningIdentityInfo(
                id: "certificate:\(summary)",
                label: summary,
                issuerSummary: Self.issuerHint(from: summary) + " · bez privátneho kľúča cez Keychain",
                isMandateCertificate: Self.looksMandate(summary),
                isQualified: true,
                hasPrivateKey: false)
        }
    }

    public static func connectedTokenNames() -> [String] {
        let watcher = TKTokenWatcher()
        return watcher.tokenIDs
            .filter { !$0.lowercased().hasPrefix("apple.") && !$0.lowercased().hasPrefix("com.apple") }
            .map { tokenID in
                let cleaned = tokenID
                    .replacingOccurrences(of: "com.", with: "")
                    .replacingOccurrences(of: ".tokenextension", with: "")
                    .replacingOccurrences(of: ".pkcs11", with: "")
                    .replacingOccurrences(of: ".token", with: "")
                return cleaned.capitalized
            }.sorted()
    }

    static func looksMandate(_ text: String) -> Bool {
        MandateCertificate.matches(subject: text)
    }

    static func looksQualified(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return lowered.contains("qcp") || lowered.contains("qualified") ||
               looksMandate(lowered) || qualifiedIssuerHints.contains { lowered.contains($0) }
    }

    static func issuerHint(from summary: String) -> String {
        for hint in ["i.ca", "disig", "eid", "e-id", "nase", "slovensko", "certum"] where summary.lowercased().contains(hint) {
            switch hint {
            case "i.ca": return "I.CA"
            case "disig": return "Disig"
            case "eid", "e-id": return "eID SR"
            case "nase": return "NASE"
            case "slovensko": return "Slovensko.sk"
            case "certum": return "Certum"
            default: continue
            }
        }
        return "Keychain / token"
    }
}

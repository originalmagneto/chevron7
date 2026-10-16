// SPDX-FileCopyrightText: 2026 Marián Čuprík
// SPDX-License-Identifier: EUPL-1.2

import CryptoKit
import Foundation

/// A qualified validation service the advocate contracted and added in Settings
/// (vyhláška 70/2021 § 3 ods. 4). v1 imports the service's sealed report; no credentials.
public struct QualifiedValidationService: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var provider: String
    public var portalURL: URL?

    public init(id: UUID = UUID(), name: String, provider: String, portalURL: URL? = nil) {
        self.id = id
        self.name = name
        self.provider = provider
        self.portalURL = portalURL
    }
}

public enum QualifiedValidationReportError: LocalizedError, Equatable {
    case sealInvalid
    case notAValidationService(subject: String)
    case reportForAnotherDocument
    case validatedBeforeLastSignature
    case indicationMismatch(signer: String)

    public var errorDescription: String? {
        switch self {
        case .sealInvalid:
            return "Pečať na výsledku validácie nie je platná, preto ho nemožno použiť."
        case .notAValidationService(let subject):
            return "Výsledok nezapečatila kvalifikovaná služba validácie z dôveryhodného zoznamu (pečať: \(subject))."
        case .reportForAnotherDocument:
            return "Výsledok validácie sa týka iného dokumentu."
        case .validatedBeforeLastSignature:
            return "Výsledok validácie je starší ako posledný podpis dokumentu."
        case .indicationMismatch(let signer):
            return "Kvalifikovaná služba posúdila podpis \(signer) inak ako overenie v Chevron7. Skontrolujte dokument a výsledok."
        }
    }
}

/// A qualified validation service's sealed output, accepted for one original: sealed by a
/// service the trusted lists name `QESValidation/Q`, newer than the last signature, and naming
/// this document (by hash or signature values) unless the advocate confirms that it does.
public struct QualifiedValidationReport: Sendable, Equatable {
    public enum Binding: Sendable, Equatable {
        /// The report names the original's hash or every signature value.
        case matched
        /// A PDF or text report the app cannot read; the advocate confirms it concerns this document.
        case needsConfirmation
    }

    public static let validationServiceType = "http://uri.etsi.org/TrstSvc/Svctype/QESValidation/Q"

    public var data: Data
    public var fileName: String
    public var sealSubject: String
    public var sealTime: Date?
    public var binding: Binding

    public var fileExtension: String { (fileName as NSString).pathExtension.lowercased() }

    /// `reportEvidence` is the engine's evidence for the report file itself (its seal).
    public static func accept(reportData: Data, fileName: String, reportEvidence: ConversionEvidence,
                              original: ElectronicOriginal) throws -> QualifiedValidationReport {
        let seals = reportEvidence.tree.signatures
        guard let seal = seals.first(where: { $0.state == .valid }) else {
            throw QualifiedValidationReportError.sealInvalid
        }
        let facts = reportEvidence.signature(id: seal.id)
        guard facts?.trustServiceTypes.contains(validationServiceType) == true else {
            throw QualifiedValidationReportError.notAValidationService(
                subject: facts?.signerCommonName ?? seal.signerDisplayName)
        }
        let sealTime = seal.timestampTime ?? seal.signingTime
        if let sealTime, let last = original.authorizations.compactMap(\.signingTime).max(), sealTime < last {
            throw QualifiedValidationReportError.validatedBeforeLastSignature
        }
        let binding: Binding
        if let xml = xmlText(reportData) {
            guard names(original, in: xml) else { throw QualifiedValidationReportError.reportForAnotherDocument }
            let verdicts = signatureVerdicts(xml)
            for authorization in original.authorizations {
                guard let verdict = verdicts[authorization.signatureValue.base64EncodedString()] else { continue }
                if verdict != authorization.state {
                    throw QualifiedValidationReportError.indicationMismatch(signer: authorization.signerName)
                }
            }
            binding = .matched
        } else {
            binding = .needsConfirmation
        }
        return QualifiedValidationReport(data: reportData, fileName: fileName, sealSubject: seal.signerDisplayName,
                                         sealTime: sealTime, binding: binding)
    }

    static func xmlText(_ data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.drop { $0 == "\u{FEFF}" || $0.isWhitespace }
        return trimmed.hasPrefix("<") ? text : nil
    }

    /// The report names the original when it carries one of the original's SHA-256 values
    /// (base64 or hex, e.g. Disig's `ContentHash`) or every signature value.
    static func names(_ original: ElectronicOriginal, in xml: String) -> Bool {
        let compact = xml.replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
        var hashes = original.documents.map(\.sha256)
        hashes.append(Data(SHA256.hash(data: original.pdfData)))
        for hash in hashes {
            let hex = hash.map { String(format: "%02x", $0) }.joined()
            if compact.contains(hash.base64EncodedString()) || compact.lowercased().contains(hex) { return true }
        }
        let values = original.authorizations.map { $0.signatureValue.base64EncodedString() }
        return !values.isEmpty && values.allSatisfy { compact.contains($0) }
    }

    /// Per signature value, the verdict a machine-readable report states: Disig/NASES
    /// `ESSignatureValidationDetail` (`SignatureValue` with `ValidationResult/Type`) or ETSI
    /// TS 119 102-2 (`SignatureIdentifier/SignatureValue` with `MainIndication`).
    static func signatureVerdicts(_ xml: String) -> [String: ElectronicOriginal.ValidityState] {
        guard let document = try? XMLDocument(xmlString: xml, options: []) else { return [:] }
        var verdicts: [String: ElectronicOriginal.ValidityState] = [:]
        let disig = (try? document.nodes(forXPath: "//*[local-name()='ESSignatureValidationDetail']")) ?? []
        for node in disig {
            guard let value = first(node, "./*[local-name()='SignatureId']/*[local-name()='SignatureValue']"),
                  let type = first(node, ".//*[local-name()='Signature']/*[local-name()='ValidationResult']/*[local-name()='Type']") else {
                continue
            }
            verdicts[compact(value)] = state(type)
        }
        let etsi = (try? document.nodes(forXPath: "//*[local-name()='SignatureValidationReport']")) ?? []
        for node in etsi {
            guard let value = first(node, "./*[local-name()='SignatureIdentifier']/*[local-name()='SignatureValue']"),
                  let indication = first(node, "./*[local-name()='SignatureValidationStatus']/*[local-name()='MainIndication']") else {
                continue
            }
            verdicts[compact(value)] = state(indication)
        }
        return verdicts
    }

    private static func first(_ node: XMLNode, _ path: String) -> String? {
        (try? node.nodes(forXPath: path))?.first?.stringValue
    }

    private static func compact(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s", with: "", options: .regularExpression)
    }

    private static func state(_ text: String) -> ElectronicOriginal.ValidityState {
        let value = text.lowercased()
        if value == "valid" || value.hasSuffix("total-passed") || value.hasSuffix(":passed") { return .valid }
        if value == "invalid" || value.hasSuffix("total-failed") || value.hasSuffix(":failed") { return .invalid }
        return .undetermined
    }
}
